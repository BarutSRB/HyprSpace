// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class AppVisibilityDiagnosticsTests: XCTestCase {
    func testReportComparesWorldAXAndWindowVisibilityState() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.enableNiriLayout()
        controller.enableDwindleLayout()
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = addWindow(pid: 881_001, windowId: 881_101, workspaceId: workspaceId, controller: controller)
        let hiddenState = HiddenState(
            proportionalPosition: CGPoint(x: 0.5, y: 0.5),
            referenceMonitorId: nil,
            reason: .scratchpad
        )
        controller.workspaceManager.setHiddenState(hiddenState, for: token)
        controller.workspaceManager.setLayoutReason(.nativeFullscreen, for: token)
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .service)
        controller.axManager.setMacOSAppHidden(
            true,
            pid: token.pid,
            entries: [(pid: token.pid, windowId: token.windowId)]
        )
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))
        let reveal = controller.intentLedger.beginAppRevealFocus(
            token: token,
            workspaceId: workspaceId,
            handleIdentity: ObjectIdentifier(handle),
            pendingApps: [
                token.pid: controller.workspaceManager.appVisibilityGeneration(for: token.pid)
            ],
            focusFingerprint: AppRevealFocusFingerprint(
                selectedManagedToken: nil,
                pendingFocusedToken: nil,
                pendingFocusedWorkspaceId: nil,
                nativeFocusOwner: .none,
                interactionMonitorId: nil,
                activeWorkspaceIdsByMonitor: [:]
            ),
            destination: .scratchpad(index: 1, monitorId: nil)
        )
        defer {
            controller.axManager.setMacOSAppHidden(
                false,
                pid: token.pid,
                entries: [(pid: token.pid, windowId: token.windowId)]
            )
        }

        let report = RuntimeDiagnosticsReport.build(controller, traceLimit: 10)

        XCTAssertTrue(report.contains("== macOS App Visibility State =="))
        XCTAssertTrue(report.contains("pid=\(token.pid) worldHidden=true generation=1"))
        XCTAssertTrue(report.contains("axManagerHidden=true appAXHidden=true"))
        XCTAssertTrue(report.contains("windows=1 workspaces=1 activeWorkspaces=1"))
        XCTAssertTrue(report.contains("pendingReveal=id:\(reveal.id),win:\(token.windowId)"))
        XCTAssertTrue(report.contains("destination:scratchpad"))
        XCTAssertTrue(report.contains("hidden=scratchpad layout=nativeFullscreen"))
        XCTAssertTrue(report.contains("sync=unverified-os"))
        XCTAssertTrue(report.contains("projection workspace=\(workspaceId.uuidString) expectedExcluded=1"))
        XCTAssertTrue(report.contains("niri=excluded:1,missing:0,unexpected:0,match:true"), report)
        XCTAssertTrue(report.contains("dwindle=excluded:1,missing:0,unexpected:0,match:true"), report)
    }

    func testReportSurfacesVisibilityFenceDesynchronization() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = addWindow(pid: 881_002, windowId: 881_102, workspaceId: workspaceId, controller: controller)

        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .service)

        let report = RuntimeDiagnosticsReport.build(controller, traceLimit: 10)

        XCTAssertTrue(report.contains("pid=\(token.pid) worldHidden=true"))
        XCTAssertTrue(report.contains("axManagerHidden=false appAXHidden=false"))
        XCTAssertTrue(report.contains("sync=DESYNC"))
    }

    func testReportSurfacesStaleProjectionExclusionsWithoutManagedWindows() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.enableNiriLayout()
        controller.enableDwindleLayout()
        let staleToken = WindowToken(pid: 881_005, windowId: 881_105)
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            controller.workspaceManager.niriEngine?.setProjectionExclusions(
                [staleToken],
                in: workspaceId
            )
            controller.workspaceManager.dwindleEngine?.setExcludedTokens(
                [staleToken],
                in: workspaceId
            )
        }

        let report = RuntimeDiagnosticsReport.build(controller, traceLimit: 10)

        XCTAssertTrue(report.contains("projection workspace=\(workspaceId.uuidString) expectedExcluded=0"))
        XCTAssertTrue(report.contains("niri=excluded:1,missing:0,unexpected:1,match:false"), report)
        XCTAssertTrue(report.contains("dwindle=excluded:1,missing:0,unexpected:1,match:false"), report)
    }

    func testParkAuditExcludesMacOSHiddenWindowsFromVisibleAndStrayClassification() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = addWindow(pid: 881_003, windowId: 881_103, workspaceId: workspaceId, controller: controller)
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .service)
        ParkVisibilityAudit.shared.beginCapture()
        defer { ParkVisibilityAudit.shared.endCapture() }

        controller.layoutRefreshController.auditParkVisibility(displayId: 1)

        let dump = ParkVisibilityAudit.shared.dump()
        XCTAssertTrue(dump.contains("visible=[]"))
        XCTAssertTrue(dump.contains("strays=none"))
        XCTAssertTrue(dump.contains("parked=0 appHidden=1"))
    }

    func testParkAuditConservativelyExcludesAXFencedWindowsDuringDesynchronization() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = addWindow(pid: 881_004, windowId: 881_104, workspaceId: workspaceId, controller: controller)
        controller.axManager.setMacOSAppHidden(
            true,
            pid: token.pid,
            entries: [(pid: token.pid, windowId: token.windowId)]
        )
        defer {
            controller.axManager.setMacOSAppHidden(
                false,
                pid: token.pid,
                entries: [(pid: token.pid, windowId: token.windowId)]
            )
        }
        ParkVisibilityAudit.shared.beginCapture()
        defer { ParkVisibilityAudit.shared.endCapture() }

        controller.layoutRefreshController.auditParkVisibility(displayId: 1)

        let dump = ParkVisibilityAudit.shared.dump()
        XCTAssertTrue(dump.contains("visible=[]"))
        XCTAssertTrue(dump.contains("strays=none"))
        XCTAssertTrue(dump.contains("parked=0 appHidden=1"))
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMAppVisibilityDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(settings: settings)
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}
