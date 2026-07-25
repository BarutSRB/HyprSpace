// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class NiriAdmissionRestoreStateTests: XCTestCase {
    func testHintOnlyReevaluationUpdatesBeforeFirstClaimWithoutLayoutInvalidation() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(801), windowId: 91),
            pid: 801,
            windowId: 91,
            to: workspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.5)
        )
        let beforeUpdate = controller.workspaceManager.worldSeq
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 200, height: 100),
            maxSize: CGSize(width: 1200, height: 900),
            isFixed: false
        )
        controller.workspaceManager.setCachedConstraints(constraints, for: token)

        XCTAssertTrue(
            controller.workspaceManager.updateAdmissionHints(
                ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.75),
                for: token
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriContainerPrimarySpan,
            0.75
        )
        XCTAssertTrue(controller.workspaceManager.isSeqEpochCurrent(beforeUpdate, domains: .layout))
        XCTAssertEqual(
            controller.workspaceManager.cachedConstraints(for: token, maxAge: .greatestFiniteMagnitude),
            constraints
        )

        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }

        XCTAssertFalse(
            controller.workspaceManager.updateAdmissionHints(
                ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 1.0),
                for: token
            )
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriContainerPrimarySpan,
            0.75
        )
    }

    func testFloatingCapturePersistsAndSuccessfulReattachClearsDetachedSizing() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let workspaceName = try XCTUnwrap(controller.workspaceManager.descriptor(for: workspaceId)?.name)
        controller.niriLayoutHandler.enableNiriLayout()

        let token = WindowToken(pid: 802, windowId: 92)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.restore-width",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Document",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 10, y: 20, width: 700, height: 500)
        )
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.5),
            managedReplacementMetadata: metadata
        )

        let expected = NiriContainerSizingState(
            width: .proportion(0.72),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: .fixed(640),
            hasManualSingleWindowWidthOverride: true,
            height: .fixed(720),
            isFullHeight: true,
            savedHeight: .proportion(0.6),
            hasManualSingleWindowHeightOverride: true
        )
        let expectedWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(625),
            savedHeight: .auto(weight: 2),
            windowWidth: .fixed(485)
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = controller.workspaceManager.withEngineMutationScope {
            engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let stalePlacement = try XCTUnwrap(engine.persistedPlacement(for: token, in: workspaceId))
        controller.workspaceManager.setNiriRestorePlacements([token: stalePlacement])
        controller.workspaceManager.withEngineMutationScope {
            guard let column = engine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
            node.sizingMode = expectedWindowState.sizingMode
            node.height = expectedWindowState.height
            node.savedHeight = expectedWindowState.savedHeight
            node.windowWidth = expectedWindowState.windowWidth
        }

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: token))
        XCTAssertNil(engine.findNode(for: token, in: workspaceId))
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            expected
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.niriPlacement?.window,
            expectedWindowState
        )

        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        let persistedEntry = try XCTUnwrap(
            controller.settings.loadPersistedWindowRestoreCatalog().entries.first {
                $0.restoreIntent.workspaceName == workspaceName
            }
        )
        XCTAssertEqual(persistedEntry.restoreIntent.detachedNiriContainerSizingState, expected)
        XCTAssertEqual(persistedEntry.restoreIntent.niriPlacement?.window, expectedWindowState)

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: token))
        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }.first?.niriRestorePlacements ?? [:]
        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), expected)
        let restoredNode = try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        XCTAssertEqual(restoredNode.sizingMode, expectedWindowState.sizingMode)
        XCTAssertEqual(restoredNode.height, expectedWindowState.height)
        XCTAssertEqual(restoredNode.savedHeight, expectedWindowState.savedHeight)
        XCTAssertEqual(restoredNode.windowWidth, expectedWindowState.windowWidth)
        let placement = try XCTUnwrap(placements[token])
        controller.workspaceManager.setNiriRestorePlacements([token: placement])

        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.niriPlacement,
            placement
        )

        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        XCTAssertTrue(controller.settings.loadPersistedWindowRestoreCatalog().entries.isEmpty)
    }

    func testFloatingCaptureRefreshesSiblingPlacementBeforeReattach() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(808), windowId: 98),
            pid: 808,
            windowId: 98,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(808), windowId: 99),
            pid: 808,
            windowId: 99,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        var firstNode: NiriWindow?
        var secondNode: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            let first = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
            let second = engine.addWindow(token: secondToken, to: workspaceId, afterSelection: first.id)
            var state = ViewportState()
            state.selectedNodeId = first.id
            guard let firstColumn = engine.column(of: first) else {
                XCTFail("Expected first Niri container")
                return
            }
            XCTAssertTrue(
                engine.consumeWindow(
                    second,
                    into: firstColumn,
                    enteringFrom: .down,
                    in: workspaceId,
                    motion: .disabled,
                    state: &state,
                    workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 1600),
                    gaps: 0,
                    orientation: .vertical
                )
            )
            firstNode = first
            secondNode = second
        }
        controller.workspaceManager.setNiriRestorePlacements(engine.persistedPlacements(in: workspaceId))

        let expectedContainerHeight = ProportionalSize.proportion(0.7)
        let expectedFirstWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(590),
            savedHeight: .auto(weight: 1.25),
            windowWidth: .fixed(360)
        )
        let expectedSecondWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(610),
            savedHeight: .auto(weight: 1.75),
            windowWidth: .fixed(480)
        )
        controller.workspaceManager.withEngineMutationScope {
            guard let firstNode,
                  let secondNode,
                  let column = engine.column(of: firstNode)
            else {
                XCTFail("Expected stacked Niri windows")
                return
            }
            column.height = expectedContainerHeight
            firstNode.sizingMode = expectedFirstWindowState.sizingMode
            firstNode.height = expectedFirstWindowState.height
            firstNode.savedHeight = expectedFirstWindowState.savedHeight
            firstNode.windowWidth = expectedFirstWindowState.windowWidth
            secondNode.sizingMode = expectedSecondWindowState.sizingMode
            secondNode.height = expectedSecondWindowState.height
            secondNode.savedHeight = expectedSecondWindowState.savedHeight
            secondNode.windowWidth = expectedSecondWindowState.windowWidth
        }

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: secondToken))
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: firstToken)?.niriPlacement?.column.height,
            expectedContainerHeight
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: firstToken)?.niriPlacement?.window,
            expectedFirstWindowState
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: secondToken)?.niriPlacement?.window,
            expectedSecondWindowState
        )

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: secondToken))
        _ = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        let restoredFirst = try XCTUnwrap(engine.findNode(for: firstToken, in: workspaceId))
        let restoredSecond = try XCTUnwrap(engine.findNode(for: secondToken, in: workspaceId))
        XCTAssertTrue(engine.column(of: restoredFirst) === engine.column(of: restoredSecond))
        XCTAssertEqual(engine.column(of: restoredFirst)?.height, expectedContainerHeight)
        XCTAssertEqual(restoredFirst.sizingMode, expectedFirstWindowState.sizingMode)
        XCTAssertEqual(restoredFirst.height, expectedFirstWindowState.height)
        XCTAssertEqual(restoredFirst.savedHeight, expectedFirstWindowState.savedHeight)
        XCTAssertEqual(restoredFirst.windowWidth, expectedFirstWindowState.windowWidth)
        XCTAssertEqual(restoredSecond.sizingMode, expectedSecondWindowState.sizingMode)
        XCTAssertEqual(restoredSecond.height, expectedSecondWindowState.height)
        XCTAssertEqual(restoredSecond.savedHeight, expectedSecondWindowState.savedHeight)
        XCTAssertEqual(restoredSecond.windowWidth, expectedSecondWindowState.windowWidth)
    }

    func testEngineReplacementRefreshesWindowSizingWithoutInterveningLayout() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(807), windowId: 97),
            pid: 807,
            windowId: 97,
            to: workspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = controller.workspaceManager.withEngineMutationScope {
            engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        let stalePlacement = try XCTUnwrap(engine.persistedPlacement(for: token, in: workspaceId))
        controller.workspaceManager.setNiriRestorePlacements([token: stalePlacement])

        let expectedWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(615),
            savedHeight: .auto(weight: 2),
            windowWidth: .fixed(475)
        )
        let expectedContainerHeight = ProportionalSize.proportion(0.68)
        controller.workspaceManager.withEngineMutationScope {
            guard let column = engine.column(of: node) else {
                XCTFail("Expected Niri window and container")
                return
            }
            node.sizingMode = expectedWindowState.sizingMode
            node.height = expectedWindowState.height
            node.savedHeight = expectedWindowState.savedHeight
            node.windowWidth = expectedWindowState.windowWidth
            column.height = expectedContainerHeight
        }

        XCTAssertEqual(controller.workspaceManager.restoreIntent(for: token)?.niriPlacement, stalePlacement)
        controller.niriLayoutHandler.enableNiriLayout()

        let capturedIntent = try XCTUnwrap(controller.workspaceManager.restoreIntent(for: token))
        XCTAssertEqual(capturedIntent.niriPlacement?.window, expectedWindowState)
        XCTAssertEqual(capturedIntent.niriPlacement?.column.height, expectedContainerHeight)
        XCTAssertEqual(capturedIntent.detachedNiriContainerSizingState?.height, expectedContainerHeight)
        let replacementEngine = try XCTUnwrap(controller.niriEngine)
        XCTAssertFalse(replacementEngine === engine)
        XCTAssertNil(replacementEngine.findNode(for: token, in: workspaceId))

        _ = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        let restoredNode = try XCTUnwrap(replacementEngine.findNode(for: token, in: workspaceId))
        XCTAssertEqual(restoredNode.sizingMode, expectedWindowState.sizingMode)
        XCTAssertEqual(restoredNode.height, expectedWindowState.height)
        XCTAssertEqual(restoredNode.savedHeight, expectedWindowState.savedHeight)
        XCTAssertEqual(restoredNode.windowWidth, expectedWindowState.windowWidth)
        XCTAssertEqual(replacementEngine.column(of: restoredNode)?.height, expectedContainerHeight)
    }

    func testDuplicateMembershipRepairCommitsAuthoritativePlacement() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let axRef = AXWindowRef(element: AXUIElementCreateApplication(809), windowId: 100)
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: 809,
            windowId: 100,
            to: targetWorkspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let expectedWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(620),
            savedHeight: .auto(weight: 1.5),
            windowWidth: .fixed(490)
        )
        let expectedContainerHeight = ProportionalSize.proportion(0.74)
        controller.workspaceManager.withEngineMutationScope {
            let staleNode = engine.addWindow(
                token: token,
                to: sourceWorkspaceId,
                afterSelection: nil
            )
            let authoritativeNode = engine.addWindow(
                token: token,
                to: targetWorkspaceId,
                afterSelection: nil
            )
            engine.column(of: staleNode)?.height = .proportion(0.2)
            guard let authoritativeColumn = engine.column(of: authoritativeNode) else {
                XCTFail("Expected authoritative Niri container")
                return
            }
            authoritativeColumn.height = expectedContainerHeight
            authoritativeNode.sizingMode = expectedWindowState.sizingMode
            authoritativeNode.height = expectedWindowState.height
            authoritativeNode.savedHeight = expectedWindowState.savedHeight
            authoritativeNode.windowWidth = expectedWindowState.windowWidth
            XCTAssertTrue(
                controller.workspaceManager.captureDetachedNiriPlacement(
                    for: token,
                    in: sourceWorkspaceId
                )
            )
        }

        XCTAssertNotNil(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState
        )
        _ = controller.workspaceManager.addWindow(
            axRef,
            pid: token.pid,
            windowId: token.windowId,
            to: targetWorkspaceId
        )

        XCTAssertNil(engine.findNode(for: token, in: sourceWorkspaceId))
        XCTAssertNotNil(engine.findNode(for: token, in: targetWorkspaceId))
        let restoreIntent = try XCTUnwrap(controller.workspaceManager.restoreIntent(for: token))
        XCTAssertNil(restoreIntent.detachedNiriContainerSizingState)
        XCTAssertEqual(restoreIntent.niriPlacement?.column.height, expectedContainerHeight)
        XCTAssertEqual(restoreIntent.niriPlacement?.window, expectedWindowState)
    }

    func testEngineReplacementCapturesLiveSizing() throws {
        let controller = Self.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(803), windowId: 93),
            pid: 803,
            windowId: 93,
            to: workspaceId
        )
        let expected = NiriContainerSizingState(
            width: .fixed(730),
            presetWidthIndex: 2,
            isFullWidth: true,
            savedWidth: .proportion(0.6),
            hasManualSingleWindowWidthOverride: false,
            height: .proportion(0.75),
            isFullHeight: false,
            savedHeight: .fixed(680),
            hasManualSingleWindowHeightOverride: true
        )
        let oldEngine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let node = oldEngine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            guard let column = oldEngine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
        }

        controller.niriLayoutHandler.enableNiriLayout()

        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            expected
        )
        XCTAssertNil(controller.niriEngine?.findNode(for: token, in: workspaceId))

        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }.first?.niriRestorePlacements ?? [:]
        XCTAssertEqual(controller.niriEngine?.containerSizingState(for: token, in: workspaceId), expected)
        controller.workspaceManager.setNiriRestorePlacements(placements)
        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState
        )
    }

    func testMatchedPersistedRestoreHydratesDetachedSizing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
        let token = WindowToken(pid: 804, windowId: 94)
        let placeholderWorkspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.hydrated-width",
            workspaceId: placeholderWorkspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Hydrate",
            windowLevel: 0,
            parentWindowId: nil,
            frame: nil
        )
        let expected = NiriContainerSizingState(
            width: .proportion(0.82),
            presetWidthIndex: 1,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: true,
            height: .fixed(760),
            isFullHeight: true,
            savedHeight: .proportion(0.5),
            hasManualSingleWindowHeightOverride: true
        )
        let persistedEntry = PersistedWindowRestoreEntry(
            key: try XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata)),
            identity: try XCTUnwrap(PersistedWindowRestoreIdentity(token: token, metadata: metadata)),
            restoreIntent: PersistedRestoreIntent(
                workspaceName: "1",
                topologyProfile: TopologyProfile(sortedMonitors: []),
                preferredMonitor: nil,
                floatingFrame: nil,
                normalizedFloatingOrigin: nil,
                restoreToFloating: false,
                rescueEligible: false,
                detachedNiriContainerSizingState: expected
            )
        )
        let runtimeState = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        runtimeState.windowRestoreCatalog = PersistedWindowRestoreCatalog(entries: [persistedEntry])
        let reloadedRuntimeState = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        XCTAssertEqual(
            reloadedRuntimeState.windowRestoreCatalog?.entries.first?.restoreIntent.detachedNiriContainerSizingState,
            expected
        )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: reloadedRuntimeState,
            autosaveEnabled: false
        )
        let controller = Self.controller(settings: settings)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        var liveMetadata = metadata
        liveMetadata.workspaceId = workspaceId

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: liveMetadata
        )

        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            expected
        )
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), workspaceId)
    }

    func testPersistedFloatingHydrationPreservesFullPlacementUntilTiling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
        let token = WindowToken(pid: 810, windowId: 101)
        let placeholderWorkspaceId = WorkspaceDescriptor.ID()
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.hydrated-floating-placement",
            workspaceId: placeholderWorkspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Hydrated Floating Placement",
            windowLevel: 0,
            parentWindowId: nil,
            frame: CGRect(x: 40, y: 50, width: 720, height: 520)
        )
        let columnState = PersistedNiriColumnState(
            displayMode: .normal,
            activeTileIndex: 0,
            width: .proportion(0.64),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: .fixed(700),
            hasManualSingleWindowWidthOverride: true,
            height: .proportion(0.71),
            isFullHeight: false,
            savedHeight: .fixed(730),
            hasManualSingleWindowHeightOverride: true
        )
        let windowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(605),
            savedHeight: .auto(weight: 1.4),
            windowWidth: .fixed(465)
        )
        let placement = PersistedNiriPlacement(
            columnIndex: 0,
            tileIndex: 0,
            column: columnState,
            window: windowState
        )
        let detachedState = NiriContainerSizingState(
            width: columnState.width,
            presetWidthIndex: columnState.presetWidthIndex,
            isFullWidth: columnState.isFullWidth,
            savedWidth: columnState.savedWidth,
            hasManualSingleWindowWidthOverride: columnState.hasManualSingleWindowWidthOverride,
            height: columnState.height,
            isFullHeight: columnState.isFullHeight,
            savedHeight: columnState.savedHeight,
            hasManualSingleWindowHeightOverride: columnState.hasManualSingleWindowHeightOverride
        )
        let persistedEntry = PersistedWindowRestoreEntry(
            key: try XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata)),
            identity: try XCTUnwrap(PersistedWindowRestoreIdentity(token: token, metadata: metadata)),
            restoreIntent: PersistedRestoreIntent(
                workspaceName: "1",
                topologyProfile: TopologyProfile(sortedMonitors: []),
                preferredMonitor: nil,
                floatingFrame: CGRect(x: 40, y: 50, width: 720, height: 520),
                normalizedFloatingOrigin: nil,
                restoreToFloating: true,
                rescueEligible: true,
                niriPlacement: placement,
                detachedNiriContainerSizingState: detachedState
            )
        )
        let runtimeState = RuntimeStateStore(
            directory: root.appendingPathComponent("state", isDirectory: true),
            deferSaves: false
        )
        runtimeState.windowRestoreCatalog = PersistedWindowRestoreCatalog(entries: [persistedEntry])
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
        let controller = Self.controller(settings: settings)
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()
        var liveMetadata = metadata
        liveMetadata.workspaceId = workspaceId

        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            managedReplacementMetadata: liveMetadata
        )

        XCTAssertEqual(controller.workspaceManager.windowMode(for: token), .floating)
        XCTAssertEqual(controller.workspaceManager.restoreIntent(for: token)?.niriPlacement, placement)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            detachedState
        )

        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 80, y: 90, width: 760, height: 540),
            for: token,
            restoreToFloating: true
        )
        XCTAssertEqual(controller.workspaceManager.restoreIntent(for: token)?.niriPlacement, placement)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            detachedState
        )

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: token))
        _ = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        let engine = try XCTUnwrap(controller.niriEngine)
        let restoredNode = try XCTUnwrap(engine.findNode(for: token, in: workspaceId))
        XCTAssertEqual(engine.persistedPlacement(for: token, in: workspaceId)?.column, columnState)
        XCTAssertEqual(restoredNode.sizingMode, windowState.sizingMode)
        XCTAssertEqual(restoredNode.height, windowState.height)
        XCTAssertEqual(restoredNode.savedHeight, windowState.savedHeight)
        XCTAssertEqual(restoredNode.windowWidth, windowState.windowWidth)
    }

    func testNiriSourceMoveKeepsLiveSizingOverAdmissionHint() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(805), windowId: 95),
            pid: 805,
            windowId: 95,
            to: sourceWorkspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.5),
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.source-move-width",
                workspaceId: sourceWorkspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "Source Move",
                windowLevel: 0,
                parentWindowId: nil,
                frame: nil
            )
        )
        let expected = NiriContainerSizingState(
            width: .proportion(0.88),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false,
            height: .proportion(0.8),
            isFullHeight: false,
            savedHeight: .fixed(700),
            hasManualSingleWindowHeightOverride: true
        )
        let expectedWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(610),
            savedHeight: .auto(weight: 1.5),
            windowWidth: .fixed(470)
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        var node: NiriWindow?
        controller.workspaceManager.withEngineMutationScope {
            let addedNode = engine.addWindow(token: token, to: sourceWorkspaceId, afterSelection: nil)
            node = addedNode
            guard let column = engine.column(of: addedNode) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
            addedNode.sizingMode = expectedWindowState.sizingMode
            addedNode.height = expectedWindowState.height
            addedNode.savedHeight = expectedWindowState.savedHeight
            addedNode.windowWidth = expectedWindowState.windowWidth
        }

        let result = controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) { sourceState, targetState in
            guard let node,
                  let moveResult = engine.moveWindowToWorkspace(
                      node,
                      from: sourceWorkspaceId,
                      to: targetWorkspaceId,
                      sourceState: &sourceState,
                      targetState: &targetState
                  )
            else {
                return nil
            }
            return (moveResult, [token])
        }

        XCTAssertNotNil(result)
        XCTAssertEqual(engine.containerSizingState(for: token, in: targetWorkspaceId), expected)
        XCTAssertNil(controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.niriPlacement?.window,
            expectedWindowState
        )
        XCTAssertEqual(
            controller.workspaceManager.admissionHints(for: token)?.initialNiriContainerPrimarySpan,
            0.5
        )

        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
        let persisted = try XCTUnwrap(
            controller.settings.loadPersistedWindowRestoreCatalog().entries.first {
                $0.identity?.windowId == token.windowId
            }
        )
        XCTAssertNil(persisted.restoreIntent.detachedNiriContainerSizingState)
        XCTAssertEqual(persisted.restoreIntent.niriPlacement?.window, expectedWindowState)

        let placements = controller.workspaceManager.withBatchedLayoutBuild {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [targetWorkspaceId])
        }.first?.niriRestorePlacements ?? [:]
        controller.workspaceManager.setNiriRestorePlacements(placements)
        XCTAssertNil(controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState)
    }

    func testNiriColumnMoveCommitsEveryLivePlacementWithoutDetachedMarkers() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        controller.niriLayoutHandler.enableNiriLayout()

        let firstToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(811), windowId: 102),
            pid: 811,
            windowId: 102,
            to: sourceWorkspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(811), windowId: 103),
            pid: 811,
            windowId: 103,
            to: sourceWorkspaceId
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let firstWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(580),
            savedHeight: .auto(weight: 1.2),
            windowWidth: .fixed(350)
        )
        let secondWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(620),
            savedHeight: .auto(weight: 1.8),
            windowWidth: .fixed(510)
        )
        let expectedContainerHeight = ProportionalSize.proportion(0.69)
        var movedColumn: NiriContainer?
        controller.workspaceManager.withEngineMutationScope {
            let first = engine.addWindow(token: firstToken, to: sourceWorkspaceId, afterSelection: nil)
            let second = engine.addWindow(
                token: secondToken,
                to: sourceWorkspaceId,
                afterSelection: first.id
            )
            var state = ViewportState()
            state.selectedNodeId = first.id
            guard let firstColumn = engine.column(of: first) else {
                XCTFail("Expected source Niri container")
                return
            }
            XCTAssertTrue(
                engine.consumeWindow(
                    second,
                    into: firstColumn,
                    enteringFrom: .down,
                    in: sourceWorkspaceId,
                    motion: .disabled,
                    state: &state,
                    workingFrame: CGRect(x: 0, y: 0, width: 1200, height: 1600),
                    gaps: 0,
                    orientation: .vertical
                )
            )
            firstColumn.height = expectedContainerHeight
            first.sizingMode = firstWindowState.sizingMode
            first.height = firstWindowState.height
            first.savedHeight = firstWindowState.savedHeight
            first.windowWidth = firstWindowState.windowWidth
            second.sizingMode = secondWindowState.sizingMode
            second.height = secondWindowState.height
            second.savedHeight = secondWindowState.savedHeight
            second.windowWidth = secondWindowState.windowWidth
            movedColumn = firstColumn
        }
        let column = try XCTUnwrap(movedColumn)

        let result = controller.workspaceManager.withBatchedWorkspaceMove(
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        ) { sourceState, targetState in
            guard let moveResult = engine.moveColumnToWorkspace(
                column,
                from: sourceWorkspaceId,
                to: targetWorkspaceId,
                sourceState: &sourceState,
                targetState: &targetState,
                targetOrientation: .vertical
            ) else {
                return nil
            }
            return (moveResult, [firstToken, secondToken])
        }

        XCTAssertNotNil(result)
        XCTAssertEqual(controller.workspaceManager.workspace(for: firstToken), targetWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.workspace(for: secondToken), targetWorkspaceId)
        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: firstToken)?.detachedNiriContainerSizingState
        )
        XCTAssertNil(
            controller.workspaceManager.restoreIntent(for: secondToken)?.detachedNiriContainerSizingState
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: firstToken)?.niriPlacement?.column.height,
            expectedContainerHeight
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: secondToken)?.niriPlacement?.column.height,
            expectedContainerHeight
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: firstToken)?.niriPlacement?.window,
            firstWindowState
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: secondToken)?.niriPlacement?.window,
            secondWindowState
        )
    }

    func testNiriToDwindleMoveCapturesLiveSizingBeforeDirectRemoval() throws {
        let controller = Self.controller()
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let targetWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        var configurations = controller.settings.workspaceConfigurations
        let targetIndex = try XCTUnwrap(configurations.firstIndex { $0.name == "2" })
        configurations[targetIndex] = configurations[targetIndex].with(layoutType: .dwindle)
        controller.settings.workspaceConfigurations = configurations
        controller.niriLayoutHandler.enableNiriLayout()

        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(806), windowId: 96),
            pid: 806,
            windowId: 96,
            to: sourceWorkspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.4)
        )
        let expected = NiriContainerSizingState(
            width: .fixed(680),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: .proportion(0.7),
            hasManualSingleWindowWidthOverride: true,
            height: .fixed(740),
            isFullHeight: true,
            savedHeight: .proportion(0.65),
            hasManualSingleWindowHeightOverride: true
        )
        let expectedWindowState = PersistedNiriWindowState(
            sizingMode: .normal,
            height: .fixed(600),
            savedHeight: .auto(weight: 1.6),
            windowWidth: .fixed(460)
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        controller.workspaceManager.withEngineMutationScope {
            let node = engine.addWindow(token: token, to: sourceWorkspaceId, afterSelection: nil)
            guard let column = engine.column(of: node) else {
                XCTFail("Expected Niri column")
                return
            }
            Self.apply(expected, to: column)
            node.sizingMode = expectedWindowState.sizingMode
            node.height = expectedWindowState.height
            node.savedHeight = expectedWindowState.savedHeight
            node.windowWidth = expectedWindowState.windowWidth
        }

        XCTAssertTrue(
            controller.workspaceNavigationHandler.moveWindow(
                handle: WindowHandle(id: token),
                toWorkspaceId: targetWorkspaceId
            ).didMutate
        )

        XCTAssertNil(engine.findNode(for: token, in: sourceWorkspaceId))
        XCTAssertEqual(controller.workspaceManager.workspace(for: token), targetWorkspaceId)
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.detachedNiriContainerSizingState,
            expected
        )
        XCTAssertEqual(
            controller.workspaceManager.restoreIntent(for: token)?.niriPlacement?.window,
            expectedWindowState
        )
    }

    private static func controller(settings: SettingsStore? = nil) -> WMController {
        if let settings {
            return configuredController(settings: settings)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMTests-\(UUID().uuidString)", isDirectory: true)
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
        return configuredController(settings: settings)
    }

    private static func configuredController(settings: SettingsStore) -> WMController {
        WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }

    private static func apply(_ state: NiriContainerSizingState, to column: NiriContainer) {
        column.width = state.width
        column.presetWidthIdx = state.presetWidthIndex
        column.isFullWidth = state.isFullWidth
        column.savedWidth = state.savedWidth
        column.hasManualSingleWindowWidthOverride = state.hasManualSingleWindowWidthOverride
        column.height = state.height
        column.isFullHeight = state.isFullHeight
        column.savedHeight = state.savedHeight
        column.hasManualSingleWindowHeightOverride = state.hasManualSingleWindowHeightOverride
        column.cachedHeight = 0
    }
}
