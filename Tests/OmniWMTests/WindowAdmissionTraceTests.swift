// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

final class WindowAdmissionTraceTests: XCTestCase {
    func testInactiveRecorderDoesNotEvaluatePayload() {
        let recorder = WindowAdmissionTrace(capacity: 4)
        var evaluations = 0
        let makeEvent = {
            evaluations += 1
            return WindowAdmissionTraceEvent(action: .cgsCreated, windowId: 41)
        }

        recorder.record(makeEvent())

        XCTAssertEqual(evaluations, 0)
        XCTAssertEqual(recorder.dump(), "none")

        recorder.beginCapture()
        recorder.record(makeEvent())

        XCTAssertEqual(evaluations, 1)
        XCTAssertEqual(recorder.recordsSnapshot().map(\.action), [.cgsCreated])
    }

    func testCapacityEvictsOldestRecords() {
        let recorder = WindowAdmissionTrace(capacity: 3)
        recorder.beginCapture()

        for windowId in 1 ... 4 {
            recorder.record(.init(action: .cgsCreated, windowId: windowId))
        }

        XCTAssertEqual(recorder.recordsSnapshot().map(\.windowId), [2, 3, 4])
    }

    func testProcessWindowAndEndpointGenerationsAdvanceOnReuse() throws {
        let recorder = WindowAdmissionTrace(capacity: 32)
        let pid: pid_t = 8_101
        let windowId = 8_102
        let firstRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )
        recorder.beginCapture()

        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 3))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: firstRef)
        )
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: replacementRef)
        )
        recorder.record(.init(action: .cgsDestroyed, windowId: windowId))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: replacementRef)
        )
        recorder.record(.init(action: .endpointDestroyed, pid: pid))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 4))
        recorder.record(.init(action: .processTerminated, pid: pid))
        recorder.record(.init(action: .processLaunched, pid: pid))

        let records = recorder.recordsSnapshot()
        let recordsByIndex = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.offset, $0.element) })
        XCTAssertEqual(recordsByIndex[0]?.processGeneration, 1)
        XCTAssertEqual(recordsByIndex[1]?.endpointGeneration, 1)
        XCTAssertEqual(recordsByIndex[3]?.windowGeneration, 1)
        XCTAssertEqual(recordsByIndex[4]?.windowGeneration, 1)
        XCTAssertEqual(recordsByIndex[6]?.windowGeneration, 2)
        XCTAssertEqual(recordsByIndex[9]?.endpointGeneration, 2)
        XCTAssertEqual(recordsByIndex[11]?.processGeneration, 2)
        XCTAssertEqual(recordsByIndex[9]?.callbackGeneration, 4)
    }

    func testReusedOrDestroyedWindowCannotRemainFinalizationTarget() {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_111
        let windowId = 8_112
        let ref = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        recorder.beginCapture()
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .admissionPending, pid: pid, windowId: windowId, axRef: ref)
        )
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.windowId, windowId)

        recorder.record(.init(action: .cgsDestroyed, windowId: windowId))
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))

        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testLateEndpointGenerationCannotClearCurrentFailure() throws {
        let recorder = WindowAdmissionTrace(capacity: 32)
        let pid: pid_t = 8_121
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 1))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "old", callbackGeneration: 1)
        )
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 2))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "current", callbackGeneration: 2)
        )
        recorder.record(.init(action: .enumerationCompleted, pid: pid, callbackGeneration: 1))

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.reason, "current")
        XCTAssertEqual(target.endpointGeneration, 2)
        XCTAssertEqual(target.callbackGeneration, 2)
        XCTAssertNil(recorder.recordsSnapshot().last?.endpointGeneration)
    }

    func testUnknownCallbackEventCannotPreemptSeededEndpoint() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_125
        recorder.beginCapture()
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "stale", callbackGeneration: 1)
        )
        XCTAssertNil(recorder.recordsSnapshot().last?.endpointGeneration)
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))

        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 2))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "current", callbackGeneration: 2)
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.reason, "current")
        XCTAssertEqual(target.callbackGeneration, 2)
    }

    func testContextRecreationWithinServiceGenerationIsolatesLateEnumeration() throws {
        let registry = AXCallbackGenerationRegistry()
        let serviceGeneration = registry.currentGeneration
        let firstCallback = try XCTUnwrap(
            registry.reserveCallbackGeneration(serviceGeneration: serviceGeneration)
        )
        let secondCallback = try XCTUnwrap(
            registry.reserveCallbackGeneration(serviceGeneration: serviceGeneration)
        )
        let recorder = WindowAdmissionTrace(capacity: 32)
        let pid: pid_t = 8_126
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: firstCallback))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "old", callbackGeneration: firstCallback)
        )
        recorder.record(.init(action: .endpointDestroyed, pid: pid, callbackGeneration: firstCallback))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: secondCallback))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "current", callbackGeneration: secondCallback)
        )
        recorder.record(.init(action: .enumerationCompleted, pid: pid, callbackGeneration: firstCallback))

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.reason, "current")
        XCTAssertEqual(target.endpointGeneration, 2)
        XCTAssertEqual(target.callbackGeneration, secondCallback)
        XCTAssertNil(recorder.recordsSnapshot().last?.endpointGeneration)
    }

    func testLateCallbackCannotRetireCurrentWindowTarget() throws {
        let recorder = WindowAdmissionTrace(capacity: 32)
        let pid: pid_t = 8_131
        let windowId = 8_132
        let ref = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId)
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 1))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 2))
        recorder.record(
            .init(
                action: .admissionPending,
                pid: pid,
                windowId: windowId,
                callbackGeneration: 2,
                axRef: ref
            )
        )
        recorder.record(
            .init(
                action: .admissionDisappeared,
                pid: pid,
                windowId: windowId,
                callbackGeneration: 1,
                axRef: ref
            )
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.windowId, windowId)
        XCTAssertEqual(target.callbackGeneration, 2)
        XCTAssertNil(recorder.recordsSnapshot().last?.endpointGeneration)
    }

    func testLatePreviousOwnerCannotRetireReusedWindowTarget() throws {
        let recorder = WindowAdmissionTrace(capacity: 32)
        let oldPID: pid_t = 8_141
        let currentPID: pid_t = 8_142
        let windowId = 8_143
        let oldRef = AXWindowRef(element: AXUIElementCreateApplication(oldPID), windowId: windowId)
        let currentRef = AXWindowRef(element: AXUIElementCreateApplication(currentPID), windowId: windowId)
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: oldPID))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(.init(action: .admissionPending, pid: oldPID, windowId: windowId, axRef: oldRef))
        recorder.record(.init(action: .processTerminated, pid: oldPID))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(.init(action: .processLaunched, pid: currentPID))
        recorder.record(
            .init(action: .admissionPending, pid: currentPID, windowId: windowId, axRef: currentRef)
        )

        let currentGeneration = recorder.recordsSnapshot().last?.windowGeneration
        recorder.record(
            .init(action: .admissionDisappeared, pid: oldPID, windowId: windowId, axRef: oldRef)
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.pid, currentPID)
        XCTAssertEqual(target.windowId, windowId)
        XCTAssertEqual(target.windowGeneration, currentGeneration)
        XCTAssertEqual(recorder.recordsSnapshot().last?.windowGeneration, currentGeneration)
    }

    func testFullRescanAliasesDoNotAdvanceWindowGeneration() {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let firstPID: pid_t = 8_146
        let secondPID: pid_t = 8_147
        let windowId = 8_148
        let firstRef = AXWindowRef(element: AXUIElementCreateApplication(firstPID), windowId: windowId)
        let secondRef = AXWindowRef(element: AXUIElementCreateApplication(secondPID), windowId: windowId)
        recorder.beginCapture()
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .fullRescanCandidate, pid: firstPID, windowId: windowId, axRef: firstRef)
        )
        recorder.record(
            .init(
                action: .fullRescanRejected,
                pid: firstPID,
                windowId: windowId,
                competingPid: secondPID,
                axRef: firstRef
            )
        )
        recorder.record(
            .init(action: .fullRescanSelected, pid: secondPID, windowId: windowId, axRef: secondRef)
        )

        XCTAssertEqual(
            recorder.recordsSnapshot().compactMap(\.windowGeneration),
            [1, 1, 1, 1]
        )
    }

    func testSelectedFullRescanOwnerRejectsLatePreviousOwnerDisappearance() throws {
        let recorder = WindowAdmissionTrace(capacity: 24)
        let oldPID: pid_t = 8_149
        let currentPID: pid_t = 8_150
        let windowId = 8_151
        let oldRef = AXWindowRef(element: AXUIElementCreateApplication(oldPID), windowId: windowId)
        let currentRef = AXWindowRef(element: AXUIElementCreateApplication(currentPID), windowId: windowId)
        recorder.beginCapture()
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(.init(action: .admissionTracked, pid: oldPID, windowId: windowId, axRef: oldRef))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .fullRescanSelected, pid: currentPID, windowId: windowId, axRef: currentRef)
        )
        recorder.record(
            .init(action: .fullRescanRejected, pid: currentPID, windowId: windowId, axRef: currentRef)
        )
        recorder.record(
            .init(action: .admissionDisappeared, pid: oldPID, windowId: windowId, axRef: oldRef)
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.pid, currentPID)
        XCTAssertEqual(target.windowId, windowId)
        XCTAssertEqual(target.windowGeneration, 2)
    }

    func testDestroyedEndpointRejectsLateSameCallbackEvents() {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_151
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 7))
        recorder.record(.init(action: .enumerationFailed, pid: pid, callbackGeneration: 7))
        recorder.record(.init(action: .endpointDestroyed, pid: pid, callbackGeneration: 7))
        recorder.record(.init(action: .enumerationCompleted, pid: pid, callbackGeneration: 7))

        XCTAssertNil(recorder.recordsSnapshot().last?.endpointGeneration)
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testGenerationlessResolutionCannotClearGenerationBoundFailure() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_161
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 8))
        recorder.record(
            .init(action: .enumerationFailed, pid: pid, reason: "current", callbackGeneration: 8)
        )
        recorder.record(.init(action: .enumerationCompleted, pid: pid))

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.reason, "current")
        XCTAssertEqual(target.callbackGeneration, 8)
    }

    func testFinalizationTargetPrioritizesAnomalyAndHonorsExclusion() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pendingRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_202),
            windowId: 8_212
        )
        let refusalRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_203),
            windowId: 8_213
        )
        recorder.beginCapture()
        recorder.record(
            .init(action: .frontmostObserved, pid: 8_201, bundleId: "example.frontmost")
        )
        recorder.record(
            .init(
                action: .admissionPending,
                pid: 8_202,
                windowId: 8_212,
                reason: "facts_deferred",
                axRef: pendingRef
            )
        )
        recorder.record(
            .init(
                action: .terminalFrameRefusal,
                pid: 8_203,
                windowId: 8_213,
                reason: "sizeWriteFailed",
                axRef: refusalRef
            )
        )
        recorder.endCapture()

        let terminal = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(terminal.pid, 8_203)
        XCTAssertEqual(terminal.windowId, 8_213)
        XCTAssertEqual(terminal.reason, "sizeWriteFailed")

        let pending = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 8_203))
        XCTAssertEqual(pending.pid, 8_202)
        XCTAssertEqual(pending.windowId, 8_212)
    }

    func testResolvedEnumerationFailureFallsBackToLastManagedFocus() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let focusedRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_221),
            windowId: 8_231
        )
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .managedFocusObserved,
                pid: 8_221,
                windowId: 8_231,
                axRef: focusedRef
            )
        )
        recorder.record(
            .init(action: .enumerationFailed, pid: 8_222, reason: "timeout")
        )
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.pid, 8_222)

        recorder.record(
            .init(action: .enumerationCompleted, pid: 8_222, count: 1)
        )
        recorder.record(
            .init(action: .admissionTracked, pid: 8_223, windowId: 8_233)
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.pid, 8_221)
        XCTAssertEqual(target.windowId, 8_231)
    }

    func testSuccessfulEmptyEnumerationClearsCurrentFailure() {
        let recorder = WindowAdmissionTrace(capacity: 8)
        let pid: pid_t = 8_234
        recorder.beginCapture()
        recorder.record(.init(action: .enumerationFailed, pid: pid, reason: "timeout"))

        recorder.record(.init(action: .enumerationCompleted, pid: pid, count: 0))

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testEmptyEnumerationTargetRequiresPositiveCurrentCompletion() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_235
        recorder.beginCapture()
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 1))
        recorder.record(
            .init(action: .enumerationEmpty, pid: pid, reason: "old_empty", callbackGeneration: 1)
        )
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 2))
        recorder.record(
            .init(action: .enumerationEmpty, pid: pid, reason: "current_empty", callbackGeneration: 2)
        )

        recorder.record(
            .init(action: .enumerationCompleted, pid: pid, count: 1, callbackGeneration: 1)
        )
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.reason, "current_empty")

        recorder.record(
            .init(action: .enumerationCompleted, pid: pid, count: 0, callbackGeneration: 2)
        )
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.action, .enumerationEmpty)

        recorder.record(
            .init(action: .enumerationCompleted, pid: pid, count: 1, callbackGeneration: 2)
        )
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testProcessTerminationClearsEveryFinalizationTargetForPID() {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_241
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .frontmostObserved, pid: pid))
        recorder.record(.init(action: .managedFocusObserved, pid: pid))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_242))
        recorder.record(.init(action: .terminalFrameRefusal, pid: pid, windowId: 8_242))

        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.pid, pid)

        recorder.record(.init(action: .processTerminated, pid: pid))

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testLateDisappearanceCannotReactivateTerminatedProcess() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_251
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_252))
        recorder.record(.init(action: .processTerminated, pid: pid))
        recorder.record(
            .init(
                action: .admissionDisappeared,
                pid: pid,
                windowId: 8_252,
                reason: "process_terminated"
            )
        )

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(recorder.recordsSnapshot().last?.processGeneration, 1)

        recorder.record(.init(action: .processLaunched, pid: pid))
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_253))

        let relaunched = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(relaunched.windowId, 8_253)
        XCTAssertEqual(relaunched.processGeneration, 2)

        recorder.record(
            .init(
                action: .admissionDisappeared,
                pid: pid,
                windowId: 8_252,
                reason: "process_terminated"
            )
        )

        XCTAssertEqual(recorder.recordsSnapshot().last?.windowId, 8_252)
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.windowId, 8_253)
    }

    func testAuxiliaryPruningPreservesTerminatedProcessTombstone() {
        let recorder = WindowAdmissionTrace(capacity: 1)
        let pid: pid_t = 8_261
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .processTerminated, pid: pid))

        for windowId in 8_300 ..< 8_600 {
            recorder.record(.init(action: .cgsCreated, windowId: windowId))
        }
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_262))

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    @MainActor
    func testFullRescanPreferenceReportsDecisiveReason() {
        let windowId = 8_301
        let preservedPID: pid_t = 8_302
        let ownerPID: pid_t = 8_303
        let preserved = fullRescanCandidate(pid: preservedPID, windowId: windowId)
        let owner = fullRescanCandidate(pid: ownerPID, windowId: windowId)

        let preference = AXManager.fullRescanCandidatePreference(
            preserved,
            over: owner,
            activationPolicyByPID: [preservedPID: .regular, ownerPID: .regular],
            ownerPID: ownerPID,
            existingPID: preservedPID
        )

        XCTAssertTrue(preference.prefersCandidate)
        XCTAssertEqual(preference.reason, .preservedLogicalPID)
    }

    func testDumpIsStructuredJSONLines() throws {
        let recorder = WindowAdmissionTrace(capacity: 4)
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .admissionPending,
                pid: 8_401,
                windowId: 8_402,
                reason: "window_info_missing",
                attempt: 1,
                retryGeneration: 7
            )
        )

        let line = try XCTUnwrap(recorder.dump().split(separator: "\n").first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["action"] as? String, "admission_pending")
        XCTAssertEqual(object["windowId"] as? Int, 8_402)
        XCTAssertEqual(object["retryGeneration"] as? Int, 7)
    }

    func testRepeatedClassificationObservationsAreRetained() {
        let recorder = WindowAdmissionTrace(capacity: 4)
        let observation = classificationObservation(rulesRevision: 7)
        recorder.beginCapture()

        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation,
                classificationRulesSnapshot: .init(revision: observation.rulesRevision, rules: [])
            )
        )
        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation,
                classificationRulesSnapshot: .init(revision: observation.rulesRevision, rules: [])
            )
        )

        XCTAssertEqual(recorder.recordsSnapshot().count, 2)
        XCTAssertEqual(recorder.recordsSnapshot().first?.observation, observation)
        let snapshots = recorder.dump().split(separator: "\n").filter { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return false }
            return object["kind"] as? String == "rules_snapshot"
        }
        XCTAssertEqual(snapshots.count, 1)
    }

    func testClassificationDumpCarriesDecisionOnly() throws {
        let recorder = WindowAdmissionTrace(capacity: 4)
        let observation = classificationObservation(rulesRevision: 11)
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation,
                classificationRulesSnapshot: .init(revision: observation.rulesRevision, rules: [])
            )
        )

        let line = try XCTUnwrap(
            recorder.dump().split(separator: "\n").first { $0.contains("classification_observed") }
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let dumped = try XCTUnwrap(object["observation"] as? [String: Any])

        XCTAssertNotNil(dumped["observedDecision"])
        XCTAssertNil(dumped["observedPolicy"])
    }

    func testRulesSnapshotIsIndividuallyByteBounded() throws {
        let recorder = WindowAdmissionTrace(capacity: 4)
        let rules = largeRules()
        let observation = classificationObservation(rulesRevision: 9)
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation,
                classificationRulesSnapshot: .init(revision: observation.rulesRevision, rules: rules)
            )
        )

        let line = try XCTUnwrap(recorder.dump().split(separator: "\n").first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["kind"] as? String, "rules_snapshot")
        XCTAssertEqual(object["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(line.utf8.count, RuntimeTraceLimits.rulesSnapshotBytes)
    }

    func testRulesSnapshotsHaveCumulativeByteBudget() throws {
        let recorder = WindowAdmissionTrace(capacity: 8)
        let rules = largeRules()
        recorder.beginCapture()
        for revision in 1 ... 3 {
            let observation = classificationObservation(rulesRevision: UInt64(revision))
            recorder.record(
                .init(
                    action: .classificationObserved,
                    pid: observation.tokenPid,
                    windowId: observation.tokenWindowId,
                    observation: observation,
                    classificationRulesSnapshot: .init(revision: observation.rulesRevision, rules: rules)
                )
            )
        }

        let lines = recorder.dump().split(separator: "\n")
        let objects = try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let rulesBytes = zip(lines, objects)
            .filter {
                let kind = $0.1["kind"] as? String
                return kind == "rules_snapshot" || kind == "rules_snapshots_truncated"
            }
            .reduce(0) { $0 + $1.0.utf8.count + 1 }

        XCTAssertLessThanOrEqual(rulesBytes, RuntimeTraceLimits.cumulativeRulesSnapshotBytes)
        XCTAssertTrue(objects.contains { $0["kind"] as? String == "rules_snapshots_truncated" })
    }

    func testSmallReferencedRulesSnapshotsAllFitWithoutTruncation() throws {
        let recorder = WindowAdmissionTrace(capacity: 8)
        recorder.beginCapture()
        for revision in 1 ... 4 {
            let observation = classificationObservation(rulesRevision: UInt64(revision))
            recorder.record(
                .init(
                    action: .classificationObserved,
                    pid: observation.tokenPid,
                    windowId: observation.tokenWindowId,
                    observation: observation,
                    classificationRulesSnapshot: .init(
                        revision: observation.rulesRevision,
                        rules: [AppRule(bundleId: "example.\(revision)", layout: .float)]
                    )
                )
            )
        }

        let objects = try recorder.dump().split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let revisions = objects.compactMap { object -> Int? in
            guard object["kind"] as? String == "rules_snapshot" else { return nil }
            return object["revision"] as? Int
        }
        XCTAssertEqual(revisions, [1, 2, 3, 4])
        XCTAssertFalse(objects.contains { $0["kind"] as? String == "rules_snapshots_truncated" })
    }

    func testEvictedRuleRevisionCannotDisplaceRetainedRevision() throws {
        let recorder = WindowAdmissionTrace(capacity: 1)
        recorder.beginCapture()
        for revision in 1 ... 2 {
            let observation = classificationObservation(rulesRevision: UInt64(revision))
            recorder.record(
                .init(
                    action: .classificationObserved,
                    pid: observation.tokenPid,
                    windowId: observation.tokenWindowId,
                    observation: observation,
                    classificationRulesSnapshot: .init(
                        revision: observation.rulesRevision,
                        rules: largeRules()
                    )
                )
            )
        }

        let objects = try recorder.dump().split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let revisions = objects.compactMap { object -> Int? in
            guard object["kind"] as? String == "rules_snapshot" else { return nil }
            return object["revision"] as? Int
        }
        XCTAssertEqual(revisions, [2])
        XCTAssertFalse(objects.contains { $0["revision"] as? Int == 1 })
    }

    private func classificationObservation(rulesRevision: UInt64) -> WindowClassificationObservation {
        WindowClassificationObservation(
            tokenPid: 8_501,
            tokenWindowId: 8_502,
            appName: "Example",
            bundleId: "example.app",
            workspaceName: nil,
            rulesRevision: rulesRevision,
            input: WindowClassificationInput(
                appName: "Example",
                ax: AXWindowFactsDTO(
                    from: AXWindowFacts(
                        role: kAXWindowRole as String,
                        subrole: kAXStandardWindowSubrole as String,
                        title: "Window",
                        hasCloseButton: true,
                        hasFullscreenButton: true,
                        fullscreenButtonEnabled: true,
                        hasZoomButton: true,
                        hasMinimizeButton: true,
                        appPolicy: .regular,
                        bundleId: "example.app",
                        attributeFetchSucceeded: true
                    )
                ),
                sizeConstraints: nil,
                windowServer: nil,
                appFullscreen: false,
                manualOverride: nil
            ),
            observedDecision: WindowClassificationDecisionDTO(
                from: WindowDecision(
                    disposition: .managed,
                    source: .heuristic,
                    layoutDecisionKind: .fallbackLayout,
                    workspaceName: nil,
                    ruleEffects: .none,
                    admissionHints: .none,
                    heuristicReasons: [],
                    deferredReason: nil
                )
            )
        )
    }

    private func largeRules() -> [AppRule] {
        let value = String(repeating: "🪟", count: 2_000)
        return (0 ..< 80).map { index in
            AppRule(
                bundleId: "example.\(index).\(value)",
                appNameSubstring: value,
                titleRegex: value,
                axRole: value,
                axSubrole: value,
                assignToWorkspace: value
            )
        }
    }

    private func fullRescanCandidate(pid: pid_t, windowId: Int) -> FullRescanWindowCandidate {
        FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .persistent
        )
    }
}
