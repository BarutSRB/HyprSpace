// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsRecordingPresentationTests: XCTestCase {
    func testRecordingStartSuccessAndNoChangeArePresented() {
        XCTAssertEqual(
            diagnosticsRecordingStartStatus(for: .started),
            .success("Recording started")
        )
        XCTAssertEqual(
            diagnosticsRecordingStartStatus(for: .noChange),
            .failure("A recording is already running")
        )
    }

    func testRecordingStartWriteFailureIsPresentedVerbatim() {
        XCTAssertEqual(
            diagnosticsRecordingStartStatus(for: .writeFailed("Diagnostics directory is read-only")),
            .failure("Diagnostics directory is read-only")
        )
    }

    func testRecordingStartStoppedOutcomeRemainsUnexpected() {
        let artifact = TraceCaptureArtifact(
            profile: .problem,
            url: URL(fileURLWithPath: "/tmp/recording.log"),
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            diagnosticsRecordingStartStatus(for: .stopped(artifact)),
            .failure("Unexpected recording state")
        )
    }
}
