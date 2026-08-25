// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class InputAmplificationTests: XCTestCase {
    func testMultitouchSourceExistsOnlyWhileGestureFeatureIsEnabled() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DynamicMultitouch")
        controller.settings.scrollGestureEnabled = false
        controller.settings.workspaceSwipeEnabled = false
        controller.hasStartedServices = true
        let handler = controller.mouseEventHandler
        var sourceCreations = 0
        handler.multitouchSourceFactory = {
            sourceCreations += 1
            return MultitouchGestureSource(operations: nil)
        }

        handler.reconcileMultitouchSource()
        XCTAssertEqual(sourceCreations, 0)
        XCTAssertNil(handler.multitouchDiagnosticsSnapshot)

        controller.settings.workspaceSwipeEnabled = true
        handler.reconcileMultitouchSource()
        XCTAssertEqual(sourceCreations, 1)
        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .unavailable)

        controller.settings.workspaceSwipeEnabled = false
        handler.reconcileMultitouchSource()
        XCTAssertNil(handler.multitouchDiagnosticsSnapshot)
        XCTAssertNil(MultitouchGestureSource.shared)
        controller.hasStartedServices = false
    }

    func testGestureAvailabilityCallbackOnlyFiresForAggregateTransitions() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "GestureAvailability")
        let settings = controller.settings
        settings.scrollGestureEnabled = false
        settings.workspaceSwipeEnabled = false
        var states: [Bool] = []
        settings.onTrackpadGestureAvailabilityChanged = { states.append($0) }

        settings.scrollGestureEnabled = true
        settings.workspaceSwipeEnabled = true
        settings.scrollGestureEnabled = false
        settings.workspaceSwipeEnabled = false

        XCTAssertEqual(states, [true, false])
    }

    func testTrackpadScrollDoesNotEnterEventIntake() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "TrackpadScrollIntake")
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }
        let initialSequence = controller.eventIntake.lastSeq

        _ = controller.mouseEventHandler.receiveTapScrollWheel(
            at: .zero,
            deltaX: 1,
            deltaY: 2,
            momentumPhase: 0,
            phase: CGScrollPhase.changed.rawValue,
            modifiers: []
        )
        XCTAssertEqual(controller.eventIntake.lastSeq, initialSequence)

        _ = controller.mouseEventHandler.receiveTapScrollWheel(
            at: .zero,
            deltaX: 1,
            deltaY: 2,
            momentumPhase: 0,
            phase: 0,
            modifiers: []
        )
        XCTAssertEqual(controller.eventIntake.lastSeq, initialSequence + 1)
    }
}
