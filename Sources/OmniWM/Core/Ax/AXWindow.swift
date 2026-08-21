// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement
    let windowId: Int

    init(element: AXUIElement, windowId: Int) {
        self.element = element
        self.windowId = windowId
    }

    init(element: AXUIElement) throws {
        self.element = element
        var value: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &value)
        guard result == .success else { throw AXErrorWrapper.cannotGetWindowId }
        self.windowId = Int(value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowId == rhs.windowId
    }
}

enum AXErrorWrapper: Error {
    case cannotSetFrame
    case cannotGetAttribute
    case cannotGetWindowId
}

typealias AXFrameRequestId = UInt64

typealias AXFrameComponents = FrameMutationComponents

func axFrameMatches(
    _ observed: CGRect,
    target: CGRect,
    components: AXFrameComponents,
    tolerance: CGFloat = FrameTolerance.frameWrite
) -> Bool {
    (!components.contains(.position)
        || (abs(observed.origin.x - target.origin.x) < tolerance
            && abs(observed.origin.y - target.origin.y) < tolerance))
        && (!components.contains(.size)
            || (abs(observed.width - target.width) < tolerance
                && abs(observed.height - target.height) < tolerance))
}

enum AXFrameWriteOrder {
    case sizeThenPosition
    case positionThenSize
}

enum AXFrameWriteFailureReason: Equatable, Sendable {
    case valueCreationFailed
    case sizeWriteFailed(AXError)
    case positionWriteFailed(AXError)
    case staleElement
    case contextUnavailable
    case readbackFailed
    case verificationMismatch
    case cancelled
    case suppressed

    var traceDescription: String {
        switch self {
        case .valueCreationFailed:
            "valueCreationFailed"
        case let .sizeWriteFailed(error):
            "sizeWriteFailed(raw=\(error.rawValue))"
        case let .positionWriteFailed(error):
            "positionWriteFailed(raw=\(error.rawValue))"
        case .staleElement:
            "staleElement"
        case .contextUnavailable:
            "contextUnavailable"
        case .readbackFailed:
            "readbackFailed"
        case .verificationMismatch:
            "verificationMismatch"
        case .cancelled:
            "cancelled"
        case .suppressed:
            "suppressed"
        }
    }
}

struct AXFrameWriteResult: Equatable, Sendable {
    let targetFrame: CGRect
    let observedFrame: CGRect?
    let writeOrder: AXFrameWriteOrder
    let sizeError: AXError
    let positionError: AXError
    let failureReason: AXFrameWriteFailureReason?
    let components: AXFrameComponents

    init(
        targetFrame: CGRect,
        observedFrame: CGRect?,
        writeOrder: AXFrameWriteOrder,
        sizeError: AXError,
        positionError: AXError,
        failureReason: AXFrameWriteFailureReason?,
        components: AXFrameComponents = .all
    ) {
        self.targetFrame = targetFrame
        self.observedFrame = observedFrame
        self.writeOrder = writeOrder
        self.sizeError = sizeError
        self.positionError = positionError
        self.failureReason = failureReason
        self.components = components
    }

    var isVerifiedSuccess: Bool {
        failureReason == nil
    }

    var shouldRetryAfterRefresh: Bool {
        failureReason == .staleElement
    }

    static func skipped(
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        failureReason: AXFrameWriteFailureReason,
        observedFrame: CGRect? = nil,
        components: AXFrameComponents = .all
    ) -> Self {
        Self(
            targetFrame: targetFrame,
            observedFrame: observedFrame,
            writeOrder: AXWindowService.frameWriteOrder(currentFrame: currentFrameHint, targetFrame: targetFrame),
            sizeError: .success,
            positionError: .success,
            failureReason: failureReason,
            components: components
        )
    }
}

struct AXFrameApplicationRequest: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?
    let components: AXFrameComponents
    var verify = true
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents = .all,
        verify: Bool = true,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.frame = frame
        self.currentFrameHint = currentFrameHint
        self.components = components
        self.verify = verify
        self.traceRequestId = traceRequestId
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.frame == rhs.frame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.components == rhs.components
            && lhs.verify == rhs.verify
    }
}

struct AXFrameApplyResult: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let targetFrame: CGRect
    let currentFrameHint: CGRect?
    let writeResult: AXFrameWriteResult
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId = 0,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        writeResult: AXFrameWriteResult,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.targetFrame = targetFrame
        self.currentFrameHint = currentFrameHint
        self.writeResult = writeResult
        self.traceRequestId = traceRequestId
    }

    var confirmedFrame: CGRect? {
        if let observedFrame = writeResult.observedFrame,
           axFrameMatches(observedFrame, target: targetFrame, components: writeResult.components)
        {
            return observedFrame
        }
        guard writeResult.isVerifiedSuccess else { return nil }
        return writeResult.observedFrame ?? targetFrame
    }

    func rekeyed(to windowId: Int) -> Self {
        Self(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: AXWindowRef(
                element: expectedWindow.element,
                windowId: windowId
            ),
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: writeResult,
            traceRequestId: traceRequestId
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.targetFrame == rhs.targetFrame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.writeResult == rhs.writeResult
    }
}

func sameAXWindowIdentity(_ lhs: AXWindowRef, _ rhs: AXWindowRef) -> Bool {
    lhs.windowId == rhs.windowId && CFEqual(lhs.element, rhs.element)
}

enum AXWindowHeuristicReason: String, Sendable {
    case attributeFetchFailed
    case accessoryWithoutClose
    case noButtonsOnNonStandardSubrole
    case nonStandardSubrole
    case missingFullscreenButton
    case disabledFullscreenButton
}

struct AXWindowFacts: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let title: String?
    let hasCloseButton: Bool
    let hasFullscreenButton: Bool
    let fullscreenButtonEnabled: Bool?
    let hasZoomButton: Bool
    let hasMinimizeButton: Bool
    let appPolicy: NSApplication.ActivationPolicy?
    let bundleId: String?
    let attributeFetchSucceeded: Bool
}

struct AXWindowDecisionEvidence: Equatable, Sendable {
    let facts: AXWindowFacts
    let sizeConstraints: WindowSizeConstraints

    static func unavailable(
        role: String? = nil,
        subrole: String? = nil,
        appPolicy: NSApplication.ActivationPolicy? = nil,
        bundleId: String? = nil
    ) -> Self {
        Self(
            facts: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: appPolicy,
                bundleId: bundleId,
                attributeFetchSucceeded: false
            ),
            sizeConstraints: .unconstrained
        )
    }
}

struct AXWindowFactAttributeValues {
    let role: String?
    let subrole: String?
    let title: String?
    let closeButton: Any?
    let fullscreenButton: Any?
    let fullscreenButtonEnabled: Bool?
    let zoomButton: Any?
    let minimizeButton: Any?
}

struct AXWindowConstraintInputs {
    let hasGrowArea: Bool
    let hasZoomButton: Bool
    let subrole: String?
    let minSize: CGSize?
    let maxSize: CGSize?
    let currentSize: CGSize?
}

enum AXFullscreenButtonEvidence {
    case absent
    case present(AXUIElement)
    case failed

    var element: AXUIElement? {
        guard case let .present(element) = self else { return nil }
        return element
    }

    var succeeded: Bool {
        guard case .failed = self else { return true }
        return false
    }
}

struct AXWindowHeuristicDisposition: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let reasons: [AXWindowHeuristicReason]
}

enum AXWindowService {
    private enum WindowTypeAttributeIndex: Int {
        case role
        case subrole
        case closeButton
        case fullScreenButton
        case zoomButton
        case minimizeButton
        case title
    }

    // Held AXUIElement references for windows that may be pruned from the
    // app's kAXWindowsAttribute enumeration (e.g. scratchpad-hidden Calculator
    // windows that drop out of the AX windows list while off-screen). Survives
    // AppAXContext reconciliation because we hold the CFType ref directly.
    private static let pinnedElementsLock = NSLock()
    private nonisolated(unsafe) static var pinnedElements: [UInt32: AXUIElement] = [:]

    static func pinAXElement(_ element: AXUIElement, for windowId: UInt32) {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        pinnedElements[windowId] = element
    }

    static func unpinAXElement(for windowId: UInt32) {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        pinnedElements.removeValue(forKey: windowId)
    }

    static func hasPinnedAXElement(for windowId: UInt32) -> Bool {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        return pinnedElements[windowId] != nil
    }

    private static func pinnedAXElement(for windowId: UInt32) -> AXUIElement? {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        return pinnedElements[windowId]
    }

    static func pinnedWindowId(for windowId: UInt32) -> CGWindowID? {
        guard let pinned = pinnedAXElement(for: windowId) else { return nil }
        var resolvedWindowId: CGWindowID = 0
        guard _AXUIElementGetWindow(pinned, &resolvedWindowId) == .success else { return nil }
        return resolvedWindowId
    }

    private static let titleCacheCap = 512
    @MainActor private static var titleCache: [UInt32: String?] = [:]
    @MainActor private static var titleInsertionOrder: [UInt32] = []

    private static func value(at index: Int, in values: CFArray) -> CFTypeRef? {
        guard index >= 0,
              index < CFArrayGetCount(values),
              let pointer = CFArrayGetValueAtIndex(values, index)
        else {
            return nil
        }
        return unsafeBitCast(pointer, to: CFTypeRef.self)
    }

    private static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: NSString.self) as String
    }

    @MainActor
    static func titlePreferFast(windowId: UInt32) -> String? {
        if let cached = titleCache[windowId] {
            return cached
        }
        let title = SkyLight.shared.getWindowTitle(windowId)
        storeTitleCacheEntry(windowId: windowId, title: title)
        return title
    }

    @MainActor
    static func invalidateCachedTitle(windowId: UInt32) {
        titleCache.removeValue(forKey: windowId)
        titleInsertionOrder.removeAll { $0 == windowId }
    }

    @MainActor
    static func invalidateCachedTitles(windowIds: [UInt32]) {
        for windowId in windowIds {
            titleCache.removeValue(forKey: windowId)
        }
        let windowIdSet = Set(windowIds)
        titleInsertionOrder.removeAll { windowIdSet.contains($0) }
    }

    @MainActor
    private static func storeTitleCacheEntry(windowId: UInt32, title: String?) {
        if titleCache.index(forKey: windowId) == nil {
            titleInsertionOrder.append(windowId)
        }
        titleCache[windowId] = title
        while titleCache.count > titleCacheCap, let oldest = titleInsertionOrder.first {
            titleInsertionOrder.removeFirst()
            titleCache.removeValue(forKey: oldest)
        }
    }

    static func shouldTreatAsTopLevelWindow(role: String?, subrole: String?) -> Bool {
        role == kAXWindowRole as String || subrole == kAXStandardWindowSubrole as String
    }

    static func windowId(_ window: AXWindowRef) -> Int {
        window.windowId
    }

    static func processIdentifier(_ window: AXWindowRef) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window.element, &pid) == .success else { return nil }
        return pid
    }

    static func isSizeSettable(_ window: AXWindowRef) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            window.element,
            kAXSizeAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    static func frame(_ window: AXWindowRef) throws(AXErrorWrapper) -> CGRect {
        let attributes = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString
        ] as CFArray
        var valuesPtr: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributes,
            .init(),
            &valuesPtr
        )
        guard result == .success,
              let values = valuesPtr,
              CFArrayGetCount(values) == 2,
              let posRaw = value(at: 0, in: values),
              let sizeRaw = value(at: 1, in: values)
        else { throw .cannotGetAttribute }
        guard CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { throw .cannotGetAttribute }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(posRaw, to: AXValue.self), .cgPoint, &pos),
              AXValueGetValue(unsafeDowncast(sizeRaw, to: AXValue.self), .cgSize, &size)
        else { throw .cannotGetAttribute }
        return convertFromAX(CGRect(origin: pos, size: size))
    }

    @MainActor
    static func fastFrame(_ window: AXWindowRef) -> CGRect? {
        guard let frame = SkyLight.shared.getWindowBounds(UInt32(windowId(window))) else { return nil }
        return ScreenCoordinateSpace.toAppKit(rect: frame)
    }

    @MainActor
    static func framePreferFast(_ window: AXWindowRef) -> CGRect? {
        fastFrame(window)
    }

    static func frameWriteOrder(currentFrame: CGRect?, targetFrame: CGRect) -> AXFrameWriteOrder {
        guard let currentFrame else {
            return .sizeThenPosition
        }
        if targetFrame.width > currentFrame.width + 0.5 || targetFrame.height > currentFrame.height + 0.5 {
            return .positionThenSize
        }
        return .sizeThenPosition
    }

    static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> AXFrameWriteResult {
        setFrame(
            window,
            frame: frame,
            currentFrameHint: currentFrameHint,
            components: components,
            verify: verify,
            timing: nil
        )
    }

    static func setFrameTraced(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> (result: AXFrameWriteResult, timing: AXFrameSetterTiming) {
        var timing = AXFrameSetterTiming()
        let result = withUnsafeMutablePointer(to: &timing) { pointer in
            setFrame(
                window,
                frame: frame,
                currentFrameHint: currentFrameHint,
                components: components,
                verify: verify,
                timing: pointer
            )
        }
        return (result, timing)
    }

    private static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents,
        verify: Bool,
        timing: UnsafeMutablePointer<AXFrameSetterTiming>?
    ) -> AXFrameWriteResult {
        precondition(!components.isEmpty)
        let writeOrder = components == .all
            ? frameWriteOrder(
                currentFrame: currentFrameHint ?? (try? self.frame(window)),
                targetFrame: frame
            )
            : .sizeThenPosition
        let axFrame = convertToAX(frame)
        var position = CGPoint(x: axFrame.origin.x, y: axFrame.origin.y)
        var size = CGSize(width: axFrame.size.width, height: axFrame.size.height)
        let positionValue = components.contains(.position) ? AXValueCreate(.cgPoint, &position) : nil
        let sizeValue = components.contains(.size) ? AXValueCreate(.cgSize, &size) : nil
        guard (!components.contains(.position) || positionValue != nil),
              (!components.contains(.size) || sizeValue != nil)
        else {
            return .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: .valueCreationFailed,
                components: components
            )
        }

        var positionError: AXError = .success
        var sizeError: AXError = .success

        func setSize() -> AXError {
            guard let sizeValue else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
            if let timing {
                timing.pointee.sizeNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        func setPosition() -> AXError {
            guard let positionValue else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(
                window.element,
                kAXPositionAttribute as CFString,
                positionValue
            )
            if let timing {
                timing.pointee.positionNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        switch writeOrder {
        case .sizeThenPosition:
            sizeError = setSize()
            positionError = setPosition()
        case .positionThenSize:
            positionError = setPosition()
            sizeError = setSize()
        }

        let verificationStart = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let observedFrame = verify ? (try? self.frame(window)) : nil
        if let timing {
            timing.pointee.verificationNs = elapsedNanoseconds(since: verificationStart)
        }

        let failureReason: AXFrameWriteFailureReason? = if sizeError != .success {
            mapFrameWriteFailure(sizeError, attribute: .size)
        } else if positionError != .success {
            mapFrameWriteFailure(positionError, attribute: .position)
        } else if !verify {
            nil
        } else if let observedFrame {
            axFrameMatches(observedFrame, target: frame, components: components) ? nil : .verificationMismatch
        } else {
            .readbackFailed
        }

        return AXFrameWriteResult(
            targetFrame: frame,
            observedFrame: observedFrame,
            writeOrder: writeOrder,
            sizeError: sizeError,
            positionError: positionError,
            failureReason: failureReason,
            components: components
        )
    }

    private static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        let end = DispatchTime.now().uptimeNanoseconds
        return end >= start ? end - start : 0
    }

    private static func convertFromAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toAppKit(rect: rect)
    }

    private static func convertToAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toWindowServer(rect: rect)
    }

    static func subrole(_ window: AXWindowRef) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window.element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return nil }
        return subrole
    }

    static func roleAndSubrole(_ window: AXWindowRef) -> (role: String?, subrole: String?) {
        let attributes = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString
        ] as CFArray
        var valuesPtr: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(window.element, attributes, .init(), &valuesPtr)
        guard result == .success, let values = valuesPtr, CFArrayGetCount(values) == 2 else { return (nil, nil) }
        return (
            stringValue(value(at: 0, in: values)),
            stringValue(value(at: 1, in: values))
        )
    }

    static func isSystemModalSurface(role: String?, subrole: String?) -> Bool {
        role == kAXSheetRole as String
            || subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
    }

    static func isSystemModalSurface(_ window: AXWindowRef) -> Bool {
        let attributes = roleAndSubrole(window)
        return isSystemModalSurface(role: attributes.role, subrole: attributes.subrole)
    }

    static func isFullscreen(_ window: AXWindowRef) -> Bool {
        isFullscreen(window, subrole: subrole(window))
    }

    static func isFullscreen(_ window: AXWindowRef, subrole: String?) -> Bool {
        if subrole == "AXFullScreenWindow" {
            return true
        }

        var value: CFTypeRef?
        let fullScreenAttribute = "AXFullScreen" as CFString
        let result = AXUIElementCopyAttributeValue(
            window.element,
            fullScreenAttribute,
            &value
        )
        if result == .success, let boolValue = value as? Bool {
            return boolValue
        }

        if let frame = try? frame(window) {
            return isFullscreenFrame(frame)
        }

        return false
    }

    static func isFullscreenAttributeSet(_ window: AXWindowRef) -> Bool {
        if let subrole = subrole(window), subrole == "AXFullScreenWindow" {
            return true
        }

        var value: CFTypeRef?
        let fullScreenAttribute = "AXFullScreen" as CFString
        let result = AXUIElementCopyAttributeValue(
            window.element,
            fullScreenAttribute,
            &value
        )
        if result == .success, let boolValue = value as? Bool {
            return boolValue
        }

        return false
    }

    static func setNativeFullscreen(_ window: AXWindowRef, fullscreen: Bool) -> Bool {
        let fullScreenAttribute = "AXFullScreen" as CFString
        let result = AXUIElementSetAttributeValue(
            window.element,
            fullScreenAttribute,
            fullscreen as CFBoolean
        )
        return result == .success
    }

    private static func isFullscreenFrame(_ frame: CGRect) -> Bool {
        let center = frame.center
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return false
        }
        return frame.approximatelyEqual(to: screen.frame, tolerance: FrameTolerance.screenMatch)
    }

    static func collectWindowFacts(
        _ window: AXWindowRef,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String? = nil,
        includeTitle: Bool
    ) -> AXWindowFacts {
        var attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXCloseButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXMinimizeButtonAttribute as CFString
        ]
        if includeTitle {
            attributes.append(kAXTitleAttribute as CFString)
        }

        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        guard result == .success,
              let values,
              CFArrayGetCount(values) > WindowTypeAttributeIndex.minimizeButton.rawValue
        else {
            return AXWindowDecisionEvidence.unavailable(
                appPolicy: appPolicy,
                bundleId: bundleId
            ).facts
        }

        func attributeValue(_ index: WindowTypeAttributeIndex) -> CFTypeRef? {
            value(at: index.rawValue, in: values)
        }

        let fullscreenButtonValue = attributeValue(.fullScreenButton)
        let fullscreenButtonEvidence = fullscreenButtonEvidence(fullscreenButtonValue)
        var attributeFetchSucceeded = fullscreenButtonEvidence.succeeded

        var fullscreenButtonEnabled: Bool?
        if let buttonElement = fullscreenButtonEvidence.element {
            var enabledValue: CFTypeRef?
            let enabledResult = AXUIElementCopyAttributeValue(
                buttonElement,
                kAXEnabledAttribute as CFString,
                &enabledValue
            )
            if enabledResult == .success {
                if let enabledValue {
                    if let resolvedEnabled = enabledValue as? Bool {
                        fullscreenButtonEnabled = resolvedEnabled
                    } else {
                        attributeFetchSucceeded = false
                    }
                }
            }
        }

        return makeWindowFacts(
            AXWindowFactAttributeValues(
                role: stringValue(attributeValue(.role)),
                subrole: stringValue(attributeValue(.subrole)),
                title: includeTitle ? stringValue(attributeValue(.title)) : nil,
                closeButton: attributeValue(.closeButton),
                fullscreenButton: fullscreenButtonValue,
                fullscreenButtonEnabled: fullscreenButtonEnabled,
                zoomButton: attributeValue(.zoomButton),
                minimizeButton: attributeValue(.minimizeButton)
            ),
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        )
    }

    static func makeWindowFacts(
        _ attributes: AXWindowFactAttributeValues,
        appPolicy: NSApplication.ActivationPolicy?,
        bundleId: String?,
        attributeFetchSucceeded: Bool
    ) -> AXWindowFacts {
        AXWindowFacts(
            role: attributes.role,
            subrole: attributes.subrole,
            title: attributes.title,
            hasCloseButton: resolvedAttribute(attributes.closeButton),
            hasFullscreenButton: resolvedAttribute(attributes.fullscreenButton),
            fullscreenButtonEnabled: attributes.fullscreenButtonEnabled,
            hasZoomButton: resolvedAttribute(attributes.zoomButton),
            hasMinimizeButton: resolvedAttribute(attributes.minimizeButton),
            appPolicy: appPolicy,
            bundleId: bundleId,
            attributeFetchSucceeded: attributeFetchSucceeded
        )
    }

    private static func resolvedAttribute(_ value: CFTypeRef?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

    static func resolvedAttribute(_ value: Any?) -> Bool {
        guard let value else { return false }
        return resolvedAttribute(value as CFTypeRef)
    }

    static func fullscreenButtonEvidence(_ value: Any?) -> AXFullscreenButtonEvidence {
        guard let value else { return .absent }
        let cfValue = value as CFTypeRef
        let typeId = CFGetTypeID(cfValue)
        if typeId == CFNullGetTypeID() {
            return .absent
        }
        if typeId == AXUIElementGetTypeID() {
            return .present(unsafeDowncast(cfValue, to: AXUIElement.self))
        }
        guard typeId == AXValueGetTypeID() else {
            return .failed
        }
        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else {
            return .failed
        }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else {
            return .failed
        }
        switch error {
        case .noValue,
             .attributeUnsupported:
            return .absent
        default:
            return .failed
        }
    }

    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    static func sizeValue(_ value: Any?) -> CGSize? {
        guard let value else { return nil }
        return sizeValue(value as CFTypeRef)
    }

    static func sizeConstraintInputs(
        from values: CFArray,
        currentSize: CGSize?
    ) -> AXWindowConstraintInputs {
        AXWindowConstraintInputs(
            hasGrowArea: resolvedAttribute(value(at: 0, in: values)),
            hasZoomButton: resolvedAttribute(value(at: 1, in: values)),
            subrole: stringValue(value(at: 2, in: values)),
            minSize: sizeValue(value(at: 3, in: values)),
            maxSize: sizeValue(value(at: 4, in: values)),
            currentSize: currentSize
        )
    }

    static func resolvedSizeConstraints(_ inputs: AXWindowConstraintInputs) -> WindowSizeConstraints {
        let resizable = inputs.hasGrowArea
            || inputs.hasZoomButton
            || inputs.subrole == (kAXStandardWindowSubrole as String)
        if !resizable {
            return inputs.currentSize.map(WindowSizeConstraints.fixed(size:)) ?? .unconstrained
        }
        return WindowSizeConstraints(
            minSize: inputs.minSize ?? CGSize(width: 100, height: 100),
            maxSize: inputs.maxSize ?? .zero,
            isFixed: false
        )
    }

    static func heuristicDisposition(
        for facts: AXWindowFacts,
        overriddenWindowType: AXWindowType? = nil
    ) -> AXWindowHeuristicDisposition {
        if let overriddenWindowType {
            let disposition: WindowDecisionDisposition = overriddenWindowType == .tiling ? .managed : .floating
            return AXWindowHeuristicDisposition(disposition: disposition, reasons: [])
        }

        if !facts.attributeFetchSucceeded {
            return AXWindowHeuristicDisposition(
                disposition: .undecided,
                reasons: [.attributeFetchFailed]
            )
        }

        let hasAnyButton = facts.hasCloseButton
            || facts.hasFullscreenButton
            || facts.hasZoomButton
            || facts.hasMinimizeButton

        if facts.appPolicy == .accessory && !facts.hasCloseButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.accessoryWithoutClose]
            )
        }

        if !hasAnyButton && facts.subrole != kAXStandardWindowSubrole as String {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.noButtonsOnNonStandardSubrole]
            )
        }

        if let subrole = facts.subrole,
           subrole != (kAXStandardWindowSubrole as String)
        {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.nonStandardSubrole]
            )
        }

        if !facts.hasFullscreenButton {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.missingFullscreenButton]
            )
        }

        if facts.fullscreenButtonEnabled != true {
            return AXWindowHeuristicDisposition(
                disposition: .floating,
                reasons: [.disabledFullscreenButton]
            )
        }

        return AXWindowHeuristicDisposition(
            disposition: .managed,
            reasons: []
        )
    }

    static func sizeConstraints(_ window: AXWindowRef, currentSize: CGSize? = nil) -> WindowSizeConstraints {
        fetchSizeConstraintsBatched(window, currentSize: currentSize)
    }

    private static func fetchSizeConstraintsBatched(
        _ window: AXWindowRef,
        currentSize: CGSize? = nil
    ) -> WindowSizeConstraints {
        let attributes: [CFString] = [
            "AXGrowArea" as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXSubroleAttribute as CFString,
            "AXMinSize" as CFString,
            "AXMaxSize" as CFString
        ]

        var values: CFArray?
        let attributesCFArray = attributes as CFArray
        let result = AXUIElementCopyMultipleAttributeValues(
            window.element,
            attributesCFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )

        let observedSize = currentSize ?? (try? frame(window).size)
        let inputs = if result == .success, let values {
            sizeConstraintInputs(from: values, currentSize: observedSize)
        } else {
            AXWindowConstraintInputs(
                hasGrowArea: false,
                hasZoomButton: false,
                subrole: nil,
                minSize: nil,
                maxSize: nil,
                currentSize: observedSize
            )
        }

        return resolvedSizeConstraints(inputs)
    }

    static func axWindowRef(for windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        if let pinned = pinnedAXElement(for: windowId) {
            var winId: CGWindowID = 0
            if _AXUIElementGetWindow(pinned, &winId) == .success, winId == windowId {
                return AXWindowRef(element: pinned, windowId: Int(winId))
            }
            unpinAXElement(for: windowId)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var winId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &winId) == .success, winId == windowId {
                return AXWindowRef(element: window, windowId: Int(winId))
            }
        }

        return nil
    }

    private enum FrameWriteAttribute {
        case size
        case position
    }

    private static func mapFrameWriteFailure(
        _ error: AXError,
        attribute: FrameWriteAttribute
    ) -> AXFrameWriteFailureReason {
        if error == .invalidUIElement || error == .cannotComplete {
            return .staleElement
        }

        return switch attribute {
        case .size:
            .sizeWriteFailed(error)
        case .position:
            .positionWriteFailed(error)
        }
    }
}

enum AXWindowType {
    case tiling
    case floating
}
