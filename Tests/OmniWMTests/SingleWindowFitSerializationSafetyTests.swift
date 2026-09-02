// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class SingleWindowFitSerializationSafetyTests: XCTestCase {
    func testNonFiniteDimensionsRejectDeserialization() {
        for serialized in ["1e999x1e999", "1e999x100", "100x1e999", "nanx100", "100xnan"] {
            XCTAssertNil(SingleWindowFit(serialized: serialized))
        }
    }

    func testHugeFiniteDimensionsRoundTripAsCustom() {
        let fits = [
            SingleWindowFit(mode: .custom, width: 1e30, height: 100),
            SingleWindowFit(mode: .custom, width: 100, height: Double.greatestFiniteMagnitude)
        ]

        for fit in fits {
            XCTAssertTrue(fit.hasValidCustomSize)
            XCTAssertEqual(SingleWindowFit(serialized: fit.serialized), fit)
        }
    }

    func testDirectCustomSerializationHandlesIntegerBoundary() throws {
        let boundary = Double(Int.max)
        XCTAssertNil(Int(exactly: boundary))
        XCTAssertEqual(
            SingleWindowFit(mode: .custom, width: boundary, height: 100).serialized,
            "\(String(boundary))x100"
        )
        XCTAssertEqual(
            SingleWindowFit(mode: .custom, width: 100, height: boundary).serialized,
            "100x\(String(boundary))"
        )

        let representable = boundary.nextDown
        let integer = try XCTUnwrap(Int(exactly: representable))
        XCTAssertEqual(
            SingleWindowFit(mode: .custom, width: representable, height: 100).serialized,
            "\(integer)x100"
        )
    }

    func testInvalidDirectCustomSizesSerializeAsFullScreen() {
        let fits = [
            SingleWindowFit(mode: .custom, width: .infinity, height: 100),
            SingleWindowFit(mode: .custom, width: -.infinity, height: 100),
            SingleWindowFit(mode: .custom, width: .nan, height: 100),
            SingleWindowFit(mode: .custom, width: 0, height: 100),
            SingleWindowFit(mode: .custom, width: -1, height: 100),
            SingleWindowFit(mode: .custom, width: 100, height: .infinity),
            SingleWindowFit(mode: .custom, width: 100, height: .nan)
        ]

        for fit in fits {
            XCTAssertEqual(fit.serialized, "fill")
        }
    }

    func testTOMLRoundTripsExtremeCustomDimensions() throws {
        let boundaryFit = SingleWindowFit(mode: .custom, width: Double(Int.max), height: 720)
        let hugeFit = SingleWindowFit(mode: .custom, width: 1024, height: Double.greatestFiniteMagnitude)
        var export = SettingsExport.defaults()
        export.niriSingleWindowFit = boundaryFit
        export.monitorDwindleSettings = [MonitorDwindleSettings(monitorName: "Extreme", singleWindowFit: hugeFit)]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))

        XCTAssertEqual(decoded.niriSingleWindowFit, boundaryFit)
        XCTAssertEqual(decoded.monitorDwindleSettings.first?.singleWindowFit, hugeFit)
    }
}
