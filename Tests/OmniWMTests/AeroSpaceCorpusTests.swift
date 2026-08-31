// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

struct AeroSpaceCorpusExpectation: Codable, Equatable {
    var aeroSpaceLabel: String
    var expectedDisposition: String
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
            coverage.loaded + coverage.skippedMissingWindowLevel,
            coverage.files
        )
        let table = try expectations()
        XCTAssertEqual(
            Set(table.keys),
            Set(dumps.map(\.name)),
            "expectations.json and the loaded dumps disagree"
        )
    }

    func testNonWindowRolesRemainInTheCorpusAndAreUntracked() throws {
        let (dumps, _) = try AeroSpaceAxDumpLoader.load()
        let nonWindowRoleDumps = dumps.filter {
            $0.observation.input.ax.role != (kAXWindowRole as String)
        }

        XCTAssertFalse(nonWindowRoleDumps.isEmpty)
        for dump in nonWindowRoleDumps {
            let got = WindowClassificationReproducer.recompute(dump.observation, rules: [])
            XCTAssertEqual(got.disposition, "unmanaged", dump.name)
        }
    }

    func testReviewedPopupBoundaryPreservesRootProofFacts() throws {
        let (dumps, _) = try AeroSpaceAxDumpLoader.load()
        let table = Dictionary(uniqueKeysWithValues: dumps.map { ($0.name, $0) })
        let expected: [String: (isMain: Bool, isModal: Bool)] = [
            "emacs_child_frame_corfu": (false, false),
            "emacs_child_frame_posframe": (false, false),
            "macos_capslock_popup_safari": (false, false),
            "macos_capslock_popup_textedit": (false, false),
            "macos_share_window_purple_pill_sublime": (false, false),
            "ghostty_check_for_updates_2_alert": (false, true),
            "ghostty_quick_terminal": (true, false),
            "intellij_native_open_window": (true, true)
        ]

        for (name, rootProof) in expected {
            let dump = try XCTUnwrap(table[name], name)
            XCTAssertEqual(dump.observation.input.ax.isMain, rootProof.isMain, name)
            XCTAssertEqual(dump.observation.input.ax.isModal, rootProof.isModal, name)
        }
    }

    func testEveryDumpMatchesItsReviewedExpectation() throws {
        let (dumps, _) = try AeroSpaceAxDumpLoader.load()
        let table = try expectations()
        for dump in dumps {
            let expected = try XCTUnwrap(table[dump.name], "\(dump.name): no expectation")
            let got = WindowClassificationReproducer.recompute(dump.observation, rules: [])
            XCTAssertEqual(got.disposition, expected.expectedDisposition, "\(dump.name): disposition")
        }
    }

    func testDivergencesFromAeroSpaceCarryAReason() throws {
        let expectedForLabel = [
            "popup": "unmanaged",
            "dialog": "floating",
            "window": "managed"
        ]
        for (name, expectation) in try expectations() {
            let aero = try XCTUnwrap(
                expectedForLabel[expectation.aeroSpaceLabel],
                "\(name): unknown AeroSpace label \(expectation.aeroSpaceLabel)"
            )
            let diverges = expectation.expectedDisposition != aero
            if diverges {
                XCTAssertNotNil(
                    expectation.note,
                    "\(name): diverges from AeroSpace (\(expectation.aeroSpaceLabel)) without a note"
                )
            }
        }
    }
}
