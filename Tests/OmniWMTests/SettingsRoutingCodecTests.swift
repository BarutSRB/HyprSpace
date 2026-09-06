// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsRoutingCodecTests: XCTestCase {
    func testRoutingSettingsRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.monitorRoutingMode = .custom
        export.mouseWarpEnabled = false
        export.monitorArrangements = [MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Studio Display", monitorDisplayId: 7, gridColumn: 1, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 0)
        ]), MonitorArrangement(monitors: [
            MonitorRoutingSettings(monitorName: "Work Display", monitorDisplayId: 9, gridColumn: 0, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 1)
        ])]

        let encoded = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("[[routing.arrangements.monitors]]"))
        XCTAssertFalse(text.contains("monitorRoutingOverrides"))
        let mode = try XCTUnwrap(text.range(of: "mode = \"custom\""))
        let arrangements = try XCTUnwrap(text.range(of: "[[routing.arrangements]]"))
        XCTAssertLessThan(mode.lowerBound, arrangements.lowerBound)

        let decoded = try SettingsTOMLCodec.decode(encoded)

        XCTAssertEqual(decoded.monitorRoutingMode, .custom)
        XCTAssertFalse(decoded.mouseWarpEnabled)
        XCTAssertEqual(decoded.monitorArrangements, export.monitorArrangements)
    }

    func testRoutingDefaults() throws {
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(.defaults()))

        XCTAssertEqual(decoded.monitorRoutingMode, .macOS)
        XCTAssertTrue(decoded.mouseWarpEnabled)
        XCTAssertTrue(decoded.monitorArrangements.isEmpty)
        XCTAssertTrue(String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .contains("arrangements = []"))
    }
}
