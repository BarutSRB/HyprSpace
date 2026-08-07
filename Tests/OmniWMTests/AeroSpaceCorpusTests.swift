// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

struct AeroSpaceCorpusExpectation: Codable, Equatable {
    var aeroSpaceLabel: String
    var expectedDisposition: String
    var expectedPolicy: String
    var note: String?
}

@MainActor
final class AeroSpaceCorpusTests: XCTestCase {
    private func expectations() throws -> [String: AeroSpaceCorpusExpectation] {
        let resourceURL = try XCTUnwrap(Bundle.module.resourceURL)
        let url = resourceURL.appendingPathComponent("Fixtures/AeroSpaceAxDumps/expectations.json")
        return try JSONDecoder().decode(
            [String: AeroSpaceCorpusExpectation].self,
            from: Data(contentsOf: url)
        )
    }

    func testCorpusIsLoadedAndFullyCovered() throws {
        let (dumps, coverage) = try AeroSpaceAxDumpLoader.load()
        XCTAssertFalse(dumps.isEmpty, "AeroSpace corpus loaded no dumps")
        XCTAssertEqual(
            coverage.loaded + coverage.skippedNonWindowRole + coverage.skippedMissingWindowLevel,
            coverage.files
        )
        let table = try expectations()
        XCTAssertEqual(
            Set(table.keys),
            Set(dumps.map(\.name)),
            "expectations.json and the loaded dumps disagree"
        )
    }

    func testEveryDumpMatchesItsReviewedExpectation() throws {
        let (dumps, _) = try AeroSpaceAxDumpLoader.load()
        let table = try expectations()
        for dump in dumps {
            let expected = try XCTUnwrap(table[dump.name], "\(dump.name): no expectation")
            let got = WindowClassificationReproducer.recomputeOutcome(dump.observation, rules: [])
            XCTAssertEqual(got.decision.disposition, expected.expectedDisposition, "\(dump.name): disposition")
            XCTAssertEqual(got.policy, expected.expectedPolicy, "\(dump.name): interaction policy")
        }
    }

    func testDivergencesFromAeroSpaceCarryAReason() throws {
        let expectedForLabel = [
            "popup": ("floating", "handsOffSurface"),
            "dialog": ("floating", "full"),
            "window": ("managed", "full")
        ]
        for (name, expectation) in try expectations() {
            let aero = try XCTUnwrap(
                expectedForLabel[expectation.aeroSpaceLabel],
                "\(name): unknown AeroSpace label \(expectation.aeroSpaceLabel)"
            )
            let diverges = expectation.expectedDisposition != aero.0 || expectation.expectedPolicy != aero.1
            if diverges {
                XCTAssertNotNil(
                    expectation.note,
                    "\(name): diverges from AeroSpace (\(expectation.aeroSpaceLabel)) without a note"
                )
            } else {
                XCTAssertNil(expectation.note, "\(name): has a divergence note but does not diverge")
            }
        }
    }

    func testManagedWindowsAlwaysKeepFullRights() throws {
        let (dumps, _) = try AeroSpaceAxDumpLoader.load()
        for dump in dumps {
            let got = WindowClassificationReproducer.recomputeOutcome(dump.observation, rules: [])
            if got.decision.disposition == "managed" {
                XCTAssertEqual(
                    got.policy,
                    "full",
                    "\(dump.name): a tiled window must keep every capability, otherwise it occupies a "
                        + "layout slot OmniWM may never frame-write"
                )
            }
        }
    }
}
