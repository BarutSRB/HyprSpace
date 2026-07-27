// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DwindleWorkspaceMonitorMoveTests: XCTestCase {
    func testConfiguredWorkspaceMovesWithoutSwapAndReusesTreeOnDestinationGeometry() throws {
        let sourceMonitor = makeMonitor(
            displayId: 972_001,
            name: "Source",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let destinationMonitor = makeMonitor(
            displayId: 972_002,
            name: "Destination",
            frame: CGRect(x: 900, y: 100, width: 1000, height: 700)
        )
        let manager = makeManager(
            sourceMonitor: sourceMonitor,
            destinationMonitor: destinationMonitor
        )
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let replacementWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let destinationWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))

        XCTAssertTrue(
            manager.setActiveWorkspace(
                replacementWorkspaceId,
                on: sourceMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                destinationWorkspaceId,
                on: destinationMonitor.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(manager.setActiveWorkspace(movedWorkspaceId, on: sourceMonitor.id))

        let engine = DwindleLayoutEngine()
        manager.dwindleEngine = engine
        let firstToken = addWindow(
            pid: 972_101,
            windowId: 972_201,
            workspaceId: movedWorkspaceId,
            manager: manager
        )
        let secondToken = addWindow(
            pid: 972_102,
            windowId: 972_202,
            workspaceId: movedWorkspaceId,
            manager: manager
        )
        manager.withEngineMutationScope(in: movedWorkspaceId) {
            _ = engine.addWindow(
                token: firstToken,
                to: movedWorkspaceId,
                activeWindowFrame: nil
            )
            _ = engine.addWindow(
                token: secondToken,
                to: movedWorkspaceId,
                activeWindowFrame: nil
            )
            _ = engine.calculateLayout(
                for: movedWorkspaceId,
                screen: sourceMonitor.visibleFrame
            )
        }

        let originalRoot = try XCTUnwrap(engine.root(for: movedWorkspaceId))
        let originalFirstNode = try XCTUnwrap(engine.findNode(for: firstToken, in: movedWorkspaceId))
        let originalSecondNode = try XCTUnwrap(engine.findNode(for: secondToken, in: movedWorkspaceId))
        let originalFirstTileId = try XCTUnwrap(
            engine.tileSnapshot(for: firstToken, in: movedWorkspaceId)?.id
        )
        let originalSecondTileId = try XCTUnwrap(
            engine.tileSnapshot(for: secondToken, in: movedWorkspaceId)?.id
        )

        let outcome = manager.moveWorkspaceToMonitor(
            movedWorkspaceId,
            to: destinationMonitor.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(manager.activeWorkspace(on: sourceMonitor.id)?.id, replacementWorkspaceId)
        XCTAssertEqual(manager.activeWorkspace(on: destinationMonitor.id)?.id, movedWorkspaceId)
        XCTAssertEqual(manager.monitorForWorkspace(destinationWorkspaceId)?.id, destinationMonitor.id)
        XCTAssertNotEqual(manager.activeWorkspace(on: sourceMonitor.id)?.id, destinationWorkspaceId)
        XCTAssertTrue(engine.root(for: movedWorkspaceId) === originalRoot)
        XCTAssertTrue(engine.findNode(for: firstToken, in: movedWorkspaceId) === originalFirstNode)
        XCTAssertTrue(engine.findNode(for: secondToken, in: movedWorkspaceId) === originalSecondNode)
        XCTAssertEqual(
            engine.tileSnapshot(for: firstToken, in: movedWorkspaceId)?.id,
            originalFirstTileId
        )
        XCTAssertEqual(
            engine.tileSnapshot(for: secondToken, in: movedWorkspaceId)?.id,
            originalSecondTileId
        )
        XCTAssertEqual(Set(originalRoot.collectAllWindows()), Set([firstToken, secondToken]))

        let resolvedMonitor = try XCTUnwrap(manager.monitor(for: movedWorkspaceId))
        XCTAssertEqual(resolvedMonitor.id, destinationMonitor.id)
        var destinationFrames: [WindowToken: CGRect] = [:]
        manager.withEngineMutationScope(in: movedWorkspaceId) {
            destinationFrames = engine.calculateLayout(
                for: movedWorkspaceId,
                screen: resolvedMonitor.visibleFrame
            )
        }

        XCTAssertEqual(Set(destinationFrames.keys), Set([firstToken, secondToken]))
        XCTAssertEqual(originalRoot.cachedFrame, destinationMonitor.visibleFrame)
        XCTAssertNotEqual(originalRoot.cachedFrame, sourceMonitor.visibleFrame)
        for frame in destinationFrames.values {
            XCTAssertGreaterThanOrEqual(frame.minX, destinationMonitor.visibleFrame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, destinationMonitor.visibleFrame.maxX)
            XCTAssertGreaterThanOrEqual(frame.minY, destinationMonitor.visibleFrame.minY)
            XCTAssertLessThanOrEqual(frame.maxY, destinationMonitor.visibleFrame.maxY)
        }
    }

    private func makeManager(
        sourceMonitor: Monitor,
        destinationMonitor: Monitor
    ) -> WorkspaceManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMDwindleWorkspaceMonitorMoveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: sourceMonitor)),
                layoutType: .dwindle
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: destinationMonitor)),
                layoutType: .dwindle
            )
        ]
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange([sourceMonitor, destinationMonitor])
        manager.applySettings()
        return manager
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        manager: WorkspaceManager
    ) -> WindowToken {
        manager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}
