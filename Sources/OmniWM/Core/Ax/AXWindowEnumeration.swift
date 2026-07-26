// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation

struct WindowAdmissionGeometryEvidence: Equatable, Sendable {
    let isSizeSettable: Bool
    let frame: CGRect?

    var isManageable: Bool {
        guard isSizeSettable, let frame else { return false }
        return !frame.isNull
            && !frame.isInfinite
            && frame.width > 1
            && frame.height > 1
    }
}

struct AXWindowInspectionContext: Sendable {
    let appPolicy: NSApplication.ActivationPolicy?
    let bundleId: String?
    let includeTitle: Bool

    static let unidentified = AXWindowInspectionContext(
        appPolicy: nil,
        bundleId: nil,
        includeTitle: false
    )
}

struct AXEnumeratedWindow: Sendable {
    let axRef: AXWindowRef
    let axPid: pid_t?
    let role: String?
    let subrole: String?
    let admissionGeometry: WindowAdmissionGeometryEvidence
    let fullscreenAttribute: Bool?
    let decisionEvidence: AXWindowDecisionEvidence

    init(
        axRef: AXWindowRef,
        axPid: pid_t?,
        role: String?,
        subrole: String?,
        admissionGeometry: WindowAdmissionGeometryEvidence,
        fullscreenAttribute: Bool? = nil,
        decisionEvidence: AXWindowDecisionEvidence? = nil
    ) {
        self.axRef = axRef
        self.axPid = axPid
        self.role = role
        self.subrole = subrole
        self.admissionGeometry = admissionGeometry
        self.fullscreenAttribute = fullscreenAttribute
        self.decisionEvidence = decisionEvidence ?? .unavailable(role: role, subrole: subrole)
    }
}

enum FullRescanEnumerationRoute: Equatable, Sendable {
    case persistent
    case oneShot
}

struct FullRescanWindowCandidate: Sendable {
    let enumeratedWindow: AXEnumeratedWindow
    let logicalPID: pid_t
    let windowServerInfo: WindowServerInfo?
    let windowServerOwnerPID: pid_t?
    let enumerationRoute: FullRescanEnumerationRoute
    let callbackGeneration: UInt64?

    var axRef: AXWindowRef {
        enumeratedWindow.axRef
    }

    var pid: pid_t {
        logicalPID
    }

    var windowId: Int {
        enumeratedWindow.axRef.windowId
    }

    var axPid: pid_t? {
        enumeratedWindow.axPid
    }

    var isManageable: Bool {
        enumeratedWindow.admissionGeometry.isManageable
    }

    var capturedFrame: CGRect? {
        windowServerInfo?.frame ?? enumeratedWindow.admissionGeometry.frame
    }

    func isFullscreen(screenFrames: [CGRect]) -> Bool {
        if enumeratedWindow.subrole == "AXFullScreenWindow" {
            return true
        }
        if let fullscreenAttribute = enumeratedWindow.fullscreenAttribute {
            return fullscreenAttribute
        }
        guard let frame = capturedFrame,
              let screenFrame = screenFrames.first(where: { $0.contains(frame.center) })
        else {
            return false
        }
        return frame.approximatelyEqual(to: screenFrame, tolerance: FrameTolerance.screenMatch)
    }

    init(
        enumeratedWindow: AXEnumeratedWindow,
        logicalPID: pid_t,
        windowServerInfo: WindowServerInfo?,
        windowServerOwnerPID: pid_t?,
        enumerationRoute: FullRescanEnumerationRoute,
        callbackGeneration: UInt64? = nil
    ) {
        self.enumeratedWindow = enumeratedWindow
        self.logicalPID = logicalPID
        self.windowServerInfo = windowServerInfo
        self.windowServerOwnerPID = windowServerOwnerPID
        self.enumerationRoute = enumerationRoute
        self.callbackGeneration = callbackGeneration
    }
}

struct AXManagedWindowIdentity: Sendable {
    let token: WindowToken
    let axRef: AXWindowRef
}

enum AXWindowEnumerationError: Error, Sendable {
    case applicationUnavailable(AXError)
    case contextUnavailable
    case invalidApplicationWindows
    case subscriptionFailed
    case timedOut
}

enum AXWindowEnumerationInspector {
    private struct DecisionEvidenceContext {
        let inspection: AXWindowInspectionContext
        let geometry: WindowAdmissionGeometryEvidence
        let deadline: TimeInterval
    }

    private static let decisionAttributeNames = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        "AXFullScreen",
        kAXCloseButtonAttribute as String,
        kAXFullScreenButtonAttribute as String,
        kAXZoomButtonAttribute as String,
        kAXMinimizeButtonAttribute as String,
        "AXGrowArea",
        "AXMinSize",
        "AXMaxSize"
    ]

    static func enumerateApplication(
        pid: pid_t,
        timeout: TimeInterval,
        context: AXWindowInspectionContext = .unidentified
    ) throws -> [AXEnumeratedWindow] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let appElement = AXUIElementCreateApplication(pid)
        let windowElements = try applicationWindowElements(
            appElement,
            deadline: deadline,
            checkCancellation: { try Task.checkCancellation() }
        )
        var results: [AXEnumeratedWindow] = []
        results.reserveCapacity(windowElements.count)
        for element in windowElements {
            try Task.checkCancellation()
            if let window = try inspect(
                element,
                deadline: deadline,
                context: context,
                checkCancellation: { try Task.checkCancellation() }
            ) {
                results.append(window)
            }
        }
        return results
    }

    static func applicationWindowElements(
        _ appElement: AXUIElement,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> [AXUIElement] {
        try checkCancellation()
        try setRemainingTimeout(on: appElement, until: deadline)
        defer { AXUIElementSetMessagingTimeout(appElement, 0) }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        )
        try checkCancellation()
        _ = try remainingTimeout(until: deadline)
        guard result == .success else {
            throw AXWindowEnumerationError.applicationUnavailable(result)
        }
        guard let elements = value as? [AXUIElement] else {
            throw AXWindowEnumerationError.invalidApplicationWindows
        }
        return elements
    }

    static func inspect(
        _ element: AXUIElement,
        deadline: TimeInterval,
        context: AXWindowInspectionContext = .unidentified,
        checkCancellation: () throws -> Void
    ) throws -> AXEnumeratedWindow? {
        try checkCancellation()
        try setRemainingTimeout(on: element, until: deadline)
        defer { AXUIElementSetMessagingTimeout(element, 0) }

        var windowIdRaw: CGWindowID = 0
        let windowIdResult = _AXUIElementGetWindow(element, &windowIdRaw)
        try checkCancellation()
        guard windowIdResult == .success else { return nil }

        let resolvedPid = try resolvedPID(
            for: element,
            deadline: deadline,
            checkCancellation: checkCancellation
        )
        let resolvedValues = try decisionAttributeValues(
            element,
            context: context,
            deadline: deadline,
            checkCancellation: checkCancellation
        )
        let role = value(at: 0, in: resolvedValues) as? String
        let subrole = value(at: 1, in: resolvedValues) as? String
        guard AXWindowService.shouldTreatAsTopLevelWindow(role: role, subrole: subrole) else {
            return nil
        }

        let geometry = try admissionGeometry(
            for: element,
            values: resolvedValues,
            deadline: deadline,
            checkCancellation: checkCancellation
        )
        let evidence = try decisionEvidence(
            values: resolvedValues,
            context: DecisionEvidenceContext(
                inspection: context,
                geometry: geometry,
                deadline: deadline
            ),
            checkCancellation: checkCancellation
        )
        return AXEnumeratedWindow(
            axRef: AXWindowRef(element: element, windowId: Int(windowIdRaw)),
            axPid: resolvedPid,
            role: role,
            subrole: subrole,
            admissionGeometry: geometry,
            fullscreenAttribute: value(at: 4, in: resolvedValues) as? Bool,
            decisionEvidence: evidence
        )
    }

    private static func resolvedPID(
        for element: AXUIElement,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> pid_t? {
        try setRemainingTimeout(on: element, until: deadline)
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        try checkCancellation()
        return result == .success ? pid : nil
    }

    private static func decisionAttributeValues(
        _ element: AXUIElement,
        context: AXWindowInspectionContext,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> [Any?] {
        let attributes = context.includeTitle
            ? decisionAttributeNames + [kAXTitleAttribute as String]
            : decisionAttributeNames
        var values: CFArray?
        try setRemainingTimeout(on: element, until: deadline)
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            .init(),
            &values
        )
        try checkCancellation()
        guard result == .success else {
            throw AXWindowEnumerationError.applicationUnavailable(result)
        }
        guard let values = values as? [Any?], values.count >= decisionAttributeNames.count else {
            throw AXWindowEnumerationError.invalidApplicationWindows
        }
        return values
    }

    private static func decisionEvidence(
        values: [Any?],
        context: DecisionEvidenceContext,
        checkCancellation: () throws -> Void
    ) throws -> AXWindowDecisionEvidence {
        let fullscreenButtonValue = value(at: 6, in: values)
        let fullscreenButtonState = try fullscreenButtonEnabled(
            fullscreenButtonValue,
            deadline: context.deadline,
            checkCancellation: checkCancellation
        )
        let facts = AXWindowService.makeWindowFacts(
            AXWindowFactAttributeValues(
                role: value(at: 0, in: values) as? String,
                subrole: value(at: 1, in: values) as? String,
                title: context.inspection.includeTitle ? value(at: 12, in: values) as? String : nil,
                closeButton: value(at: 5, in: values),
                fullscreenButton: fullscreenButtonValue,
                fullscreenButtonEnabled: fullscreenButtonState.enabled,
                zoomButton: value(at: 7, in: values),
                minimizeButton: value(at: 8, in: values)
            ),
            appPolicy: context.inspection.appPolicy,
            bundleId: context.inspection.bundleId,
            attributeFetchSucceeded: fullscreenButtonState.succeeded
        )
        let constraints = AXWindowService.resolvedSizeConstraints(
            AXWindowConstraintInputs(
                hasGrowArea: AXWindowService.resolvedAttribute(value(at: 9, in: values)),
                hasZoomButton: AXWindowService.resolvedAttribute(value(at: 7, in: values)),
                subrole: value(at: 1, in: values) as? String,
                minSize: AXWindowService.sizeValue(value(at: 10, in: values)),
                maxSize: AXWindowService.sizeValue(value(at: 11, in: values)),
                currentSize: context.geometry.frame?.size
            )
        )
        return AXWindowDecisionEvidence(facts: facts, sizeConstraints: constraints)
    }

    private static func fullscreenButtonEnabled(
        _ value: Any?,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> (enabled: Bool?, succeeded: Bool) {
        let evidence = AXWindowService.fullscreenButtonEvidence(value)
        guard evidence.succeeded else { return (nil, false) }
        guard let button = evidence.element else { return (nil, true) }
        try setRemainingTimeout(on: button, until: deadline)
        defer { AXUIElementSetMessagingTimeout(button, 0) }
        var enabledValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            button,
            kAXEnabledAttribute as CFString,
            &enabledValue
        )
        try checkCancellation()
        guard result == .success else { return (nil, true) }
        guard let enabledValue else { return (nil, true) }
        guard let enabled = enabledValue as? Bool else { return (nil, false) }
        return (enabled, true)
    }

    private static func admissionGeometry(
        for element: AXUIElement,
        values: [Any?]?,
        deadline: TimeInterval,
        checkCancellation: () throws -> Void
    ) throws -> WindowAdmissionGeometryEvidence {
        try setRemainingTimeout(on: element, until: deadline)
        var isSizeSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXSizeAttribute as CFString,
            &isSizeSettable
        )
        try checkCancellation()
        return WindowAdmissionGeometryEvidence(
            isSizeSettable: result == .success && isSizeSettable.boolValue,
            frame: frame(from: values)
        )
    }

    private static func frame(from values: [Any?]?) -> CGRect? {
        guard let positionValue = value(at: 2, in: values),
              let sizeValue = value(at: 3, in: values),
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAXValue = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }
        return ScreenCoordinateSpace.toAppKit(rect: CGRect(origin: position, size: size))
    }

    private static func value(at index: Int, in values: [Any?]?) -> Any? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func remainingTimeout(until deadline: TimeInterval) throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AXWindowEnumerationError.timedOut }
        return remaining
    }

    private static func setRemainingTimeout(on element: AXUIElement, until deadline: TimeInterval) throws {
        AXUIElementSetMessagingTimeout(element, Float(try remainingTimeout(until: deadline)))
    }
}
