// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWMCtl
import XCTest

final class TerminalCellWidthTests: XCTestCase {
    func testMeasuresTextAndEastAsianWidths() {
        XCTAssertEqual(TerminalCellWidth.measure(""), 0)
        XCTAssertEqual(TerminalCellWidth.measure("ASCII"), 5)
        XCTAssertEqual(TerminalCellWidth.measure("界"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("Ａ"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("ｱ"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("e\u{0301}"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("\u{0301}"), 0)
        XCTAssertEqual(TerminalCellWidth.measure("क्ष"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("§Ω·"), 3)
    }

    func testMeasuresEmojiSequences() {
        XCTAssertEqual(TerminalCellWidth.measure("🚀"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("☀"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("☀️"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("☀︎"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("\u{FE0F}"), 0)
        XCTAssertEqual(TerminalCellWidth.measure("A\u{FE0F}"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("👩🏽‍💻"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("👁‍🗨"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("1\u{200D}"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("🇨🇦"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("🇨"), 1)
        XCTAssertEqual(TerminalCellWidth.measure("1️⃣"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("1⃣"), 2)
        XCTAssertEqual(TerminalCellWidth.measure("\u{20E3}"), 0)
        XCTAssertEqual(TerminalCellWidth.measure("A\u{20E3}"), 1)
    }
}
