// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriInitialContainerPrimarySpanTests: XCTestCase {
    func testNilSeedUsesConfiguredDefaultContainerPrimarySpan() throws {
        let engine = NiriLayoutEngine()
        engine.defaultContainerPrimarySpan = 0.6
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 0)

        let window = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let column = try XCTUnwrap(engine.column(of: window))

        XCTAssertEqual(column.width, .proportion(0.6))
        XCTAssertEqual(column.height, .proportion(0.6))
        XCTAssertNil(column.presetWidthIdx)
        XCTAssertFalse(column.isFullWidth)
        XCTAssertFalse(column.isFullHeight)
        XCTAssertFalse(column.hasManualSingleWindowWidthOverride)
        XCTAssertFalse(column.hasManualSingleWindowHeightOverride)
    }

    func testExplicitInitialProportionSeedsBothPrimaryAxes() {
        let engine = NiriLayoutEngine()

        let state = engine.initialContainerSizingState(for: 0.5)

        XCTAssertEqual(state.width, .proportion(0.5))
        XCTAssertEqual(state.height, .proportion(0.5))
        XCTAssertEqual(state.presetWidthIndex, 1)
        XCTAssertFalse(state.isFullWidth)
        XCTAssertFalse(state.isFullHeight)
        XCTAssertNil(state.savedWidth)
        XCTAssertNil(state.savedHeight)
        XCTAssertFalse(state.hasManualSingleWindowWidthOverride)
        XCTAssertFalse(state.hasManualSingleWindowHeightOverride)
    }

    func testAutomaticInitialProportionSeedsBothAxesFromVisibleContainerCount() throws {
        let engine = NiriLayoutEngine(visibleContainerCount: 4)
        engine.defaultContainerPrimarySpan = nil
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 11)

        let window = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        let column = try XCTUnwrap(engine.column(of: window))

        XCTAssertEqual(column.width, .proportion(0.25))
        XCTAssertEqual(column.height, .proportion(0.25))
        XCTAssertNil(column.presetWidthIdx)
    }

    func testInitialPrimaryProportionSurvivesOrientationRotation() throws {
        let engine = NiriLayoutEngine()
        engine.defaultContainerPrimarySpan = 0.5
        let workspaceId = WorkspaceDescriptor.ID()
        let firstToken = WindowToken(pid: 283, windowId: 12)
        let secondToken = WindowToken(pid: 283, windowId: 13)
        let first = engine.addWindow(token: firstToken, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(token: secondToken, to: workspaceId, afterSelection: first.id)
        var state = ViewportState()
        state.selectedNodeId = first.id
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let horizontalFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: frame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .horizontal
        )
        let verticalFrames = engine.calculateLayout(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: frame,
            gaps: (horizontal: 0, vertical: 0),
            orientation: .vertical
        )

        XCTAssertEqual(try XCTUnwrap(horizontalFrames[firstToken]).width, 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[firstToken]).height, 400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(verticalFrames[secondToken]).height, 400, accuracy: 0.001)
    }

    func testInitialFullWidthProportionUsesNormalWidthStateAndMatchingPreset() {
        let engine = NiriLayoutEngine()
        engine.presetContainerPrimarySpans = [.proportion(0.5), .proportion(1)]

        let state = engine.initialContainerSizingState(for: 1)

        XCTAssertEqual(state.width, .proportion(1))
        XCTAssertEqual(state.presetWidthIndex, 1)
        XCTAssertFalse(state.isFullWidth)
        XCTAssertNil(state.savedWidth)
        XCTAssertFalse(state.hasManualSingleWindowWidthOverride)
    }

    func testFreshWindowClaimAppliesDurableStateAndResetsTransientWidthState() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 1)
        let state = NiriContainerSizingState(
            width: .fixed(640),
            presetWidthIndex: nil,
            isFullWidth: true,
            savedWidth: .proportion(0.5),
            hasManualSingleWindowWidthOverride: true
        )

        let window = engine.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: state
        )
        let column = try XCTUnwrap(engine.column(of: window))

        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), state)
        XCTAssertEqual(column.cachedWidth, 0)
        XCTAssertNil(column.widthAnimation)
        XCTAssertNil(column.targetWidth)
    }

    func testEmptyPlaceholderClaimAppliesSeedAndClearsTransientWidthState() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let root = engine.ensureRoot(for: workspaceId)
        let placeholder = NiriContainer()
        placeholder.width = .fixed(900)
        placeholder.cachedWidth = 900
        placeholder.widthAnimation = animation(from: 700, to: 900)
        placeholder.targetWidth = 900
        root.appendChild(placeholder)
        let state = engine.initialContainerSizingState(for: 0.5)

        let window = engine.addWindow(
            token: WindowToken(pid: 283, windowId: 2),
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: state
        )

        XCTAssertTrue(engine.column(of: window) === placeholder)
        XCTAssertEqual(placeholder.width, .proportion(0.5))
        XCTAssertEqual(placeholder.presetWidthIdx, 1)
        XCTAssertEqual(placeholder.cachedWidth, 0)
        XCTAssertNil(placeholder.widthAnimation)
        XCTAssertNil(placeholder.targetWidth)
    }

    func testExistingWindowIgnoresCompetingSeedWithoutResettingTransients() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 3)
        let originalState = engine.initialContainerSizingState(for: 0.5)
        let window = engine.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: originalState
        )
        let column = try XCTUnwrap(engine.column(of: window))
        let widthAnimation = animation(from: 500, to: 600)
        column.cachedWidth = 500
        column.widthAnimation = widthAnimation
        column.targetWidth = 600

        let duplicate = engine.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: engine.initialContainerSizingState(for: 0.75)
        )

        XCTAssertTrue(duplicate === window)
        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), originalState)
        XCTAssertEqual(column.cachedWidth, 500)
        XCTAssertTrue(column.widthAnimation === widthAnimation)
        XCTAssertEqual(column.targetWidth, 600)
    }

    func testSyncSeedsOnlyMissingWindows() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let existingToken = WindowToken(pid: 283, windowId: 4)
        let missingToken = WindowToken(pid: 283, windowId: 5)
        let existingState = engine.initialContainerSizingState(for: 0.5)
        _ = engine.addWindow(
            token: existingToken,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: existingState
        )
        let missingState = NiriContainerSizingState(
            width: .proportion(0.75),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false
        )

        _ = engine.syncWindows(
            [existingToken, missingToken],
            in: workspaceId,
            selectedNodeId: nil,
            containerSizingStates: [
                existingToken: engine.initialContainerSizingState(for: 1),
                missingToken: missingState
            ]
        )

        XCTAssertEqual(engine.containerSizingState(for: existingToken, in: workspaceId), existingState)
        XCTAssertEqual(engine.containerSizingState(for: missingToken, in: workspaceId), missingState)
    }

    func testSyncAppliesIndependentSeedsToTwoFreshWindows() {
        let engine = NiriLayoutEngine()
        engine.presetContainerPrimarySpans = [.proportion(0.5), .proportion(1)]
        let workspaceId = WorkspaceDescriptor.ID()
        let halfToken = WindowToken(pid: 283, windowId: 8)
        let fullToken = WindowToken(pid: 283, windowId: 9)
        let halfState = engine.initialContainerSizingState(for: 0.5)
        let fullState = engine.initialContainerSizingState(for: 1)

        _ = engine.syncWindows(
            [halfToken, fullToken],
            in: workspaceId,
            selectedNodeId: nil,
            containerSizingStates: [
                halfToken: halfState,
                fullToken: fullState
            ]
        )

        XCTAssertEqual(engine.containerSizingState(for: halfToken, in: workspaceId), halfState)
        XCTAssertEqual(engine.containerSizingState(for: fullToken, in: workspaceId), fullState)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)
    }

    func testSingleWindowFitWinsWithoutDiscardingInitialWidth() {
        let engine = NiriLayoutEngine()
        engine.singleWindowFit = .fullScreen
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 6)
        let initialState = engine.initialContainerSizingState(for: 0.5)
        _ = engine.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: initialState
        )
        let workingFrame = CGRect(x: 24, y: 16, width: 1200, height: 760)
        let fullscreenFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let area = WorkingAreaContext(
            workingFrame: workingFrame,
            fullscreenLayoutFrame: fullscreenFrame,
            viewFrame: fullscreenFrame,
            scale: 1
        )

        let frame = engine.calculateLayout(
            state: ViewportState(),
            workspaceId: workspaceId,
            monitorFrame: workingFrame,
            gaps: (horizontal: 12, vertical: 12),
            workingArea: area,
            orientation: .horizontal
        )[token]

        XCTAssertEqual(frame, fullscreenFrame)
        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), initialState)
    }

    func testInitialWidthResolvesAgainstInstalledMinimumConstraint() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 283, windowId: 7)
        let window = engine.addWindow(
            token: token,
            to: workspaceId,
            afterSelection: nil,
            containerSizingState: engine.initialContainerSizingState(for: 0.25)
        )
        engine.updateWindowConstraints(
            for: token,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 700, height: 1),
                maxSize: .zero,
                isFixed: false
            ),
            in: workspaceId,
            motion: .enabled
        )
        let column = try XCTUnwrap(engine.column(of: window))

        column.resolveAndCacheWidth(workingAreaWidth: 1200, gaps: 12)

        XCTAssertEqual(column.cachedWidth, 700)
        XCTAssertEqual(
            engine.containerSizingState(for: token, in: workspaceId),
            engine.initialContainerSizingState(for: 0.25)
        )
    }

    @MainActor
    func testHandlerSeedsAdmissionWidthBeforeFirstConstraintResolutionAndLeavesLiveStateUntouched() throws {
        let controller = makeController()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        controller.settings.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                orientation: .horizontal
            ),
            for: monitor
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(283), windowId: 10),
            pid: 283,
            windowId: 10,
            to: workspaceId,
            ruleEffects: ManagedWindowRuleEffects(
                minWidth: 700,
                minHeight: nil,
                matchedRuleId: nil
            ),
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: 0.25)
        )

        let firstPlans = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
        let engine = try XCTUnwrap(controller.niriEngine)
        let column = try XCTUnwrap(
            engine.findNode(for: token, in: workspaceId).flatMap { engine.column(of: $0) }
        )
        let initialState = engine.initialContainerSizingState(for: 0.25)

        XCTAssertFalse(firstPlans.isEmpty)
        XCTAssertEqual(column.width, .proportion(0.25))
        XCTAssertEqual(column.height, .proportion(0.25))
        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), initialState)
        XCTAssertEqual(column.cachedWidth, 700)

        column.width = .fixed(720)
        column.presetWidthIdx = nil
        column.isFullWidth = true
        column.savedWidth = .proportion(0.25)
        column.hasManualSingleWindowWidthOverride = true
        column.cachedWidth = 720
        let liveState = try XCTUnwrap(engine.containerSizingState(for: token, in: workspaceId))

        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        XCTAssertEqual(engine.containerSizingState(for: token, in: workspaceId), liveState)
        XCTAssertEqual(column.cachedWidth, 720)
    }

    private func animation(from: Double, to: Double) -> SpringAnimation {
        SpringAnimation(
            from: from,
            to: to,
            startTime: 0,
            config: .niriWindowMovement,
            displayRefreshRate: 60
        )
    }

    @MainActor
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniWMNiriInitialContainerPrimarySpanTests-\(UUID().uuidString)",
                isDirectory: true
            )
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
