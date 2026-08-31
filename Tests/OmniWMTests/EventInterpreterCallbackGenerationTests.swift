// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class EventInterpreterCallbackGenerationTests: XCTestCase {
    @MainActor
    func testFocusedWindowCallbackRequiresCurrentGeneration() {
        let pid: pid_t = 701_001
        let currentGeneration: UInt64 = 12
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)

        var factReadCount = 0
        controller.factResolver.factProvider = { _ in
            factReadCount += 1
            return nil
        }
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(.axFocusedWindowChanged(pid: pid, callbackGeneration: currentGeneration - 1))
        )
        XCTAssertEqual(factReadCount, 0)

        interpreter.handleIntakeEvent(
            stamped(.axFocusedWindowChanged(pid: pid, callbackGeneration: currentGeneration))
        )
        XCTAssertEqual(factReadCount, 1)
    }

    @MainActor
    func testDestroyedWindowCallbackRequiresCurrentGeneration() throws {
        let pid: pid_t = 701_002
        let windowId = 801_002
        let currentGeneration: UInt64 = 22
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(
                .axWindowDestroyed(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration - 1
                )
            )
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))

        interpreter.handleIntakeEvent(
            stamped(
                .axWindowDestroyed(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration
                )
            )
        )
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    @MainActor
    func testMiniaturizedWindowCallbackRequiresCurrentGeneration() {
        let pid: pid_t = 701_003
        let token = WindowToken(pid: pid, windowId: 801_003)
        let currentGeneration: UInt64 = 32
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        _ = controller.workspaceManager.recordExternalFocus(pid: token.pid, windowId: token.windowId)
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(
                .axWindowMiniaturized(
                    pid: pid,
                    windowId: token.windowId,
                    callbackGeneration: currentGeneration - 1
                )
            )
        )
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, token)

        interpreter.handleIntakeEvent(
            stamped(
                .axWindowMiniaturized(
                    pid: pid,
                    windowId: token.windowId,
                    callbackGeneration: currentGeneration
                )
            )
        )
        XCTAssertNil(controller.workspaceManager.externalFocusToken)
    }

    private func stamped(_ event: IntakeEvent) -> StampedIntakeEvent {
        StampedIntakeEvent(seq: 1, event: event)
    }

    @MainActor
    private func stop(_ controller: WMController) {
        controller.factResolver.stop()
        controller.deadlineWheel.stop()
        controller.eventIntake.close()
    }
}
