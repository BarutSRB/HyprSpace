// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowClassificationRegressionTests: XCTestCase {
    func testAllFixturesMatchEngine() throws {
        let urls = try WindowClassificationFixtureLoader.fixtureURLs()
        XCTAssertFalse(urls.isEmpty, "No window-classification fixtures found")
        for url in urls {
            let name = url.lastPathComponent
            let fixture = try WindowClassificationFixtureLoader.load(url)
            let got = WindowClassificationReproducer.recompute(
                fixture.observation,
                rules: fixture.rules
            )
            XCTAssertEqual(got, fixture.expectedDecision, "\(name): decision")
        }
    }

    func testFixtureRequiresMaintainerAuthoredExpectedDecision() throws {
        let url = try XCTUnwrap(WindowClassificationFixtureLoader.fixtureURLs().first)
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "expectedDecision")
        let truncated = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(WindowClassificationRegressionFixture.self, from: truncated),
            "fixture decoded without expectedDecision"
        )
    }

    func testObservedDecisionDoesNotDefineExpectedBehavior() throws {
        let url = try XCTUnwrap(WindowClassificationFixtureLoader.fixtureURLs().first)
        var fixture = try WindowClassificationFixtureLoader.load(url)
        fixture.observation.observedDecision.disposition =
            fixture.expectedDecision.disposition == "managed" ? "floating" : "managed"
        let got = WindowClassificationReproducer.recompute(
            fixture.observation,
            rules: fixture.rules
        )
        XCTAssertEqual(got, fixture.expectedDecision)
        XCTAssertNotEqual(got, fixture.observation.observedDecision)
    }
}
