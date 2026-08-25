// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func captureResponse(
        for request: IPCCaptureRequest,
        id: String,
        controller: WMController
    ) async -> IPCResponse {
        switch request {
        case let .start(profile):
            let outcome = await controller.toggleTraceCapture(
                desiredState: .active,
                profile: traceCaptureProfile(for: profile)
            )
            return captureResponse(for: outcome, id: id, controller: controller)
        case .stop:
            let outcome = await controller.toggleTraceCapture(desiredState: .inactive)
            return captureResponse(for: outcome, id: id, controller: controller)
        case .status:
            return .success(
                id: id,
                kind: .capture,
                result: IPCResult(capture: captureResult(from: controller.traceCaptureStatus))
            )
        }
    }

    @MainActor
    private static func captureResponse(
        for outcome: TraceCaptureOutcome,
        id: String,
        controller: WMController
    ) -> IPCResponse {
        switch outcome {
        case .started,
             .stopped:
            return .success(
                id: id,
                kind: .capture,
                status: .executed,
                result: IPCResult(capture: captureResult(from: controller.traceCaptureStatus))
            )
        case .noChange:
            return .failure(
                id: id,
                kind: .capture,
                code: .captureStateConflict,
                result: IPCResult(capture: captureResult(from: controller.traceCaptureStatus))
            )
        case let .writeFailed(reason):
            return .failure(
                id: id,
                kind: .capture,
                code: .internalError,
                result: IPCResult(
                    capture: captureResult(
                        from: controller.traceCaptureStatus,
                        failureReason: reason
                    )
                )
            )
        }
    }

    private static func captureResult(
        from status: TraceCaptureStatus,
        failureReason: String? = nil
    ) -> IPCCaptureResult {
        IPCCaptureResult(
            phase: capturePhase(for: status.phase),
            profile: status.profile.map(captureProfile(for:)),
            startedAt: status.startedAt?.ISO8601Format(),
            lastArtifact: status.lastArtifact.map { artifact in
                IPCCaptureArtifact(
                    profile: captureProfile(for: artifact.profile),
                    path: artifact.url.path,
                    startedAt: artifact.startedAt.ISO8601Format(),
                    endedAt: artifact.endedAt.ISO8601Format()
                )
            },
            failureReason: failureReason.map(RuntimeTraceLimits.boundedString)
        )
    }

    private static func traceCaptureProfile(for profile: IPCCaptureProfile) -> TraceCaptureProfile {
        switch profile {
        case .trace:
            .problem
        case .performance:
            .performance
        }
    }

    private static func captureProfile(for profile: TraceCaptureProfile) -> IPCCaptureProfile {
        switch profile {
        case .problem:
            .trace
        case .performance:
            .performance
        }
    }

    private static func capturePhase(for phase: TraceCapturePhase) -> IPCCapturePhase {
        switch phase {
        case .idle:
            .idle
        case .starting:
            .starting
        case .recording:
            .recording
        case .finalizing:
            .finalizing
        }
    }
}
