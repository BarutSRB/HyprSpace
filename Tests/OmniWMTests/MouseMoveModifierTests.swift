// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseMoveModifierTests: NiriInteractionTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let windowFrame: CGRect

        @MainActor var handler: MouseEventHandler {
            controller.mouseEventHandler
        }
    }

    func testMouseMoveModifierMappingsResolveExactly() throws {
        XCTAssertNil(MouseMoveModifierKey.off.cgEventFlags)
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: nil))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskAlternate, required: nil))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: []))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskShift, required: []))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: .maskAlternate))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskShift, required: .maskAlternate))

        let baseModifierFlags: [CGEventFlags] = [.maskAlternate, .maskControl, .maskCommand]
        for modifier in MouseMoveModifierKey.allCases where modifier != .off {
            let required = try XCTUnwrap(modifier.cgEventFlags)

            XCTAssertEqual(
                MouseEventHandler.mouseMoveMode(modifiers: required, required: required),
                .swap
            )
            if !required.contains(.maskShift) {
                XCTAssertEqual(
                    MouseEventHandler.mouseMoveMode(
                        modifiers: required.union(.maskShift),
                        required: required
                    ),
                    .insert
                )
            }
            XCTAssertEqual(
                MouseEventHandler.mouseMoveMode(
                    modifiers: required.union(.maskAlphaShift),
                    required: required
                ),
                .swap
            )

            for extra in baseModifierFlags where !required.contains(extra) {
                XCTAssertNil(
                    MouseEventHandler.mouseMoveMode(
                        modifiers: required.union(extra),
                        required: required
                    )
                )
            }
        }

        XCTAssertNil(
            MouseEventHandler.mouseMoveMode(
                modifiers: [.maskAlternate, .maskCommand],
                required: .maskAlternate
            )
        )
    }

    func testHyperKeyAlwaysTriggersMouseMove() {
        let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

        XCTAssertEqual(
            MouseEventHandler.mouseMoveMode(modifiers: hyperFlags, required: .maskAlternate),
            .swap
        )
        XCTAssertEqual(
            MouseEventHandler.mouseMoveMode(modifiers: hyperFlags, required: nil),
            .swap
        )
        XCTAssertTrue(
            MouseEventHandler.modifierFlagsMatch(hyperFlags, required: .maskAlternate)
        )
    }

    @MainActor
    func testOffDoesNotStartMoveForOptionDrag() throws {
        let fixture = try makeFixture(pid: 1_101)
        fixture.controller.settings.mouseMoveModifierKey = .off
        let worldSeq = fixture.controller.workspaceManager.worldSeq

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.handler.state.activeInteractionButton)
        XCTAssertNil(fixture.handler.state.dragGhostController)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
    }

    @MainActor
    func testConfiguredModifierReplacesOptionAndShiftSelectsInsert() throws {
        let fixture = try makeFixture(pid: 1_102)
        fixture.controller.settings.mouseMoveModifierKey = .control

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)

        XCTAssertTrue(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: [.maskControl, .maskShift]
            )
        )
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertEqual(fixture.handler.state.activeInteractionButton, .left)
        XCTAssertTrue(try XCTUnwrap(fixture.engine.interactiveMove).isInsertMode)

        fixture.handler.dispatchMouseUp(at: fixture.windowFrame.center)

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
    }

    @MainActor
    func testDefaultOptionStartsSwapAndSettingChangeDoesNotCancelActiveMove() throws {
        let fixture = try makeFixture(pid: 1_103)
        fixture.controller.settings.mouseMoveModifierKey = .option

        XCTAssertTrue(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertFalse(try XCTUnwrap(fixture.engine.interactiveMove).isInsertMode)

        fixture.controller.settings.mouseMoveModifierKey = .off

        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertNotNil(fixture.engine.interactiveMove)

        fixture.handler.dispatchMouseUp(at: fixture.windowFrame.center)

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
    }

    @MainActor
    func testMouseMoveSettingDoesNotChangeRightMouseResize() throws {
        let fixture = try makeFixture(pid: 1_104)
        fixture.controller.settings.mouseMoveModifierKey = .off
        fixture.controller.settings.mouseResizeModifierKey = .option
        let resizePoint = CGPoint(x: fixture.windowFrame.maxX - 1, y: fixture.windowFrame.midY)

        XCTAssertTrue(
            fixture.handler.dispatchMouseDown(
                at: resizePoint,
                modifiers: .maskAlternate,
                button: .right
            )
        )
        XCTAssertTrue(fixture.handler.state.isResizing)
        XCTAssertNotNil(fixture.engine.interactiveResize)

        fixture.handler.dispatchMouseUp(at: resizePoint, button: .right)

        XCTAssertFalse(fixture.handler.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    @MainActor
    func testDwindleLeftDragRemainsUnchanged() throws {
        let controller = makeController()
        controller.settings.defaultLayoutType = .dwindle
        controller.settings.mouseMoveModifierKey = .control
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        _ = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let worldSeq = controller.workspaceManager.worldSeq

        XCTAssertFalse(
            controller.mouseEventHandler.dispatchMouseDown(
                at: CGPoint(x: monitor.frame.midX, y: monitor.frame.midY),
                modifiers: .maskControl
            )
        )

        XCTAssertFalse(controller.mouseEventHandler.state.isMoving)
        XCTAssertNil(controller.mouseEventHandler.state.activeInteractionButton)
        XCTAssertNil(controller.dwindleEngine?.interactiveResize)
        XCTAssertEqual(controller.workspaceManager.worldSeq, worldSeq)
    }

    @MainActor
    private func makeFixture(pid: pid_t) throws -> Fixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let window = addWindow(engine, pid: pid, to: workspaceId)
        let gap = controller.innerGap(for: monitor)
        let frames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: controller.insetWorkingFrame(for: monitor),
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal
        )

        return Fixture(
            controller: controller,
            engine: engine,
            windowFrame: try XCTUnwrap(frames[window.token])
        )
    }

    @MainActor
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MouseMoveModifierTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 51_001),
            displayId: 51_001,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Mouse Move Modifier"
        )
    }
}
