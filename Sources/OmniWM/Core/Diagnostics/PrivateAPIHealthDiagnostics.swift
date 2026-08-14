// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

enum PrivateAPISelfTestOutcome: String, Sendable {
    case works
    case failed
    case inconclusive
}

struct PrivateAPISelfTest: Sendable {
    let api: String
    let outcome: PrivateAPISelfTestOutcome
    let detail: String
}

struct ForeignWindowProbeResult: Sendable {
    let targetPid: pid_t
    let targetWid: UInt32
    let movedDelta: CGPoint?
    let skylightMoved: Bool
    let restored: Bool
    let detail: String
}

struct PrivateAPIProbeReport: Sendable {
    let ranAt: Date
    let selfTests: [PrivateAPISelfTest]
    let foreign: ForeignWindowProbeResult?
}

@MainActor
final class PrivateAPIProbeStore {
    static let shared = PrivateAPIProbeStore()
    var last: PrivateAPIProbeReport?
}

struct PrivateAPIHealthSnapshot: Sendable {
    let connectionId: Int32
    let symbols: [String]
    let displayUUIDResolved: Bool
    let multitouchSymbols: [(name: String, resolved: Bool)]
    let cgsRegistration: String
    let fallbackDump: String
    let lastProbe: PrivateAPIProbeReport?

    func formatted() -> String {
        let trackpad = multitouchSymbols.map { "\($0.name)=\($0.resolved)" }.joined(separator: " ")
        var lines = [
            "skylightConnection=\(connectionId)\(connectionId == 0 ? " (UNAVAILABLE)" : "")",
            "skylightSymbols=\(symbols.count) resolved",
            "displayUUID=\(displayUUIDResolved ? "resolved" : "MISSING")",
            "multitouchSymbols: \(trackpad)",
            "cgsEventRegistration=\(cgsRegistration)",
            "",
            "Fallback / failure firings since launch (by subsystem):",
            fallbackDump,
            "",
            "On-demand probe:"
        ]
        if let lastProbe {
            lines.append(contentsOf: Self.formatProbe(lastProbe))
        } else {
            lines.append("  not run — use Settings ▸ Diagnostics ▸ Run Private-API Probe")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatProbe(_ report: PrivateAPIProbeReport) -> [String] {
        var lines = ["  ranAt=\(report.ranAt.ISO8601Format())"]
        for test in report.selfTests {
            lines.append("  [\(test.outcome.rawValue)] \(test.api) — \(test.detail)")
        }
        if let foreign = report.foreign {
            lines.append(
                "  foreignWindowMove: skylightMovesForeignWindows=\(foreign.skylightMoved ? "YES" : "NO")"
                    + " restored=\(foreign.restored) delta=\(TraceFormat.point(foreign.movedDelta)) \(foreign.detail)"
            )
        } else {
            lines.append("  foreignWindowMove: no eligible foreign window to probe")
        }
        return lines
    }
}

@MainActor
enum PrivateAPIHealthDiagnostics {
    static func snapshot() -> PrivateAPIHealthSnapshot {
        PrivateAPIHealthSnapshot(
            connectionId: SkyLight.shared.getMainConnectionID(),
            symbols: SkyLight.shared.capabilityReport(),
            displayUUIDResolved: SkyLight.displayUUIDResolved,
            multitouchSymbols: MultitouchBinding.resolvedSymbols(),
            cgsRegistration: CGSEventObserver.shared.lastRegistrationSummary,
            fallbackDump: FallbackFiringRecorder.shared.dump(),
            lastProbe: PrivateAPIProbeStore.shared.last
        )
    }

    @discardableResult
    static func runProbe() async -> PrivateAPIProbeReport {
        var tests = skylightTests()
        tests.append(contentsOf: axProbes())
        tests.append(contentsOf: inputProbes())
        tests.append(contentsOf: multitouchProbes())
        tests.append(await captureProbe())
        tests.append(contentsOf: monitorProbes())
        tests.append(contentsOf: systemProbes())
        let sample = SkyLight.shared.queryAllVisibleWindows().first { isEligibleForeignWindow($0) }
        tests.append(contentsOf: sampleWindowTests(sample))
        tests.append(silgenAXWindowTest(sample))
        let report = PrivateAPIProbeReport(
            ranAt: Date(),
            selfTests: tests,
            foreign: activeForeignWindowProbe(sample: sample)
        )
        PrivateAPIProbeStore.shared.last = report
        return report
    }

    private static func skylightTests() -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let cid = sky.getMainConnectionID()
        var tests = [test("SLSMainConnectionID", cid != 0 ? .works : .failed, "cid=\(cid)")]
        let wid = sky.createBorderWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        guard wid != 0 else {
            tests.append(test("SLSNewWindow/CGSNewRegionWithRect", .failed, "createBorderWindow returned 0"))
            return tests
        }
        tests.append(test("SLSNewWindow/CGSNewRegionWithRect", .works, "wid=\(wid)"))
        let target = CGPoint(x: 137, y: 213)
        _ = sky.moveWindow(wid, to: target)
        if let bounds = sky.getWindowBounds(wid) {
            let ok = abs(bounds.origin.x - target.x) < 2 && abs(bounds.origin.y - target.y) < 2
            tests.append(test("SLSMoveWindow+SLSGetWindowBounds", ok ? .works : .failed, TraceFormat.rect(bounds)))
        } else {
            tests.append(test("SLSMoveWindow+SLSGetWindowBounds", .inconclusive, "getWindowBounds nil"))
        }
        if let info = sky.queryWindowInfo(wid) {
            tests.append(test("SLSWindowQuery* iterator", info.id == wid ? .works : .failed, "id=\(info.id)"))
        } else {
            tests.append(test("SLSWindowQuery* iterator", .inconclusive, "queryWindowInfo nil"))
        }
        tests.append(contentsOf: skylightMutationTests(wid))
        sky.releaseBorderWindow(wid)
        tests.append(contentsOf: spaceTests())
        return tests
    }

    private static func skylightMutationTests(_ wid: UInt32) -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let shapeOk = sky.setWindowShape(wid, frame: CGRect(x: 137, y: 213, width: 12, height: 12))
        let configure = sky.configureWindow(wid, resolution: 1, opaque: false)
        let tagsOk = sky.setWindowTags(wid, tags: 0)
        let flushOk = sky.flushWindow(wid)
        let resolutionDetail = configure.resolution
            ? "applied=true"
            : "non-success on macOS 27; return historically ignored, borders functional"
        return [
            test("SLSSetWindowShape", shapeOk ? .works : .failed, "applied=\(shapeOk)"),
            test("SLSSetWindowOpacity", configure.opacity ? .works : .failed, "applied=\(configure.opacity)"),
            test("SLSSetWindowResolution", configure.resolution ? .works : .inconclusive, resolutionDetail),
            test("SLSSetWindowTags", tagsOk ? .works : .failed, "applied=\(tagsOk)"),
            test("SLSFlushWindowContentRegion", flushOk ? .works : .failed, "applied=\(flushOk)"),
            screencaptureSelectionExclusionTest(wid)
        ]
    }

    private static func spaceTests() -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let active = sky.activeSpace()
        let managed = sky.managedSpaces()
        let mode = sky.displaysHaveSeparateSpaces
        return [
            test(
                "SLSGetActiveSpace",
                (active ?? 0) != 0 ? .works : .failed,
                "space=\(active.map(String.init) ?? "nil")"
            ),
            test("SLSCopyManagedDisplaySpaces", managed.isEmpty ? .failed : .works, "displays=\(managed.count)"),
            test("SLSGetSpaceManagementMode", mode == .unavailable ? .failed : .works, "mode=\(mode)")
        ]
    }

    private static func axProbes() -> [PrivateAPISelfTest] {
        let trusted = AXIsProcessTrusted()
        var tests = [test("AXIsProcessTrusted", trusted ? .works : .failed, "trusted=\(trusted)")]
        let app = AXUIElementCreateApplication(getpid())
        var roleValue: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &roleValue)
        tests.append(test(
            "AXUIElementCopyAttributeValue",
            copyErr == .success ? .works : .failed,
            "err=\(copyErr.rawValue)"
        ))
        var observer: AXObserver?
        let createErr = AXObserverCreate(getpid(), privateAPIProbeAXObserverCallback, &observer)
        guard let observer else {
            tests.append(test("AXObserverCreate/Add/Remove", .failed, "observer nil err=\(createErr.rawValue)"))
            return tests
        }
        let note = kAXFocusedWindowChangedNotification as CFString
        let addErr = AXObserverAddNotification(observer, app, note, nil)
        let removeErr = AXObserverRemoveNotification(observer, app, note)
        let ok = createErr == .success && addErr == .success && removeErr == .success
        tests.append(test(
            "AXObserverCreate/Add/Remove",
            ok ? .works : .failed,
            "create=\(createErr.rawValue) add=\(addErr.rawValue) remove=\(removeErr.rawValue)"
        ))
        return tests
    }

    private static func inputProbes() -> [PrivateAPISelfTest] {
        var tests: [PrivateAPISelfTest] = []
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) {
            CFMachPortInvalidate(tap)
            tests.append(test("CGEvent.tapCreate", .works, "listen-only tap created + invalidated"))
        } else {
            tests.append(test("CGEvent.tapCreate", .failed, "nil — input monitoring permission?"))
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E50), id: 0xFFFF)
        let status = RegisterEventHotKey(UInt32(kVK_F19), 0, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            let unregistered = UnregisterEventHotKey(ref) == noErr
            tests.append(test("RegisterEventHotKey", unregistered ? .works : .failed, "register + unregister"))
        } else {
            tests.append(test("RegisterEventHotKey", .inconclusive, "status=\(status) — key may be reserved"))
        }
        tests.append(test("IsSecureEventInputEnabled", .works, "secureInput=\(IsSecureEventInputEnabled())"))
        return tests
    }

    private static func multitouchProbes() -> [PrivateAPISelfTest] {
        let resolved = MultitouchBinding.resolvedSymbols()
        let missing = resolved.filter { !$0.resolved }.map(\.name)
        var tests = [test(
            "MultitouchSupport symbols",
            missing.isEmpty ? .works : .failed,
            missing.isEmpty ? "all \(resolved.count) resolved" : "missing: \(missing.joined(separator: ", "))"
        )]
        if let binding = MultitouchBinding() {
            let count = binding.deviceCount()
            tests.append(test("MTDeviceCreateList", count >= 0 ? .works : .failed, "devices=\(count)"))
        } else {
            tests.append(test("MTDeviceCreateList", .inconclusive, "binding unavailable"))
        }
        return tests
    }

    private static func captureProbe() async -> PrivateAPISelfTest {
        guard CGPreflightScreenCaptureAccess() else {
            return test("SCShareableContent", .inconclusive, "Screen Recording not granted")
        }
        do {
            let content = try await SCShareableContent.current
            return test(
                "SCShareableContent",
                .works,
                "windows=\(content.windows.count) displays=\(content.displays.count)"
            )
        } catch {
            return test("SCShareableContent", .failed, "error=\(error.localizedDescription)")
        }
    }

    private static func monitorProbes() -> [PrivateAPISelfTest] {
        let displayId = NSScreen.main?.displayId
        var tests = [test(
            "NSScreen.displayId",
            displayId != nil ? .works : .failed,
            "main=\(displayId.map(String.init) ?? "nil")"
        )]
        if let displayId {
            let mode = CGDisplayCopyDisplayMode(displayId)
            tests.append(test(
                "CGDisplayCopyDisplayMode",
                mode != nil ? .works : .failed,
                "refreshRate=\(mode?.refreshRate ?? -1)"
            ))
        }
        return tests
    }

    private static func systemProbes() -> [PrivateAPISelfTest] {
        var tests: [PrivateAPISelfTest] = []
        var assertionID: IOPMAssertionID = 0
        let createResult = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            "OmniWM probe" as CFString,
            nil, nil, nil, 1, nil,
            &assertionID
        )
        if createResult == kIOReturnSuccess {
            let released = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
            tests.append(test("IOPMAssertionCreateWithDescription", released ? .works : .failed, "create + release"))
        } else {
            tests.append(test("IOPMAssertionCreateWithDescription", .failed, "create=\(createResult)"))
        }
        let availability = IssueRewritingFactory.make()?.availability ?? .unsupported
        tests.append(test(
            "FoundationModels availability",
            availability == .available ? .works : .inconclusive,
            "\(availability)"
        ))
        tests.append(slpsFocusProbe())
        tests.append(test("GhosttyKit", .inconclusive, "statically linked; surface lifecycle not probed"))
        return tests
    }

    private static func slpsFocusProbe() -> PrivateAPISelfTest {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return test("_SLPSSetFrontProcessWithOptions", .inconclusive, "no frontmost app")
        }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(frontPid, &psn) == noErr else {
            return test("_SLPSSetFrontProcessWithOptions", .failed, "GetProcessForPID failed")
        }
        let status = _SLPSSetFrontProcessWithOptions(&psn, 0, kCPSUserGenerated)
        return test("_SLPSSetFrontProcessWithOptions", status == noErr ? .works : .failed, "re-front status=\(status)")
    }

    private static func sampleWindowTests(_ sample: WindowServerInfo?) -> [PrivateAPISelfTest] {
        guard let sample else {
            return [
                test("SLSWindowIteratorGetResolvedCornerRadii", .inconclusive, "no foreign sample window"),
                test("SLSWindowIteratorGetCornerRadii", .inconclusive, "no foreign sample window"),
                test("SLSCopySpacesForWindows", .inconclusive, "no foreign sample window")
            ]
        }
        let sky = SkyLight.shared
        let cornerSamples = sky.diagnosticCornerSamples(forWindowId: Int(sample.id))
        let spaces = sky.spacesForWindow(sample.id)
        let detail: (WindowCornerSample?) -> String = { cornerSample in
            cornerSample.map {
                "radii=\($0.radii.topLeft),\($0.radii.topRight),\($0.radii.bottomLeft),\($0.radii.bottomRight) size=\($0.observedSize.width)x\($0.observedSize.height)"
            } ?? "nil (window may have square corners)"
        }
        let resolvedTest: PrivateAPISelfTest = if !sky.resolvedCornerRadiiAvailable {
            test("SLSWindowIteratorGetResolvedCornerRadii", .inconclusive, "symbol unavailable")
        } else if let resolved = cornerSamples.resolved {
            test("SLSWindowIteratorGetResolvedCornerRadii", .works, detail(resolved))
        } else {
            test(
                "SLSWindowIteratorGetResolvedCornerRadii",
                .inconclusive,
                "returned no usable value"
            )
        }
        let rawTest = if let raw = cornerSamples.raw {
            test("SLSWindowIteratorGetCornerRadii", .works, detail(raw))
        } else {
            test("SLSWindowIteratorGetCornerRadii", .inconclusive, "returned no usable value")
        }
        return [
            resolvedTest,
            rawTest,
            test("SLSCopySpacesForWindows", spaces.isEmpty ? .inconclusive : .works, "spaces=\(spaces.count)")
        ]
    }

    private static func silgenAXWindowTest(_ sample: WindowServerInfo?) -> PrivateAPISelfTest {
        var psn = ProcessSerialNumber()
        let status = GetProcessForPID(getpid(), &psn)
        guard status == noErr else {
            return test("GetProcessForPID/_AXUIElementGetWindow", .failed, "GetProcessForPID status=\(status)")
        }
        guard let sample else {
            return test("_AXUIElementGetWindow", .inconclusive, "no sample window")
        }
        let app = AXUIElementCreateApplication(sample.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let first = windows.first
        else {
            return test("_AXUIElementGetWindow", .inconclusive, "no AX windows (permission?)")
        }
        guard let wid = getWindowId(from: first) else {
            return test("_AXUIElementGetWindow", .failed, "returned nil")
        }
        return test("_AXUIElementGetWindow", wid != 0 ? .works : .failed, "wid=\(wid)")
    }
}

@MainActor
extension PrivateAPIHealthDiagnostics {
    static func activeForeignWindowProbe(sample: WindowServerInfo?) -> ForeignWindowProbeResult? {
        let sky = SkyLight.shared
        guard let sample = sample ?? sky.queryAllVisibleWindows().first(where: isEligibleForeignWindow) else {
            return nil
        }
        let originSLS = (sky.getWindowBounds(sample.id) ?? sample.frame).origin
        let before = independentOrigin(sample.id)
        DiagnosticsEventRecorder.shared.recordVerbose(
            name: "privateAPIProbe.foreignMove",
            pid: sample.pid,
            windowId: sample.id
        )
        _ = sky.moveWindow(sample.id, to: CGPoint(x: originSLS.x + 6, y: originSLS.y + 6))
        let after = independentOrigin(sample.id)
        let delta: CGPoint? = {
            guard let before, let after else { return nil }
            return CGPoint(x: after.x - before.x, y: after.y - before.y)
        }()
        let moved = delta.map { abs($0.x - 6) < 2 && abs($0.y - 6) < 2 } ?? false
        _ = sky.moveWindow(sample.id, to: originSLS)
        let restoredOrigin = independentOrigin(sample.id)
        let restored: Bool = {
            guard let before, let restoredOrigin else { return !moved }
            return abs(restoredOrigin.x - before.x) < 2 && abs(restoredOrigin.y - before.y) < 2
        }()
        return ForeignWindowProbeResult(
            targetPid: sample.pid,
            targetWid: sample.id,
            movedDelta: delta,
            skylightMoved: moved,
            restored: restored,
            detail: "pid=\(sample.pid) wid=\(sample.id) before=\(TraceFormat.point(before))"
        )
    }

    private static func screencaptureSelectionExclusionTest(_ wid: UInt32) -> PrivateAPISelfTest {
        let sky = SkyLight.shared
        let api = "SLSSetWindowProperty(IgnoreForScreencaptureWindowSelection)"
        guard sky.excludeFromScreencaptureWindowSelection(wid) else {
            return test(api, .failed, "applied=false — border stays selectable by the screenshot window picker")
        }
        let readback = sky.isExcludedFromScreencaptureWindowSelection(wid)
        guard readback == true else {
            return test(api, .inconclusive, "applied=true readback=\(readback.map(String.init) ?? "nil")")
        }
        return test(api, .works, "applied=true readback=true")
    }

    private static func isEligibleForeignWindow(_ info: WindowServerInfo) -> Bool {
        info.pid != getpid() && info.frame.width > 1 && info.frame.height > 1
    }

    private static func independentOrigin(_ wid: UInt32) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return rect.origin
    }

    private static func test(
        _ api: String,
        _ outcome: PrivateAPISelfTestOutcome,
        _ detail: String
    ) -> PrivateAPISelfTest {
        PrivateAPISelfTest(api: api, outcome: outcome, detail: detail)
    }
}

private func privateAPIProbeAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {}

@MainActor
extension WMController {
    @discardableResult
    func runPrivateAPIProbe() async -> PrivateAPIProbeReport {
        let report = await PrivateAPIHealthDiagnostics.runProbe()
        if let wid = report.foreign?.targetWid,
           let entry = workspaceManager.entry(forWindowId: Int(wid))
        {
            layoutRefreshController.requestRelayout(
                reason: .axWindowChanged,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        return report
    }
}
