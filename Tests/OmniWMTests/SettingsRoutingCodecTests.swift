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
        export.monitorRoutingSettings = [
            MonitorRoutingSettings(monitorName: "Studio Display", monitorDisplayId: 7, gridColumn: 1, gridRow: 0),
            MonitorRoutingSettings(monitorName: "Built-in", monitorDisplayId: 2, gridColumn: 0, gridRow: 0)
        ]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertEqual(decoded.monitorRoutingMode, .custom)
        XCTAssertFalse(decoded.mouseWarpEnabled)
        XCTAssertEqual(decoded.monitorRoutingSettings, export.monitorRoutingSettings)
    }

    func testRoutingDefaults() throws {
        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(.defaults()))

        XCTAssertEqual(decoded.monitorRoutingMode, .macOS)
        XCTAssertTrue(decoded.mouseWarpEnabled)
        XCTAssertTrue(decoded.monitorRoutingSettings.isEmpty)
    }
}
