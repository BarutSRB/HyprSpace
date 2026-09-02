// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class DefaultWorkspaceBindingContractTests: XCTestCase {
    func testEveryDefaultDigitBindingTargetsABuiltInWorkspace() {
        let workspaceNames = Set(BuiltInSettingsDefaults.workspaceConfigurations.map(\.name))
        var boundIndices: [Int] = []

        for binding in HotkeyBindingRegistry.defaults() where binding.binding != .unassigned {
            switch binding.command {
            case let .switchWorkspace(index),
                 let .moveToWorkspace(index):
                boundIndices.append(index)
                XCTAssertTrue(workspaceNames.contains(String(index + 1)), binding.id)
            default:
                continue
            }
        }

        XCTAssertEqual(Set(boundIndices), Set(0 ..< 9))
    }

    func testBuiltInWorkspaceNamesAndIdsAreUnique() {
        let configurations = BuiltInSettingsDefaults.workspaceConfigurations

        XCTAssertEqual(configurations.map(\.name), (1 ... 9).map(String.init))
        XCTAssertEqual(Set(configurations.map(\.id)).count, configurations.count)
    }
}
