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

    func testPrivateAPIProbeRequiresSuccessfulForeignMoveAndRestoreForGreenStatus() {
        let report = privateAPIProbeReport(
            foreign: ForeignWindowProbeResult(
                targetPid: 42,
                targetWid: 7,
                movedDelta: CGPoint(x: 6, y: 6),
                skylightMoved: true,
                restored: false,
                outcome: .failed,
                detail: "restore=unavailable"
            )
        )

        XCTAssertEqual(
            privateAPIProbePresentationStatus(for: report),
            .failure("1 checks, 0 failures · foreign transaction move=yes, restored=no")
        )
    }

    func testPrivateAPIProbeWithoutUnmanagedTargetIsNonGreen() {
        XCTAssertEqual(
            privateAPIProbePresentationStatus(for: privateAPIProbeReport(foreign: nil)),
            .failure("Inconclusive: 1 checks, 0 failures · no unmanaged foreign window probed")
        )
    }

    func testPrivateAPIProbeSuccessfulForeignMoveAndRestoreIsGreen() {
        let report = privateAPIProbeReport(
            foreign: ForeignWindowProbeResult(
                targetPid: 42,
                targetWid: 7,
                movedDelta: CGPoint(x: 6, y: 6),
                skylightMoved: true,
                restored: true,
                outcome: .works,
                detail: "submission=submitted restore=submitted"
            )
        )

        XCTAssertEqual(
            privateAPIProbePresentationStatus(for: report),
            .success("1 checks, 0 failures · foreign transaction move=yes, restored=yes")
        )
    }

    @MainActor
    func testForeignProbeBaselineRequiresMatchingOrigins() {
        XCTAssertTrue(
            PrivateAPIHealthDiagnostics.originsMatch(
                CGPoint(x: 100, y: 200),
                CGPoint(x: 101, y: 201)
            )
        )
        XCTAssertFalse(
            PrivateAPIHealthDiagnostics.originsMatch(
                CGPoint(x: 100, y: 200),
                CGPoint(x: 102, y: 200)
            )
        )
    }

    @MainActor
    func testForeignProbeFallsBackToDirectRestoreWhenTransactionRestoreIsUnavailable() async throws {
        let sample = foreignProbeSample()
        let baseline = sample.frame.origin
        let target = CGPoint(x: baseline.x + 6, y: baseline.y + 6)
        var origin = baseline
        var batchTargets: [CGPoint] = []
        var directTargets: [CGPoint] = []
        let operations = foreignProbeOperations(
            sample: sample,
            origin: { origin },
            batchMove: { requested in
                batchTargets.append(requested)
                if batchTargets.count == 1 {
                    origin = requested
                    return .submitted
                }
                return .unavailable
            },
            directMove: { requested in
                directTargets.append(requested)
                origin = requested
                return true
            },
            waitForOrigin: { requested in
                PrivateAPIHealthDiagnostics.originsMatch(origin, requested) ? origin : nil
            }
        )

        let optionalResult = await PrivateAPIHealthDiagnostics.activeForeignWindowProbe(
            sample: sample,
            operations: operations
        )
        let result = try XCTUnwrap(optionalResult)

        XCTAssertEqual(batchTargets, [target, baseline])
        XCTAssertEqual(directTargets, [baseline])
        XCTAssertTrue(result.skylightMoved)
        XCTAssertTrue(result.restored)
        guard case .works = result.outcome else {
            return XCTFail("expected successful probe after direct restoration")
        }
    }

    @MainActor
    func testForeignProbeSealsUnobservedMoveWithDirectBaselineRestore() async throws {
        let sample = foreignProbeSample()
        let baseline = sample.frame.origin
        var origin = baseline
        var directTargets: [CGPoint] = []
        let operations = foreignProbeOperations(
            sample: sample,
            origin: { origin },
            batchMove: { _ in .submitted },
            directMove: { requested in
                directTargets.append(requested)
                origin = requested
                return true
            },
            waitForOrigin: { requested in
                PrivateAPIHealthDiagnostics.originsMatch(origin, requested) ? origin : nil
            }
        )

        let optionalResult = await PrivateAPIHealthDiagnostics.activeForeignWindowProbe(
            sample: sample,
            operations: operations
        )
        let result = try XCTUnwrap(optionalResult)

        XCTAssertEqual(directTargets, [baseline])
        XCTAssertFalse(result.skylightMoved)
        XCTAssertTrue(result.restored)
        guard case .failed = result.outcome else {
            return XCTFail("expected an unobserved move to remain non-green")
        }
    }

    @MainActor
    func testForeignProbeDoesNotRestoreAfterOriginInterference() async throws {
        let sample = foreignProbeSample()
        let baseline = sample.frame.origin
        let target = CGPoint(x: baseline.x + 6, y: baseline.y + 6)
        let interferedOrigin = CGPoint(x: baseline.x + 80, y: baseline.y + 40)
        var origin = baseline
        var directMoveCount = 0
        let operations = foreignProbeOperations(
            sample: sample,
            origin: { origin },
            batchMove: { requested in
                origin = requested
                return .submitted
            },
            directMove: { _ in
                directMoveCount += 1
                return true
            },
            waitForOrigin: { requested in
                guard PrivateAPIHealthDiagnostics.originsMatch(requested, target) else { return nil }
                let observed = origin
                origin = interferedOrigin
                return observed
            }
        )

        let optionalResult = await PrivateAPIHealthDiagnostics.activeForeignWindowProbe(
            sample: sample,
            operations: operations
        )
        let result = try XCTUnwrap(optionalResult)

        XCTAssertEqual(directMoveCount, 0)
        XCTAssertEqual(origin, interferedOrigin)
        XCTAssertFalse(result.restored)
        guard case .inconclusive = result.outcome else {
            return XCTFail("expected interference to make the probe inconclusive")
        }
    }

    @MainActor
    func testForeignProbeDoesNotRestoreAfterIdentityLoss() async throws {
        let sample = foreignProbeSample()
        var origin = sample.frame.origin
        var queryCount = 0
        var directMoveCount = 0
        var operations = foreignProbeOperations(
            sample: sample,
            origin: { origin },
            batchMove: { requested in
                origin = requested
                return .submitted
            },
            directMove: { _ in
                directMoveCount += 1
                return true
            },
            waitForOrigin: { requested in
                PrivateAPIHealthDiagnostics.originsMatch(origin, requested) ? origin : nil
            }
        )
        operations = ForeignWindowProbeOperations(
            queryWindowInfo: { _ in
                queryCount += 1
                return queryCount == 1 ? sample : nil
            },
            windowBounds: operations.windowBounds,
            independentOrigin: operations.independentOrigin,
            batchMove: operations.batchMove,
            directMove: operations.directMove,
            waitForOrigin: operations.waitForOrigin
        )

        let optionalResult = await PrivateAPIHealthDiagnostics.activeForeignWindowProbe(
            sample: sample,
            operations: operations
        )
        let result = try XCTUnwrap(optionalResult)

        XCTAssertEqual(directMoveCount, 0)
        XCTAssertFalse(result.restored)
        guard case .inconclusive = result.outcome else {
            return XCTFail("expected identity loss to make the probe inconclusive")
        }
    }

    private func privateAPIProbeReport(foreign: ForeignWindowProbeResult?) -> PrivateAPIProbeReport {
        PrivateAPIProbeReport(
            ranAt: Date(timeIntervalSince1970: 1),
            selfTests: [PrivateAPISelfTest(api: "self-test", outcome: .works, detail: "ok")],
            foreign: foreign
        )
    }

    private func foreignProbeSample() -> WindowServerInfo {
        WindowServerInfo(
            id: 7,
            pid: 42,
            level: 0,
            frame: CGRect(x: 100, y: 200, width: 600, height: 400)
        )
    }

    private func foreignProbeOperations(
        sample: WindowServerInfo,
        origin: @escaping () -> CGPoint,
        batchMove: @escaping (CGPoint) -> SkyLight.TransactionSubmissionResult,
        directMove: @escaping (CGPoint) -> Bool,
        waitForOrigin: @escaping (CGPoint) async -> CGPoint?
    ) -> ForeignWindowProbeOperations {
        ForeignWindowProbeOperations(
            queryWindowInfo: { _ in sample },
            windowBounds: { _ in sample.frame },
            independentOrigin: { _, _ in origin() },
            batchMove: { _, target in batchMove(target) },
            directMove: { _, target in directMove(target) },
            waitForOrigin: { _, _, target in await waitForOrigin(target) }
        )
    }
}
