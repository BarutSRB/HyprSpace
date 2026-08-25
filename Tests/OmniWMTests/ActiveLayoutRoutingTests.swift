// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ActiveLayoutRoutingTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let staleNiriFrame = CGRect(x: 40, y: 60, width: 320, height: 240)

    func testLayoutTopologyProjectsOnlyNiriEngineForNiriWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "60", layoutType: .niri, controller: controller)
        let token = addManagedWindow(pid: 950, windowId: 1, to: workspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            _ = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            _ = dwindleEngine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.toggleFullscreen(in: workspaceId)
        }

        let topology = controller.workspaceManager.layoutTopology(for: workspaceId)

        XCTAssertTrue(topology.hasColumns)
        XCTAssertTrue(topology.containsNiriWindow(token))
        XCTAssertTrue(topology.dwindleFullscreenTokens.isEmpty)
        XCTAssertFalse(topology.isFullscreen(token))
    }

    func testLayoutTopologyProjectsOnlyDwindleEngineForDwindleWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "61", layoutType: .dwindle, controller: controller)
        let token = addManagedWindow(pid: 951, windowId: 1, to: workspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.toggleFullscreen(in: workspaceId)
            _ = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }

        let topology = controller.workspaceManager.layoutTopology(for: workspaceId)

        XCTAssertFalse(topology.hasColumns)
        XCTAssertFalse(topology.containsNiriWindow(token))
        XCTAssertEqual(topology.dwindleFullscreenTokens, [token])
        XCTAssertTrue(topology.isFullscreen(token))
    }

    func testEntryOrderingFollowsNiriColumnsForNiriWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "62", layoutType: .niri, controller: controller)
        let firstToken = addManagedWindow(pid: 952, windowId: 1, to: workspaceId, controller: controller)
        let secondToken = addManagedWindow(pid: 952, windowId: 2, to: workspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            _ = niriEngine.addWindow(token: secondToken, to: workspaceId, afterSelection: nil)
            _ = niriEngine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
            _ = dwindleEngine.addWindow(token: firstToken, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: secondToken, to: workspaceId, activeWindowFrame: nil)
        }

        let seededColumnTokens = niriEngine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
        XCTAssertEqual(seededColumnTokens, [secondToken, firstToken])

        let entries = controller.workspaceManager.entries(in: workspaceId)
        let ordered = WorkspaceEntryOrdering.orderedEntries(
            entries,
            topology: controller.workspaceManager.layoutTopology(for: workspaceId)
        )

        XCTAssertEqual(ordered.map(\.token), [secondToken, firstToken])
    }

    func testEntryOrderingIgnoresStaleNiriColumnsForDwindleWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "63", layoutType: .dwindle, controller: controller)
        _ = addManagedWindow(pid: 953, windowId: 1, to: workspaceId, controller: controller)
        _ = addManagedWindow(pid: 953, windowId: 2, to: workspaceId, controller: controller)
        let entries = controller.workspaceManager.entries(in: workspaceId)
        let entryTokens = entries.map(\.token)
        XCTAssertEqual(entryTokens.count, 2)

        controller.workspaceManager.withEngineMutationScope {
            for token in entryTokens.reversed() {
                _ = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
                _ = dwindleEngine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }

        let staleColumnTokens = niriEngine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
        XCTAssertEqual(staleColumnTokens, entryTokens.reversed())

        let topology = controller.workspaceManager.layoutTopology(for: workspaceId)
        let ordered = WorkspaceEntryOrdering.orderedEntries(entries, topology: topology)

        XCTAssertFalse(topology.hasColumns)
        XCTAssertEqual(ordered.map(\.token), entryTokens)
    }

    func testKeyboardFocusFrameQueriesActiveNiriEngine() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "64", layoutType: .niri, controller: controller)
        let token = addManagedWindow(pid: 954, windowId: 1, to: workspaceId, controller: controller)
        let niriFrame = staleNiriFrame

        controller.workspaceManager.withEngineMutationScope {
            let node = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            node.renderedFrame = niriFrame
            _ = dwindleEngine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.calculateLayout(for: workspaceId, screen: screenFrame)
        }

        let dwindleFrame = try XCTUnwrap(dwindleEngine.findNode(for: token, in: workspaceId)?.cachedFrame)
        XCTAssertNotEqual(dwindleFrame, niriFrame)
        XCTAssertEqual(controller.preferredKeyboardFocusFrame(for: token), niriFrame)
    }

    func testKeyboardFocusFrameQueriesActiveDwindleEngine() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "65", layoutType: .dwindle, controller: controller)
        let token = addManagedWindow(pid: 955, windowId: 1, to: workspaceId, controller: controller)
        let niriFrame = staleNiriFrame

        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.calculateLayout(for: workspaceId, screen: screenFrame)
            let staleNode = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            staleNode.renderedFrame = niriFrame
        }

        let dwindleFrame = try XCTUnwrap(dwindleEngine.findNode(for: token, in: workspaceId)?.cachedFrame)
        XCTAssertNotEqual(dwindleFrame, niriFrame)
        XCTAssertEqual(controller.preferredKeyboardFocusFrame(for: token), dwindleFrame)
    }

    func testKeyboardFocusFrameIsNilWhenOnlyDormantEngineHasNode() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let workspaceId = try makeTransientWorkspace(named: "66", layoutType: .dwindle, controller: controller)
        let token = addManagedWindow(pid: 956, windowId: 1, to: workspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            let staleNode = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            staleNode.renderedFrame = staleNiriFrame
        }

        XCTAssertNil(controller.preferredKeyboardFocusFrame(for: token))
    }

    func testFocusConfirmationActivatesOnlyDwindleEngineForDwindleWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "67", layoutType: .dwindle, controller: controller)
        let mainToken = addManagedWindow(pid: 957, windowId: 1, to: workspaceId, controller: controller)
        let otherToken = addManagedWindow(pid: 957, windowId: 2, to: workspaceId, controller: controller)

        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: mainToken, to: workspaceId, activeWindowFrame: nil)
            let otherNode = dwindleEngine.addWindow(token: otherToken, to: workspaceId, activeWindowFrame: nil)
            dwindleEngine.setSelectedNode(otherNode, in: workspaceId)
            _ = niriEngine.addWindow(token: mainToken, to: workspaceId, afterSelection: nil)
        }
        let niriSelectionBefore = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: mainToken))

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: false
        )

        let mainLeaf = try XCTUnwrap(dwindleEngine.findNode(for: mainToken, in: workspaceId))
        XCTAssertTrue(dwindleEngine.selectedNode(in: workspaceId) === mainLeaf)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            niriSelectionBefore
        )
    }

    func testFocusConfirmationActivatesOnlyNiriEngineForNiriWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "68", layoutType: .niri, controller: controller)
        let mainToken = addManagedWindow(pid: 958, windowId: 1, to: workspaceId, controller: controller)
        let otherToken = addManagedWindow(pid: 958, windowId: 2, to: workspaceId, controller: controller)

        var niriNode: NiriWindow?
        var dormantSelection: DwindleNode?
        controller.workspaceManager.withEngineMutationScope {
            niriNode = niriEngine.addWindow(token: mainToken, to: workspaceId, afterSelection: nil)
            _ = dwindleEngine.addWindow(token: mainToken, to: workspaceId, activeWindowFrame: nil)
            dormantSelection = dwindleEngine.addWindow(token: otherToken, to: workspaceId, activeWindowFrame: nil)
            dwindleEngine.setSelectedNode(dormantSelection, in: workspaceId)
        }
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: mainToken))

        controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: false
        )

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            niriNode?.id
        )
        XCTAssertTrue(dwindleEngine.selectedNode(in: workspaceId) === dormantSelection)
    }

    func testSavingViewportStateDoesNotMutateDormantNiriSelectionForDwindleWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "69", layoutType: .dwindle, controller: controller)
        let focusedToken = addManagedWindow(pid: 959, windowId: 1, to: workspaceId, controller: controller)
        let dormantToken = addManagedWindow(pid: 959, windowId: 2, to: workspaceId, controller: controller)

        var dormantNiriNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: focusedToken, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: dormantToken, to: workspaceId, activeWindowFrame: nil)
            dwindleEngine.setSelectedNode(
                dwindleEngine.findNode(for: focusedToken, in: workspaceId),
                in: workspaceId
            )
            _ = niriEngine.addWindow(token: focusedToken, to: workspaceId, afterSelection: nil)
            dormantNiriNode = niriEngine.addWindow(token: dormantToken, to: workspaceId, afterSelection: nil)
        }
        var viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        viewportState.selectedNodeId = dormantNiriNode?.id
        controller.workspaceManager.updateNiriViewportState(viewportState, for: workspaceId)
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId)

        controller.workspaceNavigationHandler.saveNiriViewportState(for: workspaceId)

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            dormantNiriNode?.id
        )
        XCTAssertEqual(dwindleEngine.selectedNode(in: workspaceId)?.windowToken, focusedToken)
    }

    func testMoveFromDwindleRecoversDwindleSelectionInsteadOfDormantNiriSelection() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let sourceWorkspaceId = try makeTransientWorkspace(
            named: "73",
            layoutType: .dwindle,
            controller: controller
        )
        let targetWorkspaceId = try makeTransientWorkspace(
            named: "74",
            layoutType: .dwindle,
            controller: controller
        )
        let staleNiriToken = addManagedWindow(pid: 963, windowId: 1, to: sourceWorkspaceId, controller: controller)
        let fallbackToken = addManagedWindow(pid: 963, windowId: 2, to: sourceWorkspaceId, controller: controller)
        let movedToken = addManagedWindow(pid: 963, windowId: 3, to: sourceWorkspaceId, controller: controller)

        var staleNiriNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: staleNiriToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: fallbackToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: movedToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            staleNiriNode = niriEngine.addWindow(
                token: staleNiriToken,
                to: sourceWorkspaceId,
                afterSelection: nil
            )
            _ = niriEngine.addWindow(token: fallbackToken, to: sourceWorkspaceId, afterSelection: nil)
            _ = niriEngine.addWindow(token: movedToken, to: sourceWorkspaceId, afterSelection: nil)
        }
        var viewportState = controller.workspaceManager.niriViewportState(for: sourceWorkspaceId)
        viewportState.selectedNodeId = staleNiriNode?.id
        controller.workspaceManager.updateNiriViewportState(viewportState, for: sourceWorkspaceId)
        _ = controller.workspaceManager.setManagedFocus(movedToken, in: sourceWorkspaceId)
        let movedHandle = try XCTUnwrap(controller.workspaceManager.handle(for: movedToken))

        XCTAssertTrue(
            controller.workspaceNavigationHandler.moveWindow(
                handle: movedHandle,
                toWorkspaceId: targetWorkspaceId
            ).didMutate
        )

        XCTAssertEqual(controller.workspaceManager.workspace(for: movedToken), targetWorkspaceId)
        XCTAssertEqual(dwindleEngine.selectedNode(in: sourceWorkspaceId)?.windowToken, fallbackToken)
        XCTAssertEqual(controller.workspaceManager.lastFocusedToken(in: sourceWorkspaceId), fallbackToken)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: sourceWorkspaceId).selectedNodeId,
            staleNiriNode?.id
        )
    }

    func testFollowingMoveIntoDwindleDoesNotMutateDormantTargetNiriViewport() throws {
        let controller = makeController()
        controller.settings.focusFollowsWindowToMonitor = true
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let sourceWorkspaceId = try makeTransientWorkspace(
            named: "76",
            layoutType: .dwindle,
            controller: controller
        )
        let targetWorkspaceId = try makeTransientWorkspace(
            named: "77",
            layoutType: .dwindle,
            controller: controller
        )
        let sourceFallbackToken = addManagedWindow(
            pid: 965,
            windowId: 1,
            to: sourceWorkspaceId,
            controller: controller
        )
        let movedToken = addManagedWindow(pid: 965, windowId: 2, to: sourceWorkspaceId, controller: controller)
        let targetToken = addManagedWindow(pid: 966, windowId: 1, to: targetWorkspaceId, controller: controller)

        var dormantTargetNiriNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(
                token: sourceFallbackToken,
                to: sourceWorkspaceId,
                activeWindowFrame: nil
            )
            _ = dwindleEngine.addWindow(token: movedToken, to: sourceWorkspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: targetToken, to: targetWorkspaceId, activeWindowFrame: nil)
            dormantTargetNiriNode = niriEngine.addWindow(
                token: targetToken,
                to: targetWorkspaceId,
                afterSelection: nil
            )
            _ = niriEngine.addWindow(token: movedToken, to: targetWorkspaceId, afterSelection: nil)
        }
        var viewportState = controller.workspaceManager.niriViewportState(for: targetWorkspaceId)
        viewportState.selectedNodeId = dormantTargetNiriNode?.id
        controller.workspaceManager.updateNiriViewportState(viewportState, for: targetWorkspaceId)
        _ = controller.workspaceManager.setManagedFocus(movedToken, in: sourceWorkspaceId)

        controller.workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: "77")

        XCTAssertEqual(controller.workspaceManager.workspace(for: movedToken), targetWorkspaceId)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: targetWorkspaceId).selectedNodeId,
            dormantTargetNiriNode?.id
        )
    }

    func testFocusValidationUpdatesOnlyActiveDwindleSelection() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let dwindleEngine = try XCTUnwrap(controller.dwindleEngine)
        let workspaceId = try makeTransientWorkspace(named: "75", layoutType: .dwindle, controller: controller)
        let focusedToken = addManagedWindow(pid: 964, windowId: 1, to: workspaceId, controller: controller)
        let staleToken = addManagedWindow(pid: 964, windowId: 2, to: workspaceId, controller: controller)

        var staleNiriNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            _ = dwindleEngine.addWindow(token: focusedToken, to: workspaceId, activeWindowFrame: nil)
            _ = dwindleEngine.addWindow(token: staleToken, to: workspaceId, activeWindowFrame: nil)
            _ = niriEngine.addWindow(token: focusedToken, to: workspaceId, afterSelection: nil)
            staleNiriNode = niriEngine.addWindow(token: staleToken, to: workspaceId, afterSelection: nil)
        }
        var viewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        viewportState.selectedNodeId = staleNiriNode?.id
        controller.workspaceManager.updateNiriViewportState(viewportState, for: workspaceId)
        _ = controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId)

        controller.ensureFocusedTokenValid(in: workspaceId)

        XCTAssertEqual(dwindleEngine.selectedNode(in: workspaceId)?.windowToken, focusedToken)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            staleNiriNode?.id
        )
    }

    func testTabRailsProjectOnlyForActiveNiriLayout() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let monitor = Monitor(
            id: .init(displayId: 20_001), displayId: 20_001,
            frame: screenFrame, visibleFrame: screenFrame,
            hasNotch: false, name: "Rails"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let niriWorkspaceId = try makeTransientWorkspace(named: "70", layoutType: .niri, controller: controller)
        let dwindleWorkspaceId = try makeTransientWorkspace(named: "71", layoutType: .dwindle, controller: controller)

        for (pid, workspaceId) in [(pid_t(960), niriWorkspaceId), (pid_t(961), dwindleWorkspaceId)] {
            let token = addManagedWindow(pid: pid, windowId: 1, to: workspaceId, controller: controller)
            let secondToken = addManagedWindow(pid: pid, windowId: 2, to: workspaceId, controller: controller)
            controller.workspaceManager.withEngineMutationScope {
                let firstNode = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
                let secondNode = niriEngine.addWindow(
                    token: secondToken,
                    to: workspaceId,
                    afterSelection: firstNode.id
                )
                if let column = niriEngine.columns(in: workspaceId).first {
                    var state = ViewportState(selectedNodeId: firstNode.id)
                    _ = niriEngine.consumeWindow(
                        secondNode,
                        into: column,
                        enteringFrom: .right,
                        in: workspaceId,
                        motion: .disabled,
                        state: &state,
                        workingFrame: screenFrame,
                        gaps: 10,
                        orientation: .horizontal
                    )
                    column.displayMode = .tabbed
                    column.frame = staleNiriFrame.offsetBy(dx: 700, dy: 0)
                    column.renderedFrame = staleNiriFrame
                }
            }
            let column = try XCTUnwrap(niriEngine.columns(in: workspaceId).first)
            XCTAssertTrue(column.isTabbed)
        }

        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(niriWorkspaceId, on: monitor.id))
        XCTAssertEqual(controller.niriLayoutHandler.desiredTabRailInfos().map(\.workspaceId), [niriWorkspaceId])
        let renderedCommands = controller.niriLayoutHandler.niriTabRailGeometryCommands(
            engine: niriEngine,
            workspaceId: niriWorkspaceId,
            monitor: controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
        )
        XCTAssertEqual(renderedCommands.count, 1)
        XCTAssertEqual(renderedCommands.first?.tileFrame, staleNiriFrame)
        XCTAssertEqual(renderedCommands.first?.visibleTileFrame, staleNiriFrame.intersection(screenFrame))

        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(dwindleWorkspaceId, on: monitor.id))
        XCTAssertTrue(controller.niriLayoutHandler.desiredTabRailInfos().isEmpty)
    }

    func testSelectTabInNiriIgnoresDwindleWorkspace() throws {
        let controller = makeController()
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let niriEngine = try XCTUnwrap(controller.niriEngine)
        let workspaceId = try makeTransientWorkspace(named: "72", layoutType: .dwindle, controller: controller)
        let token = addManagedWindow(pid: 962, windowId: 1, to: workspaceId, controller: controller)

        var staleNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            staleNode = niriEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            if let column = niriEngine.columns(in: workspaceId).first {
                column.displayMode = .tabbed
                column.renderedFrame = staleNiriFrame
            }
        }
        let column = try XCTUnwrap(niriEngine.columns(in: workspaceId).first)
        let selectionBefore = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
        XCTAssertNotEqual(selectionBefore, staleNode?.id)

        let info = TabRailInfo(
            workspaceId: workspaceId,
            owner: .niriColumn(column.id),
            plannedSeq: controller.workspaceManager.worldSeq,
            tileFrame: staleNiriFrame,
            tabCount: 1,
            activeVisualIndex: 0,
            activeWindowId: nil,
            tabs: [
                TabRailTabInfo(
                    visualIndex: 0, token: token, windowId: nil, appName: nil, title: nil, isActive: true
                )
            ]
        )

        controller.niriLayoutHandler.selectTabInNiri(info: info, visualIndex: 0, expectedToken: token)

        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
            selectionBefore
        )
        XCTAssertEqual(column.activeTileIdx, 0)
    }

    private func makeTransientWorkspace(
        named name: String,
        layoutType: LayoutType,
        controller: WMController
    ) throws -> WorkspaceDescriptor.ID {
        controller.settings.workspaceConfigurations.append(WorkspaceConfiguration(name: name, layoutType: layoutType))
        controller.workspaceManager.applySettings()
        return try XCTUnwrap(controller.workspaceManager.workspaceId(named: name))
    }

    private func addManagedWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMActiveLayoutRoutingTests-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
