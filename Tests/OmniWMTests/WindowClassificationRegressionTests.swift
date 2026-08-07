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
            let got = WindowClassificationReproducer.recomputeOutcome(
                fixture.observation,
                rules: fixture.rules
            )
            XCTAssertEqual(got.decision, fixture.expectedDecision, "\(name): decision")
            XCTAssertEqual(got.policy, fixture.expectedPolicy, "\(name): interaction policy")
        }
    }

    func testFixtureRequiresMaintainerAuthoredExpectedDecision() throws {
        let url = try XCTUnwrap(WindowClassificationFixtureLoader.fixtureURLs().first)
        let data = try Data(contentsOf: url)
        for required in ["expectedDecision", "expectedPolicy"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: required)
            let truncated = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(WindowClassificationRegressionFixture.self, from: truncated),
                "fixture decoded without \(required)"
            )
        }
    }

    func testHandsOffSurfacesAreDistinguishedFromOrdinaryFloatingWindows() throws {
        let byPolicy = try Dictionary(
            grouping: WindowClassificationFixtureLoader.fixtureURLs()
                .map { ($0.lastPathComponent, try WindowClassificationFixtureLoader.load($0)) },
            by: { $0.1.expectedPolicy }
        )
        let floatingFixtures = byPolicy.values.flatMap { $0 }
            .filter { $0.1.expectedDecision.disposition == "floating" }
        XCTAssertTrue(
            Set(floatingFixtures.map { $0.1.expectedPolicy }).count > 1,
            "every floating fixture resolves to the same policy, so the corpus cannot detect a lost suppression"
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
