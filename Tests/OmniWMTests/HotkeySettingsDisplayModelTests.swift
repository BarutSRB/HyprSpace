// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class HotkeySettingsDisplayModelTests: XCTestCase {
    func testAdvancedSearchMatchCountFindsReportedSizingCommands() {
        let ids = [
            "setContainerPrimarySpan.decrease10Percent",
            "setContainerPrimarySpan.increase10Percent",
            "setWindowSecondarySpan.decrease10Percent",
            "setWindowSecondarySpan.increase10Percent"
        ]
        let bindings = HotkeyBindingRegistry.defaults().filter { ids.contains($0.id) }

        XCTAssertEqual(HotkeySettingsDisplayModel.advancedSearchMatchCount("increase", bindings: bindings), 2)
        XCTAssertEqual(HotkeySettingsDisplayModel.advancedSearchMatchCount("decrease", bindings: bindings), 2)
    }

    func testAdvancedSearchMatchCountFindsMoveContainerCommandsByColumnID() {
        let ids = ["moveColumn.left", "moveColumn.right"]
        let bindings = HotkeyBindingRegistry.defaults().filter { ids.contains($0.id) }

        XCTAssertEqual(HotkeySettingsDisplayModel.advancedSearchMatchCount("column", bindings: bindings), 2)
    }

    func testAdvancedSearchMatchCountUsesConfiguredShortcut() throws {
        let shortcut = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("Hyper+Minus"))
        let binding = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "setContainerPrimarySpan.decrease10Percent",
            binding: shortcut
        ))

        XCTAssertEqual(
            HotkeySettingsDisplayModel.advancedSearchMatchCount("hyper+minus", bindings: [binding]),
            1
        )
    }

    func testAdvancedSearchMatchCountExcludesNormalAndHiddenCommands() {
        let ids = ["move.left", "moveColumn.left", "consumeOrExpelWindowLeft"]
        let bindings = HotkeyBindingRegistry.defaults().filter { ids.contains($0.id) }

        XCTAssertEqual(bindings.count, ids.count)
        XCTAssertEqual(HotkeySettingsDisplayModel.advancedSearchMatchCount("left", bindings: bindings), 1)
    }

    func testAdvancedSearchMatchCountRequiresAQuery() {
        XCTAssertEqual(
            HotkeySettingsDisplayModel.advancedSearchMatchCount("  ", bindings: HotkeyBindingRegistry.defaults()),
            0
        )
    }

    func testVisibilityKeepsAdvancedCommandsBehindTheToggle() {
        XCTAssertFalse(HotkeySettingsDisplayModel.isVisible(
            bindingId: "moveColumn.left",
            showsAdvancedHotkeys: false
        ))
        XCTAssertTrue(HotkeySettingsDisplayModel.isVisible(
            bindingId: "moveColumn.left",
            showsAdvancedHotkeys: true
        ))
        XCTAssertFalse(HotkeySettingsDisplayModel.isVisible(
            bindingId: "consumeOrExpelWindowLeft",
            showsAdvancedHotkeys: true
        ))
    }
}
