// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StatusMenuControlHelpTests: XCTestCase {
    func testControlCatalogHasExactlyTheUniqueSettingIdentifiers() {
        let identifiers = StatusMenuControl.allCases.map(\.id)
        let expectedIdentifiers: Set<String> = [
            "bordersEnabled",
            "workspaceBarEnabled",
            "preventSleepEnabled",
            "focusFollowsMouse",
            "focusCrossesMonitorAtEdge",
            "moveMouseToFocusedWindow",
            "focusFollowsWindowToMonitor",
            "moveCrossesMonitorAtEdge",
            "mouseWarpEnabled",
            "hiddenBarEnabled"
        ]

        XCTAssertEqual(Set(identifiers), expectedIdentifiers)
        XCTAssertEqual(identifiers.count, expectedIdentifiers.count)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testEveryControlHasCompleteDistinctHelpMetadata() {
        for control in StatusMenuControl.allCases {
            XCTAssertFalse(control.icon.isEmpty, "\(control.id) has no icon")
            XCTAssertFalse(control.label.isEmpty, "\(control.id) has no label")
            XCTAssertFalse(control.accessibilityName.isEmpty, "\(control.id) has no accessibility name")
            XCTAssertFalse(control.explanation.isEmpty, "\(control.id) has no explanation")
            XCTAssertNotEqual(control.explanation, control.label, "\(control.id) repeats its label as help")
        }
    }

    func testEveryControlHasTheExpectedPreview() {
        let expectedPreviews: [StatusMenuControl: StatusMenuControlPreview] = [
            .bordersEnabled: .focusedWindow,
            .workspaceBarEnabled: .workspaceBar,
            .preventSleepEnabled: .keepAwake,
            .focusFollowsMouse: .focusMouse,
            .focusCrossesMonitorAtEdge: .focusEdge,
            .moveMouseToFocusedWindow: .mouseToFocused,
            .focusFollowsWindowToMonitor: .followMonitor,
            .moveCrossesMonitorAtEdge: .moveEdge,
            .mouseWarpEnabled: .mouseWarp,
            .hiddenBarEnabled: .hiddenMenuIcons
        ]

        XCTAssertEqual(expectedPreviews.count, StatusMenuControl.allCases.count)
        for control in StatusMenuControl.allCases {
            XCTAssertEqual(control.preview, expectedPreviews[control], "\(control.id) has the wrong preview")
        }
    }

    func testRoutedPreviewPhaseCyclesDirectionsAtSuccessiveBoundaries() {
        let phases = (0 ... 4).map { cycle in
            StatusMenuControlPreviewPhase(
                timeInterval: Double(cycle) * StatusMenuControlPreviewPhase.cycleDuration
            )
        }

        XCTAssertEqual(phases.map(\.direction), [.right, .down, .left, .up, .right])
        XCTAssertTrue(phases.allSatisfy { $0.progress == 0 })
    }

    func testRoutedPreviewPhaseClampsProgressAndDefinesStaticEnd() {
        XCTAssertEqual(
            StatusMenuControlPreviewPhase(direction: .left, progress: -0.5),
            StatusMenuControlPreviewPhase(direction: .left, progress: 0)
        )
        XCTAssertEqual(
            StatusMenuControlPreviewPhase(direction: .up, progress: 1.5),
            StatusMenuControlPreviewPhase(direction: .up, progress: 1)
        )
        XCTAssertEqual(
            StatusMenuControlPreviewPhase.staticEnd,
            StatusMenuControlPreviewPhase(direction: .right, progress: 1)
        )
    }

    func testRoutedGeometryOwnsFourContainedWindowsPerDisplay() {
        for direction in StatusMenuControlPreviewDirection.allCases {
            let geometry = StatusMenuControlRoutedGeometry(direction: direction)

            XCTAssertEqual(geometry.sourceWindows.count, 4, "\(direction) source window count")
            XCTAssertEqual(geometry.destinationWindows.count, 4, "\(direction) destination window count")
            for window in geometry.sourceWindows {
                XCTAssertTrue(geometry.sourceDisplay.contains(window), "\(direction) source window escapes its display")
            }
            for window in geometry.destinationWindows {
                XCTAssertTrue(
                    geometry.destinationDisplay.contains(window),
                    "\(direction) destination window escapes its display"
                )
            }
        }
    }

    func testRoutedGeometryOrientsDisplaysAndArrowForEveryDirection() {
        for direction in StatusMenuControlPreviewDirection.allCases {
            let geometry = StatusMenuControlRoutedGeometry(direction: direction)

            switch direction {
            case .right:
                XCTAssertLessThan(geometry.sourceDisplay.maxX, geometry.destinationDisplay.minX)
                XCTAssertLessThan(geometry.arrowStart.x, geometry.arrowEnd.x)
                XCTAssertEqual(geometry.arrowStart.y, geometry.arrowEnd.y)
            case .down:
                XCTAssertLessThan(geometry.sourceDisplay.maxY, geometry.destinationDisplay.minY)
                XCTAssertLessThan(geometry.arrowStart.y, geometry.arrowEnd.y)
                XCTAssertEqual(geometry.arrowStart.x, geometry.arrowEnd.x)
            case .left:
                XCTAssertGreaterThan(geometry.sourceDisplay.minX, geometry.destinationDisplay.maxX)
                XCTAssertGreaterThan(geometry.arrowStart.x, geometry.arrowEnd.x)
                XCTAssertEqual(geometry.arrowStart.y, geometry.arrowEnd.y)
            case .up:
                XCTAssertGreaterThan(geometry.sourceDisplay.minY, geometry.destinationDisplay.maxY)
                XCTAssertGreaterThan(geometry.arrowStart.y, geometry.arrowEnd.y)
                XCTAssertEqual(geometry.arrowStart.x, geometry.arrowEnd.x)
            }
        }
    }

    func testDirectionalEdgeExplanationsExplicitlyCoverEveryDirection() {
        for control in [StatusMenuControl.focusCrossesMonitorAtEdge, .moveCrossesMonitorAtEdge] {
            let words = Set(
                control.explanation
                    .lowercased()
                    .components(separatedBy: CharacterSet.letters.inverted)
                    .filter { !$0.isEmpty }
            )

            for direction in ["left", "right", "up", "down"] {
                XCTAssertTrue(words.contains(direction), "\(control.id) omits \(direction)")
            }
        }
    }

    func testFocusFollowsMouseHelpPointsToRaiseBehaviorInSettings() {
        let explanation = StatusMenuControl.focusFollowsMouse.explanation

        XCTAssertTrue(explanation.contains("raises"))
        XCTAssertTrue(explanation.contains("Settings"))
    }

    func testHoveredControlIsPresentedOnlyAfterDwellCompletes() {
        var selection = StatusMenuHelpSelection()

        selection.hoverEntered(.focusFollowsMouse)

        XCTAssertEqual(selection.hoveredControl, .focusFollowsMouse)
        XCTAssertNil(selection.presentedControl)
        XCTAssertTrue(selection.presentHovered(.focusFollowsMouse))
        XCTAssertEqual(selection.presentedControl, .focusFollowsMouse)
    }

    func testStaleHoverExitCannotClearANewerHover() {
        var selection = StatusMenuHelpSelection()
        selection.hoverEntered(.focusFollowsMouse)
        selection.hoverEntered(.mouseWarpEnabled)
        XCTAssertTrue(selection.presentHovered(.mouseWarpEnabled))

        XCTAssertFalse(selection.hoverExited(.focusFollowsMouse))
        XCTAssertEqual(selection.hoveredControl, .mouseWarpEnabled)
        XCTAssertEqual(selection.presentedControl, .mouseWarpEnabled)
    }

    func testHoverTakesPrecedenceAndFocusBecomesFallbackAfterSettle() {
        var selection = StatusMenuHelpSelection()
        selection.focusChanged(.bordersEnabled, isFocused: true)
        selection.hoverEntered(.workspaceBarEnabled)
        XCTAssertTrue(selection.presentHovered(.workspaceBarEnabled))

        selection.focusChanged(.preventSleepEnabled, isFocused: true)

        XCTAssertEqual(selection.focusedControl, .preventSleepEnabled)
        XCTAssertEqual(selection.presentedControl, .workspaceBarEnabled)
        XCTAssertTrue(selection.hoverExited(.workspaceBarEnabled))
        XCTAssertEqual(selection.presentedControl, .workspaceBarEnabled)

        selection.settleAfterHoverExit()

        XCTAssertEqual(selection.presentedControl, .preventSleepEnabled)
    }

    func testFocusAlonePresentsImmediately() {
        var selection = StatusMenuHelpSelection()

        selection.focusChanged(.moveCrossesMonitorAtEdge, isFocused: true)

        XCTAssertEqual(selection.focusedControl, .moveCrossesMonitorAtEdge)
        XCTAssertEqual(selection.presentedControl, .moveCrossesMonitorAtEdge)
    }

    func testResetClearsHoverFocusAndPresentation() {
        var selection = StatusMenuHelpSelection()
        selection.focusChanged(.bordersEnabled, isFocused: true)
        selection.hoverEntered(.mouseWarpEnabled)
        XCTAssertTrue(selection.presentHovered(.mouseWarpEnabled))

        selection.reset()

        XCTAssertNil(selection.hoveredControl)
        XCTAssertNil(selection.focusedControl)
        XCTAssertNil(selection.presentedControl)
    }

    func testPresentationSchedulesExactHoverDwellBeforePresenting() async {
        let sleeper = StatusMenuHelpManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }

        presentation.hoverChanged(.focusFollowsMouse, isHovered: true)

        XCTAssertEqual(presentation.selection.hoveredControl, .focusFollowsMouse)
        XCTAssertNil(presentation.selection.presentedControl)

        await drainStatusMenuHelpTasks()

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertNil(presentation.selection.presentedControl)

        sleeper.resumeNext()
        await drainStatusMenuHelpTasks()

        XCTAssertEqual(presentation.selection.presentedControl, .focusFollowsMouse)
    }

    func testPresentationCancelsFirstDwellDuringRapidHover() async {
        let sleeper = StatusMenuHelpManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }

        presentation.hoverChanged(.focusFollowsMouse, isHovered: true)
        await drainStatusMenuHelpTasks()
        presentation.hoverChanged(.mouseWarpEnabled, isHovered: true)
        await drainStatusMenuHelpTasks()

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300), .milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(presentation.selection.hoveredControl, .mouseWarpEnabled)
        XCTAssertNil(presentation.selection.presentedControl)

        sleeper.resumeNext()
        await drainStatusMenuHelpTasks()

        XCTAssertEqual(presentation.selection.presentedControl, .mouseWarpEnabled)
    }

    func testPresentationKeepsHoveredHelpThroughExactExitGrace() async {
        let sleeper = StatusMenuHelpManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }
        presentation.focusChanged(.bordersEnabled, isFocused: true)
        presentation.hoverChanged(.workspaceBarEnabled, isHovered: true)
        await drainStatusMenuHelpTasks()
        sleeper.resumeNext()
        await drainStatusMenuHelpTasks()

        presentation.hoverChanged(.workspaceBarEnabled, isHovered: false)

        XCTAssertNil(presentation.selection.hoveredControl)
        XCTAssertEqual(presentation.selection.presentedControl, .workspaceBarEnabled)

        await drainStatusMenuHelpTasks()

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300), .milliseconds(150)])
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(presentation.selection.presentedControl, .workspaceBarEnabled)

        sleeper.resumeNext()
        await drainStatusMenuHelpTasks()

        XCTAssertEqual(presentation.selection.presentedControl, .bordersEnabled)
    }

    func testPresentationResetCancelsPendingTransition() async {
        let sleeper = StatusMenuHelpManualSleeper()
        let presentation = StatusMenuHelpPresentation { try await sleeper.sleep(for: $0) }
        presentation.hoverChanged(.moveCrossesMonitorAtEdge, isHovered: true)
        await drainStatusMenuHelpTasks()

        presentation.reset()
        await drainStatusMenuHelpTasks()

        XCTAssertEqual(sleeper.requestedDurations, [.milliseconds(300)])
        XCTAssertEqual(sleeper.pendingCount, 0)
        XCTAssertNil(presentation.selection.hoveredControl)
        XCTAssertNil(presentation.selection.focusedControl)
        XCTAssertNil(presentation.selection.presentedControl)
    }

    func testMenuPresentationGenerationAdvancesOnOpenAndClose() {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 0)

        fixture.model.menuWillOpen()

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)

        fixture.model.menuDidClose()

        XCTAssertEqual(fixture.model.menuPresentationGeneration, 2)
    }

    func testHiddenBarTileInclusionMatchesControllerAvailability() {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let hiddenBarTiles = fixture.model.toggleTiles.filter { $0.control == .hiddenBarEnabled }

        XCTAssertEqual(hiddenBarTiles.count, fixture.controller.isHiddenBarHidingAvailable ? 1 : 0)
    }

    func testFocusFollowsMouseTileDoesNotChangeRaisePreference() throws {
        let fixture = makeStatusMenuModelFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.settings.raiseOnMouseFocus = true
        let tile = try XCTUnwrap(fixture.model.toggleTiles.first { $0.control == .focusFollowsMouse })

        tile.isOn.wrappedValue = true
        tile.isOn.wrappedValue = false

        XCTAssertTrue(fixture.model.settings.raiseOnMouseFocus)
    }

    private struct StatusMenuModelFixture {
        let root: URL
        let controller: WMController
        let model: StatusMenuModel
    }

    private func makeStatusMenuModelFixture() -> StatusMenuModelFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMStatusMenuHelpTests-\(UUID().uuidString)", isDirectory: true)
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
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard", isDirectory: true),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true)
        )
        return StatusMenuModelFixture(
            root: root,
            controller: controller,
            model: StatusMenuModel(settings: settings, controller: controller)
        )
    }
}

@MainActor
private final class StatusMenuHelpManualSleeper {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var requestedDurations: [Duration] = []
    private var nextId: UInt64 = 0
    private var waiters: [Waiter] = []

    var pendingCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        nextId &+= 1
        let id = nextId
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

@MainActor
private func drainStatusMenuHelpTasks() async {
    for _ in 0 ..< 8 {
        await Task.yield()
    }
}
