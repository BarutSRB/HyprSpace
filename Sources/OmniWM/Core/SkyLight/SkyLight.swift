// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum SkyLightWindowOrder: Int32 {
    case below = -1
    case out = 0
    case above = 1
}

enum DisplaySpacesMode: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable
}

struct WindowCornerRadii: Equatable, Sendable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    init(uniform radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    static let zero = WindowCornerRadii(uniform: 0)

    /// Server radius queries can transiently report zero radii for windows whose
    /// rounded-corner metadata is not yet materialized (observed when cycling focus
    /// quickly across columns). A user-selected square corner is stored as a small
    /// nonzero radius, so only an exactly-zero sample is an invalid reading.
    var isAllZero: Bool {
        topLeft == 0 && topRight == 0 && bottomLeft == 0 && bottomRight == 0
    }

    func adding(_ value: CGFloat) -> WindowCornerRadii {
        WindowCornerRadii(
            topLeft: topLeft + value,
            topRight: topRight + value,
            bottomLeft: bottomLeft + value,
            bottomRight: bottomRight + value
        )
    }

    func normalized(to size: CGSize) -> WindowCornerRadii {
        let radii = nonnegative
        guard size.width > 0, size.height > 0 else { return .zero }

        var scale: CGFloat = 1
        scale = min(scale, ratio(limit: size.width, sum: radii.topLeft + radii.topRight))
        scale = min(scale, ratio(limit: size.width, sum: radii.bottomLeft + radii.bottomRight))
        scale = min(scale, ratio(limit: size.height, sum: radii.topLeft + radii.bottomLeft))
        scale = min(scale, ratio(limit: size.height, sum: radii.topRight + radii.bottomRight))
        guard scale < 1 else { return radii }

        return WindowCornerRadii(
            topLeft: radii.topLeft * scale,
            topRight: radii.topRight * scale,
            bottomLeft: radii.bottomLeft * scale,
            bottomRight: radii.bottomRight * scale
        )
    }

    var nonnegative: WindowCornerRadii {
        WindowCornerRadii(
            topLeft: Self.nonnegative(topLeft),
            topRight: Self.nonnegative(topRight),
            bottomLeft: Self.nonnegative(bottomLeft),
            bottomRight: Self.nonnegative(bottomRight)
        )
    }

    private func ratio(limit: CGFloat, sum: CGFloat) -> CGFloat {
        sum > 0 ? limit / sum : 1
    }

    private static func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }
}

enum WindowCornerSource: Equatable, Sendable {
    case resolved
    case raw
}

struct WindowCornerSample: Equatable, Sendable {
    let radii: WindowCornerRadii
    let observedSize: CGSize
    let source: WindowCornerSource
}

struct ManagedDisplaySpaces: Sendable {
    let displayIdentifier: String
    let spaceIds: [UInt64]
    let currentSpaceId: UInt64
    let fullscreenSpaceIds: Set<UInt64>
}

enum NativeSpaceWindowInventoryResult: Equatable, Sendable {
    case unavailable
    case queryFailed
    case authoritative([UInt64: [WindowServerInfo]])
}

@MainActor
final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnectionIDFunc = @convention(c) () -> Int32
    private typealias WindowQueryWindowsFunc = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias WindowQueryResultCopyWindowsFunc = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias WindowIteratorGetCountFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorAdvanceFunc = @convention(c) (CFTypeRef) -> Bool
    private typealias WindowIteratorGetCornerRadiiFunc = @convention(c) (
        CFTypeRef,
        CFIndex
    ) -> Unmanaged<CFArray>?
    private typealias WindowIteratorGetBoundsFunc = @convention(c) (CFTypeRef) -> CGRect
    private typealias WindowIteratorGetWindowIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetPIDFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetLevelFunc = @convention(c) (CFTypeRef) -> Int32
    private typealias WindowIteratorGetTagsFunc = @convention(c) (CFTypeRef) -> UInt64
    private typealias WindowIteratorGetAttributesFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias WindowIteratorGetParentIDFunc = @convention(c) (CFTypeRef) -> UInt32
    private typealias TransactionCreateFunc = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private typealias TransactionCommitFunc = @convention(c) (CFTypeRef, Int32) -> Void
    private typealias TransactionOrderWindowFunc = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    private typealias WindowIsOrderedInFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias TransactionMoveWindowWithGroupFunc = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
    private typealias MoveWindowFunc = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
    private typealias GetWindowBoundsFunc = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
    private typealias NewWindowFunc = @convention(c) (
        Int32,
        Int32,
        Float,
        Float,
        CFTypeRef,
        UnsafeMutablePointer<UInt32>
    ) -> CGError
    private typealias ReleaseWindowFunc = @convention(c) (Int32, UInt32) -> CGError
    private typealias WindowContextCreateFunc = @convention(c) (
        Int32,
        UInt32,
        CFDictionary?
    ) -> Unmanaged<CGContext>?
    private typealias SetWindowShapeFunc = @convention(c) (Int32, UInt32, Float, Float, CFTypeRef) -> CGError
    private typealias SetWindowResolutionFunc = @convention(c) (Int32, UInt32, Float) -> CGError
    private typealias SetWindowOpacityFunc = @convention(c) (Int32, UInt32, Int32) -> CGError
    private typealias SetWindowBackgroundBlurRadiusFunc = @convention(c) (Int32, UInt32, Int32) -> CGError
    private typealias SetWindowTagsFunc = @convention(c) (Int32, UInt32, UnsafePointer<UInt64>, Int32) -> CGError
    private typealias SetWindowPropertyFunc = @convention(c) (Int32, UInt32, CFString, CFTypeRef) -> CGError
    private typealias CopyWindowPropertyFunc = @convention(c) (
        Int32,
        UInt32,
        CFString,
        UnsafeMutablePointer<CFTypeRef?>
    ) -> CGError
    private typealias FlushWindowContentRegionFunc = @convention(c) (Int32, UInt32, CFTypeRef?) -> CGError
    private typealias NewRegionWithRectFunc = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CFTypeRef?>)
        -> CGError
    private typealias TransactionSetWindowLevelFunc = @convention(c) (CFTypeRef, UInt32, Int32) -> Void
    private typealias CopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFunc = @convention(c) (Int32) -> UInt64
    private typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyWindowsWithOptionsAndTagsFunc = @convention(c) (
        Int32,
        UInt32,
        CFArray,
        UInt32,
        UnsafeMutablePointer<UInt64>,
        UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias GetSpaceManagementModeFunc = @convention(c) (Int32) -> Int32
    private typealias DisplayCreateUUIDFromDisplayIDFunc = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?

    typealias ConnectionNotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutableRawPointer?,
        Int32
    ) -> Void
    private typealias RegisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterConnectionNotifyProcFunc = @convention(c) (
        Int32,
        ConnectionNotifyCallback,
        UInt32
    ) -> Int32
    private typealias RequestNotificationsForWindowsFunc = @convention(c) (
        Int32,
        UnsafePointer<UInt32>,
        Int32
    ) -> Int32

    typealias NotifyCallback = @convention(c) (
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        Int32
    ) -> Void
    private typealias RegisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterNotifyProcFunc = @convention(c) (
        NotifyCallback,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32

    private let mainConnectionID: MainConnectionIDFunc
    private let windowQueryWindows: WindowQueryWindowsFunc
    private let windowQueryResultCopyWindows: WindowQueryResultCopyWindowsFunc
    private let windowIteratorGetCount: WindowIteratorGetCountFunc
    private let windowIteratorAdvance: WindowIteratorAdvanceFunc
    private let windowIteratorGetCornerRadii: WindowIteratorGetCornerRadiiFunc
    private let windowIteratorGetResolvedCornerRadii: WindowIteratorGetCornerRadiiFunc?
    private let windowIteratorGetBounds: WindowIteratorGetBoundsFunc
    private let windowIteratorGetWindowID: WindowIteratorGetWindowIDFunc
    private let windowIteratorGetPID: WindowIteratorGetPIDFunc
    private let windowIteratorGetLevel: WindowIteratorGetLevelFunc
    private let windowIteratorGetTags: WindowIteratorGetTagsFunc
    private let windowIteratorGetAttributes: WindowIteratorGetAttributesFunc
    private let windowIteratorGetParentID: WindowIteratorGetParentIDFunc
    private let transactionCreate: TransactionCreateFunc
    private let transactionCommit: TransactionCommitFunc
    private let transactionOrderWindow: TransactionOrderWindowFunc
    private let windowIsOrderedIn: WindowIsOrderedInFunc
    private let transactionMoveWindowWithGroup: TransactionMoveWindowWithGroupFunc
    private let moveWindow: MoveWindowFunc
    private let getWindowBounds: GetWindowBoundsFunc
    private let registerConnectionNotifyProc: RegisterConnectionNotifyProcFunc
    private let unregisterConnectionNotifyProc: UnregisterConnectionNotifyProcFunc
    private let requestNotificationsForWindows: RequestNotificationsForWindowsFunc
    private let registerNotifyProc: RegisterNotifyProcFunc
    private let unregisterNotifyProcFunc: UnregisterNotifyProcFunc
    private let newWindow: NewWindowFunc
    private let releaseWindow: ReleaseWindowFunc
    private let windowContextCreate: WindowContextCreateFunc
    private let setWindowShape: SetWindowShapeFunc
    private let setWindowResolution: SetWindowResolutionFunc
    private let setWindowOpacity: SetWindowOpacityFunc
    private let setWindowBackgroundBlurRadius: SetWindowBackgroundBlurRadiusFunc?
    private let setWindowTags: SetWindowTagsFunc
    private let setWindowProperty: SetWindowPropertyFunc?
    private let copyWindowProperty: CopyWindowPropertyFunc?
    private let flushWindowContentRegion: FlushWindowContentRegionFunc
    private let newRegionWithRect: NewRegionWithRectFunc
    private let transactionSetWindowLevel: TransactionSetWindowLevelFunc
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFunc
    private let getActiveSpace: GetActiveSpaceFunc
    private let copySpacesForWindows: CopySpacesForWindowsFunc
    private let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTagsFunc?
    private let getSpaceManagementMode: GetSpaceManagementModeFunc

    private let capabilitySymbols: [String]

    private let screencaptureSelectionExclusionKey = "IgnoreForScreencaptureWindowSelection" as CFString

    private static let allSpacesMask: Int32 = 0x7
    private static let nativeSpaceWindowOptions: UInt32 = 0x7
    private static let fullscreenSpaceType = 4

    private nonisolated static let displayCreateUUIDFromDisplayID: DisplayCreateUUIDFromDisplayIDFunc? = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
            ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        guard let handle, let symbol = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else { return nil }
        return unsafeBitCast(symbol, to: DisplayCreateUUIDFromDisplayIDFunc.self)
    }()

    nonisolated static var displayUUIDResolved: Bool {
        displayCreateUUIDFromDisplayID != nil
    }

    private init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            fatalError("Failed to load SkyLight framework")
        }

        var capability: [String] = []

        func resolve<T>(_ symbol: String, as _: T.Type) -> T {
            guard let pointer = dlsym(lib, symbol) else {
                fatalError("SkyLight missing required symbol: \(symbol)")
            }
            capability.append(symbol)
            return unsafeBitCast(pointer, to: T.self)
        }

        func resolveOptional<T>(_ symbol: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(lib, symbol) else { return nil }
            capability.append(symbol)
            return unsafeBitCast(pointer, to: T.self)
        }

        mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
        windowQueryWindows = resolve("SLSWindowQueryWindows", as: WindowQueryWindowsFunc.self)
        windowQueryResultCopyWindows = resolve(
            "SLSWindowQueryResultCopyWindows",
            as: WindowQueryResultCopyWindowsFunc.self
        )
        windowIteratorGetCount = resolve("SLSWindowIteratorGetCount", as: WindowIteratorGetCountFunc.self)
        windowIteratorAdvance = resolve("SLSWindowIteratorAdvance", as: WindowIteratorAdvanceFunc.self)
        windowIteratorGetCornerRadii = resolve(
            "SLSWindowIteratorGetCornerRadii",
            as: WindowIteratorGetCornerRadiiFunc.self
        )
        windowIteratorGetResolvedCornerRadii = resolveOptional(
            "SLSWindowIteratorGetResolvedCornerRadii",
            as: WindowIteratorGetCornerRadiiFunc.self
        )
        windowIteratorGetBounds = resolve("SLSWindowIteratorGetBounds", as: WindowIteratorGetBoundsFunc.self)
        windowIteratorGetWindowID = resolve("SLSWindowIteratorGetWindowID", as: WindowIteratorGetWindowIDFunc.self)
        windowIteratorGetPID = resolve("SLSWindowIteratorGetPID", as: WindowIteratorGetPIDFunc.self)
        windowIteratorGetLevel = resolve("SLSWindowIteratorGetLevel", as: WindowIteratorGetLevelFunc.self)
        windowIteratorGetTags = resolve("SLSWindowIteratorGetTags", as: WindowIteratorGetTagsFunc.self)
        windowIteratorGetAttributes = resolve(
            "SLSWindowIteratorGetAttributes",
            as: WindowIteratorGetAttributesFunc.self
        )
        windowIteratorGetParentID = resolve("SLSWindowIteratorGetParentID", as: WindowIteratorGetParentIDFunc.self)
        transactionCreate = resolve("SLSTransactionCreate", as: TransactionCreateFunc.self)
        transactionCommit = resolve("SLSTransactionCommit", as: TransactionCommitFunc.self)
        transactionOrderWindow = resolve("SLSTransactionOrderWindow", as: TransactionOrderWindowFunc.self)
        windowIsOrderedIn = resolve("SLSWindowIsOrderedIn", as: WindowIsOrderedInFunc.self)
        transactionMoveWindowWithGroup = resolve(
            "SLSTransactionMoveWindowWithGroup",
            as: TransactionMoveWindowWithGroupFunc.self
        )
        moveWindow = resolve("SLSMoveWindow", as: MoveWindowFunc.self)
        getWindowBounds = resolve("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)
        registerConnectionNotifyProc = resolve(
            "SLSRegisterConnectionNotifyProc",
            as: RegisterConnectionNotifyProcFunc.self
        )
        unregisterConnectionNotifyProc = resolve(
            "SLSRemoveConnectionNotifyProc",
            as: UnregisterConnectionNotifyProcFunc.self
        )
        requestNotificationsForWindows = resolve(
            "SLSRequestNotificationsForWindows",
            as: RequestNotificationsForWindowsFunc.self
        )
        registerNotifyProc = resolve("SLSRegisterNotifyProc", as: RegisterNotifyProcFunc.self)
        unregisterNotifyProcFunc = resolve("SLSRemoveNotifyProc", as: UnregisterNotifyProcFunc.self)
        newWindow = resolve("SLSNewWindow", as: NewWindowFunc.self)
        releaseWindow = resolve("SLSReleaseWindow", as: ReleaseWindowFunc.self)
        windowContextCreate = resolve("SLWindowContextCreate", as: WindowContextCreateFunc.self)
        setWindowShape = resolve("SLSSetWindowShape", as: SetWindowShapeFunc.self)
        setWindowResolution = resolve("SLSSetWindowResolution", as: SetWindowResolutionFunc.self)
        setWindowOpacity = resolve("SLSSetWindowOpacity", as: SetWindowOpacityFunc.self)
        setWindowBackgroundBlurRadius = resolveOptional(
            "SLSSetWindowBackgroundBlurRadius",
            as: SetWindowBackgroundBlurRadiusFunc.self
        )
        setWindowTags = resolve("SLSSetWindowTags", as: SetWindowTagsFunc.self)
        setWindowProperty = resolveOptional("SLSSetWindowProperty", as: SetWindowPropertyFunc.self)
        copyWindowProperty = resolveOptional("SLSCopyWindowProperty", as: CopyWindowPropertyFunc.self)
        flushWindowContentRegion = resolve("SLSFlushWindowContentRegion", as: FlushWindowContentRegionFunc.self)
        newRegionWithRect = resolve("CGSNewRegionWithRect", as: NewRegionWithRectFunc.self)
        transactionSetWindowLevel = resolve("SLSTransactionSetWindowLevel", as: TransactionSetWindowLevelFunc.self)
        copyManagedDisplaySpaces = resolve("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFunc.self)
        getActiveSpace = resolve("SLSGetActiveSpace", as: GetActiveSpaceFunc.self)
        copySpacesForWindows = resolve("SLSCopySpacesForWindows", as: CopySpacesForWindowsFunc.self)
        copyWindowsWithOptionsAndTags = resolveOptional(
            "SLSCopyWindowsWithOptionsAndTags",
            as: CopyWindowsWithOptionsAndTagsFunc.self
        )
        getSpaceManagementMode = resolve("SLSGetSpaceManagementMode", as: GetSpaceManagementModeFunc.self)

        capabilitySymbols = capability
    }

    func getMainConnectionID() -> Int32 {
        mainConnectionID()
    }

    func capabilityReport() -> [String] {
        capabilitySymbols
    }

    var resolvedCornerRadiiAvailable: Bool {
        windowIteratorGetResolvedCornerRadii != nil
    }

    func cornerSample(forWindowId wid: Int) -> WindowCornerSample? {
        queryWindowIterator(forWindowId: wid) { iterator in
            cornerSample(from: iterator)
        }
    }

    func diagnosticCornerSamples(
        forWindowId wid: Int
    ) -> (resolved: WindowCornerSample?, raw: WindowCornerSample?) {
        queryWindowIterator(forWindowId: wid) { iterator in
            let observedSize = windowIteratorGetBounds(iterator).size
            let resolved = windowIteratorGetResolvedCornerRadii?(iterator, 0)?.takeRetainedValue()
            let raw = windowIteratorGetCornerRadii(iterator, 0)?.takeRetainedValue()
            return Self.diagnosticCornerSamples(
                resolved: resolved,
                raw: raw,
                observedSize: observedSize
            )
        } ?? (nil, nil)
    }

    private func queryWindowIterator<T>(forWindowId wid: Int, _ read: (CFTypeRef) -> T?) -> T? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(wid)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        let windowArray = [widNumber] as CFArray

        guard let query = windowQueryWindows(cid, windowArray, 0)?.takeRetainedValue() else { return nil }
        guard let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }

        guard windowIteratorGetCount(iterator) > 0,
              windowIteratorAdvance(iterator)
        else {
            return nil
        }
        return read(iterator)
    }

    private func cornerSample(from iterator: CFTypeRef) -> WindowCornerSample? {
        let observedSize = windowIteratorGetBounds(iterator).size
        let resolved = windowIteratorGetResolvedCornerRadii?(iterator, 0)?.takeRetainedValue()
        if let sample = Self.cornerSample(resolved: resolved, raw: nil, observedSize: observedSize) {
            return sample
        }
        let raw = windowIteratorGetCornerRadii(iterator, 0)?.takeRetainedValue()
        return Self.cornerSample(resolved: nil, raw: raw, observedSize: observedSize)
    }

    /// Builds a corner sample from resolved and/or raw SkyLight radii arrays,
    /// preferring resolved radii but falling back to raw ones. Zero radii are
    /// treated as an invalid (not-yet-materialized) reading, not a square window.
    /// - Returns: A sample when a non-zero radii array parses against the observed
    ///   size; `nil` when neither array yields a usable reading.
    static func cornerSample(
        resolved: CFArray?,
        raw: CFArray?,
        observedSize: CGSize
    ) -> WindowCornerSample? {
        guard observedSize.width.isFinite,
              observedSize.height.isFinite,
              observedSize.width > 0,
              observedSize.height > 0
        else {
            return nil
        }
        if let radii = parseCornerRadii(resolved), !radii.isAllZero {
            return WindowCornerSample(radii: radii, observedSize: observedSize, source: .resolved)
        }
        guard let radii = parseCornerRadii(raw), !radii.isAllZero else { return nil }
        return WindowCornerSample(radii: radii, observedSize: observedSize, source: .raw)
    }

    static func diagnosticCornerSamples(
        resolved: CFArray?,
        raw: CFArray?,
        observedSize: CGSize
    ) -> (resolved: WindowCornerSample?, raw: WindowCornerSample?) {
        (
            resolved: cornerSample(resolved: resolved, raw: nil, observedSize: observedSize),
            raw: cornerSample(resolved: nil, raw: raw, observedSize: observedSize)
        )
    }

    static func parseCornerRadii(_ values: CFArray?) -> WindowCornerRadii? {
        guard let values else { return nil }
        let count = CFArrayGetCount(values)
        guard count == 1 || count == 4 else { return nil }

        func radius(at index: CFIndex) -> CGFloat? {
            let pointer = CFArrayGetValueAtIndex(values, index)
            let value = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
            var radius = 0.0
            guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .doubleType, &radius),
                  radius.isFinite,
                  radius >= 0
            else {
                return nil
            }
            return CGFloat(radius)
        }

        guard let topLeft = radius(at: 0) else { return nil }
        if count == 1 {
            return WindowCornerRadii(uniform: topLeft)
        }
        guard let topRight = radius(at: 1),
              let bottomRight = radius(at: 2),
              let bottomLeft = radius(at: 3)
        else {
            return nil
        }
        return WindowCornerRadii(
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight
        )
    }

    private func commit(_ transaction: CFTypeRef) {
        transactionCommit(transaction, 0)
    }

    func orderWindow(_ wid: UInt32, relativeTo targetWid: UInt32, order: SkyLightWindowOrder = .above) {
        let cid = getMainConnectionID()
        guard let transaction = transactionCreate(cid)?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return
        }
        transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        commit(transaction)
    }

    func isWindowOrderedIn(_ wid: UInt32) -> Bool? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var orderedIn: UInt8 = 0
        let result = windowIsOrderedIn(cid, wid, &orderedIn)
        guard result == .success else { return nil }
        return orderedIn != 0
    }

    func moveWindow(_ wid: UInt32, to point: CGPoint) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var pt = point
        let result = moveWindow(cid, wid, &pt)
        return result == .success
    }

    func getWindowBounds(_ wid: UInt32) -> CGRect? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        var rect = CGRect.zero
        let result = getWindowBounds(cid, wid, &rect)
        guard result == .success else { return nil }
        return rect
    }

    func displayId(forSpaceId spaceId: UInt64, among monitors: [Monitor]) -> CGDirectDisplayID? {
        guard spaceId != 0, !monitors.isEmpty else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0, let spacesRef = copyManagedDisplaySpaces(cid)?.takeRetainedValue() else { return nil }
        guard let displaySpaces = spacesRef as? [[String: Any]] else { return nil }

        var displayIdByIdentifier: [String: CGDirectDisplayID] = [:]
        for monitor in monitors {
            displayIdByIdentifier[String(monitor.displayId)] = monitor.displayId
            if let identifier = monitor.displayUUID {
                displayIdByIdentifier[identifier] = monitor.displayId
            }
        }
        if let main = monitors.first(where: \.isMain) ?? monitors.first {
            displayIdByIdentifier["Main"] = main.displayId
        }

        for display in displaySpaces {
            guard Self.displaySpaces(display, contains: spaceId),
                  let identifier = display["Display Identifier"] as? String,
                  let displayId = displayIdByIdentifier[identifier]
            else {
                continue
            }
            return displayId
        }

        return nil
    }

    func activeSpace() -> UInt64? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        let space = getActiveSpace(cid)
        return space != 0 ? space : nil
    }

    var displaysHaveSeparateSpaces: DisplaySpacesMode {
        let cid = getMainConnectionID()
        guard cid != 0 else { return .unavailable }
        return getSpaceManagementMode(cid) == 1 ? .enabled : .disabled
    }

    func spacesForWindow(_ windowId: UInt32) -> [UInt64] {
        let cid = getMainConnectionID()
        guard cid != 0 else { return [] }
        var widValue = Int32(bitPattern: windowId)
        guard let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue) else { return [] }
        let windowArray = [widNumber] as CFArray
        guard let result = copySpacesForWindows(cid, Self.allSpacesMask, windowArray)?.takeRetainedValue()
        else { return [] }
        guard let spaceValues = result as? [Any] else { return [] }
        return spaceValues.compactMap(Self.numericUInt64).filter { $0 != 0 }
    }

    func spaceForWindow(_ windowId: UInt32) -> UInt64? {
        spacesForWindow(windowId).first
    }

    func nativeSpaceWindowInventory(
        spaceIds: Set<UInt64>
    ) -> NativeSpaceWindowInventoryResult {
        guard !spaceIds.contains(0) else { return .queryFailed }
        guard !spaceIds.isEmpty else { return .authoritative([:]) }
        guard let copyWindowsWithOptionsAndTags else { return .unavailable }

        let cid = getMainConnectionID()
        guard cid != 0 else { return .queryFailed }

        var windowIdsBySpace: [UInt64: [UInt32]] = [:]
        windowIdsBySpace.reserveCapacity(spaceIds.count)
        var seenWindowIds = Set<UInt32>()

        for spaceId in spaceIds {
            guard let windowIds = nativeSpaceWindowIds(
                spaceId: spaceId,
                connectionId: cid,
                copyWindowsWithOptionsAndTags: copyWindowsWithOptionsAndTags
            ) else {
                return .queryFailed
            }
            windowIdsBySpace[spaceId] = windowIds
            seenWindowIds.formUnion(windowIds)
        }

        guard !seenWindowIds.isEmpty else {
            return .authoritative(windowIdsBySpace.mapValues { _ in [] })
        }

        guard let windowInfoById = queryWindowInfo(windowIds: seenWindowIds) else { return .queryFailed }

        guard let inventory = Self.mergeNativeSpaceWindowInventory(
            windowIdsBySpace: windowIdsBySpace,
            windowInfoById: windowInfoById
        ) else {
            return .queryFailed
        }
        return .authoritative(inventory)
    }

    func queryWindowInfo(
        windowIds: Set<UInt32>
    ) -> [UInt32: WindowServerInfo]? {
        guard !windowIds.isEmpty else { return [:] }
        let cid = getMainConnectionID()
        guard cid != 0,
              let windowCount = UInt32(exactly: windowIds.count)
        else {
            return nil
        }

        let windowNumbers = windowIds.map { NSNumber(value: $0) } as CFArray
        guard let query = windowQueryWindows(cid, windowNumbers, windowCount)?.takeRetainedValue() else { return nil }
        guard let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }

        var windowInfoById: [UInt32: WindowServerInfo] = [:]
        windowInfoById.reserveCapacity(windowIds.count)
        while windowIteratorAdvance(iterator) {
            let windowId = windowIteratorGetWindowID(iterator)
            guard windowIds.contains(windowId) else { continue }
            windowInfoById[windowId] = WindowServerInfo(
                id: windowId,
                pid: windowIteratorGetPID(iterator),
                level: windowIteratorGetLevel(iterator),
                frame: windowIteratorGetBounds(iterator),
                tags: windowIteratorGetTags(iterator),
                attributes: windowIteratorGetAttributes(iterator),
                parentId: windowIteratorGetParentID(iterator)
            )
        }
        return windowInfoById
    }

    private func nativeSpaceWindowIds(
        spaceId: UInt64,
        connectionId: Int32,
        copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTagsFunc
    ) -> [UInt32]? {
        let spaces = [NSNumber(value: Int64(bitPattern: spaceId))] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = copyWindowsWithOptionsAndTags(
            connectionId,
            0,
            spaces,
            Self.nativeSpaceWindowOptions,
            &setTags,
            &clearTags
        )?.takeRetainedValue() else {
            return nil
        }

        var windowIds: [UInt32] = []
        let count = CFArrayGetCount(windows)
        windowIds.reserveCapacity(count)
        for index in 0 ..< count {
            let pointer = CFArrayGetValueAtIndex(windows, index)
            let rawWindowId = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard let numericWindowId = Self.numericUInt64(rawWindowId),
                  let windowId = UInt32(exactly: numericWindowId),
                  windowId != 0
            else {
                return nil
            }
            windowIds.append(windowId)
        }
        return windowIds
    }

    nonisolated static func mergeNativeSpaceWindowInventory(
        windowIdsBySpace: [UInt64: [UInt32]],
        windowInfoById: [UInt32: WindowServerInfo]
    ) -> [UInt64: [WindowServerInfo]]? {
        var inventory: [UInt64: [WindowServerInfo]] = [:]
        inventory.reserveCapacity(windowIdsBySpace.count)

        for (spaceId, windowIds) in windowIdsBySpace {
            var windows: [WindowServerInfo] = []
            windows.reserveCapacity(windowIds.count)
            var seenWindowIds = Set<UInt32>()
            seenWindowIds.reserveCapacity(windowIds.count)
            for windowId in windowIds where seenWindowIds.insert(windowId).inserted {
                guard let info = windowInfoById[windowId] else { return nil }
                windows.append(info)
            }
            inventory[spaceId] = windows
        }

        return inventory
    }

    nonisolated static func isSuitableNativeSpaceWindow(_ info: WindowServerInfo) -> Bool {
        guard info.id != 0, info.pid > 0 else { return false }
        guard info.parentId == 0 else { return false }
        guard info.level == 0 || info.level == 3 || info.level == 8 else { return false }
        return info.hasDocumentTag || info.hasFloatingTag
    }

    func managedSpaces() -> [ManagedDisplaySpaces] {
        let cid = getMainConnectionID()
        guard cid != 0, let spacesRef = copyManagedDisplaySpaces(cid)?.takeRetainedValue() else { return [] }
        guard let displaySpaces = spacesRef as? [[String: Any]] else { return [] }

        return displaySpaces.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            var spaceIds: [UInt64] = []
            var fullscreenSpaceIds: Set<UInt64> = []
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    guard let spaceId = Self.spaceId(space) else { continue }
                    spaceIds.append(spaceId)
                    if Self.spaceType(space) == Self.fullscreenSpaceType {
                        fullscreenSpaceIds.insert(spaceId)
                    }
                }
            }
            let currentSpaceId = (display["Current Space"] as? [String: Any]).flatMap(Self.spaceId) ?? 0
            return ManagedDisplaySpaces(
                displayIdentifier: identifier,
                spaceIds: spaceIds,
                currentSpaceId: currentSpaceId,
                fullscreenSpaceIds: fullscreenSpaceIds
            )
        }
    }

    nonisolated static func displayUUID(for displayId: CGDirectDisplayID) -> String? {
        guard let uuid = displayCreateUUIDFromDisplayID?(displayId)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid)
        else { return nil }
        return string as String
    }

    private static func displaySpaces(_ display: [String: Any], contains spaceId: UInt64) -> Bool {
        if let current = display["Current Space"] as? [String: Any],
           space(current, hasId: spaceId)
        {
            return true
        }
        guard let spaces = display["Spaces"] as? [[String: Any]] else { return false }
        return spaces.contains { space($0, hasId: spaceId) }
    }

    private static func space(_ space: [String: Any], hasId spaceId: UInt64) -> Bool {
        numericUInt64(space["id64"]) == spaceId ||
            numericUInt64(space["ManagedSpaceID"]) == spaceId ||
            numericUInt64(space["id"]) == spaceId
    }

    private static func spaceId(_ space: [String: Any]) -> UInt64? {
        numericUInt64(space["id64"]) ?? numericUInt64(space["ManagedSpaceID"]) ?? numericUInt64(space["id"])
    }

    private static func spaceType(_ space: [String: Any]) -> Int? {
        switch space["type"] {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private static func numericUInt64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            value
        case let value as UInt32:
            UInt64(value)
        case let value as UInt:
            UInt64(value)
        case let value as Int where value >= 0:
            UInt64(value)
        case let value as NSNumber:
            value.uint64Value
        case let value as String:
            UInt64(value)
        default:
            nil
        }
    }

    private var scopedTransaction: CFTypeRef?

    func withTransactionScope(_ body: () -> Void) {
        guard scopedTransaction == nil,
              let transaction = transactionCreate(getMainConnectionID())?.takeRetainedValue()
        else {
            body()
            return
        }
        scopedTransaction = transaction
        body()
        scopedTransaction = nil
        commit(transaction)
    }

    private func withTransaction(_ ops: (CFTypeRef) -> Void) {
        if let transaction = scopedTransaction {
            ops(transaction)
            return
        }
        guard let transaction = transactionCreate(getMainConnectionID())?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return
        }
        ops(transaction)
        commit(transaction)
    }

    enum TransactionSubmissionResult: Equatable, Sendable {
        case submitted
        case deferred
        case unavailable
    }

    @discardableResult
    func batchMoveWindows(
        _ positions: [(windowId: UInt32, origin: CGPoint)]
    ) -> TransactionSubmissionResult {
        guard !positions.isEmpty else { return .submitted }
        if let transaction = scopedTransaction {
            for position in positions {
                transactionMoveWindowWithGroup(
                    transaction,
                    position.windowId,
                    position.origin
                )
            }
            return .deferred
        }
        guard let transaction = transactionCreate(getMainConnectionID())?.takeRetainedValue() else {
            FallbackFiringRecorder.shared.note(.skylight, "transactionCreateNil")
            return .unavailable
        }
        for position in positions {
            transactionMoveWindowWithGroup(
                transaction,
                position.windowId,
                position.origin
            )
        }
        commit(transaction)
        return .submitted
    }

    func queryAllVisibleWindows() -> [WindowServerInfo] {
        let cid = getMainConnectionID()
        guard cid != 0 else { return [] }

        let emptyArray = [] as CFArray
        guard let query = windowQueryWindows(cid, emptyArray, 0)?.takeRetainedValue() else { return [] }
        guard let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return [] }

        var results: [WindowServerInfo] = []

        while windowIteratorAdvance(iterator) {
            let parentId = windowIteratorGetParentID(iterator)
            guard parentId == 0 else { continue }

            let level = windowIteratorGetLevel(iterator)
            guard level == 0 || level == 3 || level == 8 else { continue }

            let tags = windowIteratorGetTags(iterator)
            let attributes = windowIteratorGetAttributes(iterator)

            let hasVisibleAttribute = (attributes & 0x2) != 0
            let hasTagBit54 = (tags & 0x0040_0000_0000_0000) != 0
            guard hasVisibleAttribute || hasTagBit54 else { continue }
            let hasDocumentTag = WindowServerInfo.hasDocumentTag(tags)
            let hasFloatingTag = WindowServerInfo.hasFloatingTag(tags)
            let hasModalTag = WindowServerInfo.hasModalTag(tags)
            guard hasDocumentTag || (hasFloatingTag && hasModalTag) else { continue }

            let wid = windowIteratorGetWindowID(iterator)
            let pid = windowIteratorGetPID(iterator)
            let bounds = windowIteratorGetBounds(iterator)
            let info = WindowServerInfo(
                id: wid,
                pid: pid,
                level: level,
                frame: bounds,
                tags: tags,
                attributes: attributes,
                parentId: parentId
            )

            results.append(info)
        }

        return results
    }

    func queryWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(windowId)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        let windowArray = [widNumber] as CFArray

        guard let query = windowQueryWindows(cid, windowArray, 1)?.takeRetainedValue() else { return nil }
        guard let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }
        guard windowIteratorAdvance(iterator) else { return nil }

        let wid = windowIteratorGetWindowID(iterator)
        let pid = windowIteratorGetPID(iterator)
        let level = windowIteratorGetLevel(iterator)
        let bounds = windowIteratorGetBounds(iterator)
        let tags = windowIteratorGetTags(iterator)
        let attributes = windowIteratorGetAttributes(iterator)
        let parentId = windowIteratorGetParentID(iterator)

        return WindowServerInfo(
            id: wid,
            pid: pid,
            level: level,
            frame: bounds,
            tags: tags,
            attributes: attributes,
            parentId: parentId
        )
    }

    func registerForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = registerConnectionNotifyProc(cid, callback, event.rawValue, context)
        return result == 0
    }

    func unregisterForNotification(
        event: CGSEventType,
        callback: @escaping ConnectionNotifyCallback
    ) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        let result = unregisterConnectionNotifyProc(cid, callback, event.rawValue)
        return result == 0
    }

    func registerNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let result = registerNotifyProc(callback, event.rawValue, context)
        return result == 0
    }

    func unregisterNotifyProc(
        event: CGSEventType,
        callback: @escaping NotifyCallback,
        context: UnsafeMutableRawPointer? = nil
    ) -> Bool {
        let result = unregisterNotifyProcFunc(callback, event.rawValue, context)
        return result == 0
    }

    func subscribeToWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        guard !windowIds.isEmpty else {
            return true
        }
        let cid = getMainConnectionID()
        guard cid != 0 else {
            return false
        }
        let result = windowIds.withUnsafeBufferPointer { buffer in
            requestNotificationsForWindows(cid, buffer.baseAddress!, Int32(windowIds.count))
        }
        return result == 0
    }

    func getWindowTitle(_ windowId: UInt32) -> String? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, CGWindowID(windowId)) as? [[String: Any]],
              let windowInfo = windowList.first,
              let title = windowInfo[kCGWindowName as String] as? String
        else { return nil }
        return title
    }

    func createBorderWindow(frame: CGRect) -> UInt32 {
        let cid = getMainConnectionID()
        guard cid != 0 else { return 0 }

        var region: CFTypeRef?
        var rect = frame
        _ = newRegionWithRect(&rect, &region)
        guard let region else { return 0 }

        var wid: UInt32 = 0
        if newWindow(cid, 2, -9999, -9999, region, &wid) != .success {
            FallbackFiringRecorder.shared.note(.skylight, "newWindowFailed")
        }
        return wid
    }

    func releaseBorderWindow(_ wid: UInt32) {
        let cid = getMainConnectionID()
        guard cid != 0 else { return }
        if releaseWindow(cid, wid) != .success {
            FallbackFiringRecorder.shared.note(.skylight, "releaseWindowFailed")
        }
    }

    func createWindowContext(for wid: UInt32) -> CGContext? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        return windowContextCreate(cid, wid, nil)?.takeRetainedValue()
    }

    @discardableResult
    func setWindowShape(_ wid: UInt32, frame: CGRect) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }

        var region: CFTypeRef?
        var rect = frame
        _ = newRegionWithRect(&rect, &region)
        guard let region else { return false }

        let ok = setWindowShape(cid, wid, -9999, -9999, region) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowShapeFailed") }
        return ok
    }

    @discardableResult
    func configureWindow(_ wid: UInt32, resolution: Float, opaque: Bool) -> (resolution: Bool, opacity: Bool) {
        let cid = getMainConnectionID()
        guard cid != 0 else { return (false, false) }
        let resolutionOk = setWindowResolution(cid, wid, resolution) == .success
        let opacityOk = setWindowOpacity(cid, wid, opaque ? 1 : 0) == .success
        if !opacityOk { FallbackFiringRecorder.shared.note(.skylight, "setWindowOpacityFailed") }
        return (resolutionOk, opacityOk)
    }

    @discardableResult
    func setWindowBackgroundBlurRadius(_ wid: UInt32, radius: Int) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0, let setWindowBackgroundBlurRadius else { return false }
        let ok = setWindowBackgroundBlurRadius(cid, wid, Int32(radius)) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowBackgroundBlurRadiusFailed") }
        return ok
    }

    @discardableResult
    func setWindowTags(_ wid: UInt32, tags: UInt64) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        var tagsValue = tags
        let ok = setWindowTags(cid, wid, &tagsValue, 64) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "setWindowTagsFailed") }
        return ok
    }

    @discardableResult
    func excludeFromScreencaptureWindowSelection(_ wid: UInt32) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0, let setWindowProperty else {
            FallbackFiringRecorder.shared.note(.skylight, "screencaptureSelectionExclusionUnavailable")
            return false
        }
        let ok = setWindowProperty(cid, wid, screencaptureSelectionExclusionKey, kCFBooleanTrue) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "screencaptureSelectionExclusionFailed") }
        return ok
    }

    func isExcludedFromScreencaptureWindowSelection(_ wid: UInt32) -> Bool? {
        let cid = getMainConnectionID()
        guard cid != 0, let copyWindowProperty else { return nil }
        var value: CFTypeRef?
        guard copyWindowProperty(cid, wid, screencaptureSelectionExclusionKey, &value) == .success,
              let value
        else { return nil }
        return (value as AnyObject) === (kCFBooleanTrue as AnyObject)
    }

    @discardableResult
    func flushWindow(_ wid: UInt32) -> Bool {
        let cid = getMainConnectionID()
        guard cid != 0 else { return false }
        let ok = flushWindowContentRegion(cid, wid, nil) == .success
        if !ok { FallbackFiringRecorder.shared.note(.skylight, "flushWindowFailed") }
        return ok
    }

    func transactionMove(_ wid: UInt32, origin: CGPoint) {
        withTransaction { transaction in
            transactionMoveWindowWithGroup(transaction, wid, origin)
        }
    }

    func transactionMoveAndOrder(
        _ wid: UInt32,
        origin: CGPoint,
        level: Int32,
        relativeTo targetWid: UInt32,
        order: SkyLightWindowOrder
    ) {
        withTransaction { transaction in
            transactionMoveWindowWithGroup(transaction, wid, origin)
            transactionSetWindowLevel(transaction, wid, level)
            transactionOrderWindow(transaction, wid, order.rawValue, targetWid)
        }
    }

    func transactionHide(_ wid: UInt32) {
        withTransaction { transaction in
            transactionOrderWindow(transaction, wid, SkyLightWindowOrder.out.rawValue, 0)
        }
    }
}

enum CGSEventType: UInt32 {
    case windowClosed = 804
    case windowMoved = 806
    case windowResized = 807
    case windowOrderChanged = 808
    case windowTitleChanged = 1322
    case spaceWindowCreated = 1325
    case spaceWindowDestroyed = 1326
    case frontmostApplicationChanged = 1508
    case all = 0xFFFF_FFFF
}

struct WindowServerInfo: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let level: Int32
    let frame: CGRect
    var tags: UInt64 = 0
    var attributes: UInt32 = 0
    var parentId: UInt32 = 0
    var title: String?

    static func hasDocumentTag(_ tags: UInt64) -> Bool {
        (tags & 0x1) != 0
    }

    static func hasFloatingTag(_ tags: UInt64) -> Bool {
        (tags & 0x2) != 0
    }

    static func hasModalTag(_ tags: UInt64) -> Bool {
        (tags & 0x8000_0000) != 0
    }

    var hasDocumentTag: Bool {
        Self.hasDocumentTag(tags)
    }

    var hasFloatingTag: Bool {
        Self.hasFloatingTag(tags)
    }

    var hasModalTag: Bool {
        Self.hasModalTag(tags)
    }

    var hasParentWindow: Bool {
        parentId != 0
    }

    var hasTransientSurfaceEvidence: Bool {
        hasParentWindow || (hasFloatingTag && !hasDocumentTag)
    }
}
