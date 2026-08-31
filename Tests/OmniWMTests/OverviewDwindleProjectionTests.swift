// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class OverviewDwindleProjectionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testProjectionIncludesOnlyActiveGroupMemberWithCount() throws {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertFalse(projection.includes(fixture.first))
        XCTAssertTrue(projection.includes(fixture.second))
        XCTAssertTrue(projection.includes(fixture.standalone))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.second, fixture.standalone])
        XCTAssertEqual(projection.groupCountByToken, [fixture.second: 2])
    }

    func testProjectionTracksActiveMemberChangesWithoutUsingParkedFrame() {
        let fixture = makeGroupedFixture()

        XCTAssertEqual(fixture.engine.activateWindowOutcome(fixture.first, in: fixture.workspaceId), .activated)
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)

        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertFalse(projection.includes(fixture.second))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.standalone])
        XCTAssertEqual(projection.groupCountByToken, [fixture.first: 2])
    }

    func testProjectionPromotesRemainingMemberAfterActiveMemberRemoval() {
        let fixture = makeGroupedFixture()

        let removed = fixture.engine.syncWindows(
            [fixture.first, fixture.standalone],
            in: fixture.workspaceId,
            focusedToken: fixture.first
        )
        _ = fixture.engine.calculateLayout(for: fixture.workspaceId, screen: screen)
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.second, fixture.standalone]
        )

        XCTAssertEqual(removed, [fixture.second])
        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.standalone])
        XCTAssertTrue(projection.groupCountByToken.isEmpty)
    }

    func testProjectionPromotesEligibleMemberWhenActiveMemberIsIneligible() {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.first, fixture.standalone]
        )

        XCTAssertTrue(projection.includes(fixture.first))
        XCTAssertFalse(projection.includes(fixture.second))
        XCTAssertTrue(projection.includes(fixture.standalone))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.first, fixture.standalone])
        XCTAssertTrue(projection.groupCountByToken.isEmpty)
    }

    func testProjectionExcludesIneligibleInactiveMemberFromGroupCount() {
        let fixture = makeGroupedFixture()
        let projection = DwindleOverviewWorkspaceProjection(
            engine: fixture.engine,
            workspaceId: fixture.workspaceId,
            eligibleTokens: [fixture.second, fixture.standalone]
        )

        XCTAssertFalse(projection.includes(fixture.first))
        XCTAssertTrue(projection.includes(fixture.second))
        XCTAssertEqual(Set(projection.frames.keys), [fixture.second, fixture.standalone])
        XCTAssertTrue(projection.groupCountByToken.isEmpty)
    }

    @MainActor
    func testOverviewBuildReadsOnlyActiveMemberAndUsesEngineFrame() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewDwindleProjectionTests-\(UUID().uuidString)", isDirectory: true)
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
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.settings.workspaceConfigurations.append(
            WorkspaceConfiguration(name: "97", layoutType: .dwindle)
        )
        let monitor = Monitor(
            id: .init(displayId: 92_001),
            displayId: 92_001,
            frame: screen,
            visibleFrame: screen,
            hasNotch: false,
            name: "Overview Dwindle"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "97"))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let first = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_101), windowId: 92_201),
            pid: 92_101,
            windowId: 92_201,
            to: workspaceId
        )
        let second = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(92_102), windowId: 92_202),
            pid: 92_102,
            windowId: 92_202,
            to: workspaceId
        )
        let engine = DwindleLayoutEngine()
        controller.dwindleEngine = engine
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            _ = engine.groupWindow(direction: .left, in: workspaceId)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
        }

        var titleReads = 0
        var frameReads = 0
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        environment.windowFrame = { _ in
            frameReads += 1
            return .zero
        }
        let overview = OverviewController(
            wmController: controller,
            motionPolicy: controller.motionPolicy,
            environment: environment
        )

        overview.prepareOpenState()

        XCTAssertEqual(overview.selectedWindowHandle, controller.workspaceManager.handle(for: second))
        XCTAssertEqual(titleReads, 1)
        XCTAssertEqual(frameReads, 0)

        overview.onAnimationComplete(state: .open)
        let removedEntry = try XCTUnwrap(controller.workspaceManager.entry(for: second))
        _ = controller.workspaceManager.removeWindow(pid: second.pid, windowId: second.windowId)
        overview.handleManagedWindowRemoved(removedEntry)
        let removed = controller.workspaceManager.withEngineMutationScope {
            let removed = engine.syncWindows(
                [first],
                in: workspaceId,
                focusedToken: first
            )
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            return removed
        }
        XCTAssertEqual(removed, [second])
        overview.refreshCachedOverviewProjection(
            affectedWorkspaceIds: [workspaceId],
            selectedHandle: controller.workspaceManager.handle(for: first)
        )

        XCTAssertEqual(overview.selectedWindowHandle?.id, first)
    }

    private func makeGroupedFixture() -> (
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        first: WindowToken,
        second: WindowToken,
        standalone: WindowToken
    ) {
        let engine = DwindleLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let standalone = WindowToken(pid: 3, windowId: 3)

        _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        _ = engine.groupWindow(direction: .left, in: workspaceId)
        _ = engine.addWindow(token: standalone, to: workspaceId, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)

        return (engine, workspaceId, first, second, standalone)
    }
}
