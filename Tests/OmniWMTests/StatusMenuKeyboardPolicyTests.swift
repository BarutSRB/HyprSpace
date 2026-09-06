// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import SwiftUI
import XCTest

final class StatusMenuKeyboardPolicyTests: XCTestCase {
    func testPlainControlKeysAndShiftTabAreAccepted() {
        XCTAssertTrue(StatusMenuKeyboardPolicy.acceptsModifiers([]))
        XCTAssertTrue(StatusMenuKeyboardPolicy.acceptsModifiers([], allowingShift: true))
        XCTAssertTrue(StatusMenuKeyboardPolicy.acceptsModifiers(.shift, allowingShift: true))
        XCTAssertFalse(StatusMenuKeyboardPolicy.acceptsModifiers(.shift))
    }

    func testModifiedShortcutsPassThroughForActionsAndTraversal() {
        let shortcuts: [EventModifiers] = [
            .command, .control, .option,
            [.command, .shift], [.control, .shift], [.option, .shift],
            [.command, .control, .option]
        ]
        for modifiers in shortcuts {
            XCTAssertFalse(StatusMenuKeyboardPolicy.acceptsModifiers(modifiers))
            XCTAssertFalse(StatusMenuKeyboardPolicy.acceptsModifiers(modifiers, allowingShift: true))
        }
    }
}
