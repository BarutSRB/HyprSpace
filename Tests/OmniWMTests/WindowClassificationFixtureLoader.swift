// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM

struct WindowClassificationRegressionFixture: Codable, Equatable, Sendable {
    var observation: WindowClassificationObservation
    var rules: [AppRule]
    var expectedDecision: WindowClassificationDecisionDTO
}

enum WindowClassificationFixtureLoader {
    static func fixtureURLs() throws -> [URL] {
        guard let resourceURL = Bundle.module.resourceURL else { return [] }
        let directory = resourceURL.appendingPathComponent("Fixtures/WindowClassification", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func load(_ url: URL) throws -> WindowClassificationRegressionFixture {
        try JSONDecoder().decode(WindowClassificationRegressionFixture.self, from: Data(contentsOf: url))
    }
}
