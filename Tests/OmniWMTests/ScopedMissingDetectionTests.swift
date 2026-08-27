// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ScopedMissingDetectionTests: XCTestCase {
    func testScopedDetectionDoesNotIncrementIneligibleCounters() throws {
        let (controller, workspaceId) = try makeFixture()
        let scopedToken = WindowToken(pid: 468_100, windowId: 468_101)
        let unrelatedToken = WindowToken(pid: 468_102, windowId: 468_103)
        track([scopedToken, unrelatedToken], in: workspaceId, controller: controller)

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [scopedToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [unrelatedToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [scopedToken],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [scopedToken]
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [unrelatedToken],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [unrelatedToken]
        )
    }

    func testSeenIneligibleTokenClearsItsMissCount() throws {
        let (controller, workspaceId) = try makeFixture()
        let observedToken = WindowToken(pid: 468_112, windowId: 468_113)
        let scopedToken = WindowToken(pid: 468_114, windowId: 468_115)
        track([observedToken, scopedToken], in: workspaceId, controller: controller)

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [observedToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [observedToken, scopedToken],
                eligibleKeys: [scopedToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [observedToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [observedToken],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [observedToken]
        )
    }

    func testTwoEligibleMissesConfirmRemoval() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_104, windowId: 468_105)
        track([token], in: workspaceId, controller: controller)

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    func testTargetedRescanPreservesOnlyHiddenWindowsWithMatchingWindowServerOwner() throws {
        let (controller, workspaceId) = try makeFixture()
        let workspaceInactiveToken = WindowToken(pid: 468_140, windowId: 468_141)
        let layoutTransientToken = WindowToken(pid: 468_142, windowId: 468_143)
        let wrongOwnerToken = WindowToken(pid: 468_144, windowId: 468_145)
        let visibleToken = WindowToken(pid: 468_146, windowId: 468_147)
        let tokens = [
            workspaceInactiveToken,
            layoutTransientToken,
            wrongOwnerToken,
            visibleToken
        ]
        track(tokens, in: workspaceId, controller: controller)
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: workspaceInactiveToken
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.right)
            ),
            for: layoutTransientToken
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .workspaceInactive
            ),
            for: wrongOwnerToken
        )
        let eligibleKeys = Set(tokens)
        let windowServerInfoByWindowId = Dictionary(
            uniqueKeysWithValues: tokens.map { token in
                (
                    token.windowId,
                    WindowServerInfo(
                        id: UInt32(token.windowId),
                        pid: token == wrongOwnerToken ? token.pid + 1 : token.pid,
                        level: 0,
                        frame: .zero
                    )
                )
            }
        )
        let preservedKeys: Set<WindowToken> = [workspaceInactiveToken, layoutTransientToken]
        let retiredKeys: Set<WindowToken> = [wrongOwnerToken, visibleToken]

        for pass in 0 ..< 2 {
            var seenKeys: Set<WindowToken> = []
            controller.layoutRefreshController.preserveHiddenWindowsDuringTargetedFullRescan(
                controller.workspaceManager.allEntries(),
                eligibleKeys: eligibleKeys,
                windowServerInfoByWindowId: windowServerInfoByWindowId,
                seenKeys: &seenKeys
            )

            XCTAssertEqual(seenKeys, preservedKeys)
            let missing = controller.layoutRefreshController.confirmedMissingEntries(
                keys: seenKeys,
                eligibleKeys: eligibleKeys,
                requiredConsecutiveMisses: 2
            )
            XCTAssertEqual(Set(missing.map(\.token)), pass == 0 ? [] : retiredKeys)
        }
    }

    func testKnownInactiveSpaceIsPreservedWhileUnknownSpaceRemainsEligible() throws {
        let (controller, workspaceId) = try makeFixture()
        let inactiveToken = WindowToken(pid: 468_106, windowId: 468_107)
        let unknownToken = WindowToken(pid: 468_108, windowId: 468_109)
        track([inactiveToken, unknownToken], in: workspaceId, controller: controller)
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: "primary",
                        spaceIds: [1, 2],
                        currentSpaceId: 1
                    )
                ],
                activeSpaceId: 1,
                fullscreenSpaceIds: [],
                windowSpace: [inactiveToken.windowId: 2]
            )
        )
        let eligibleKeys: Set<WindowToken> = [inactiveToken, unknownToken]

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: eligibleKeys,
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: eligibleKeys,
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [unknownToken]
        )
    }

    func testExactDepartedSpaceNativeFullscreenTokenUsesTwoMissConfirmation() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_124, windowId: 468_125)
        track([token], in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(token))

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                nativeFullscreenRetirementKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                nativeFullscreenRetirementKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    func testExactNativeFullscreenRetirementKeysExcludeUnscopedAndKnownSpaceWindows() throws {
        let (controller, workspaceId) = try makeFixture()
        let departedToken = WindowToken(pid: 468_126, windowId: 468_127)
        let unscopedToken = WindowToken(pid: departedToken.pid, windowId: 468_128)
        let knownSpaceToken = WindowToken(pid: departedToken.pid, windowId: 468_129)
        let standardToken = WindowToken(pid: departedToken.pid, windowId: 468_130)
        track(
            [departedToken, unscopedToken, knownSpaceToken, standardToken],
            in: workspaceId,
            controller: controller
        )
        for token in [departedToken, unscopedToken, knownSpaceToken] {
            XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(token))
        }
        let currentSpaceId: UInt64 = 468_131
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: "primary",
                        spaceIds: [currentSpaceId],
                        currentSpaceId: currentSpaceId
                    )
                ],
                activeSpaceId: currentSpaceId,
                fullscreenSpaceIds: [],
                windowSpace: [knownSpaceToken.windowId: currentSpaceId]
            )
        )

        let keys = controller.layoutRefreshController.exactNativeFullscreenRetirementKeys(
            scope: .targeted(
                appPIDs: [],
                nativeSpaceIds: [],
                nativeSpaceWindowIdsByPID: [
                    departedToken.pid: [
                        departedToken.windowId,
                        knownSpaceToken.windowId,
                        standardToken.windowId
                    ]
                ]
            ),
            trackedEntries: controller.workspaceManager.allEntries()
        )

        XCTAssertEqual(keys, [departedToken])
    }

    func testStructuralReplacementRestorePreservesAppFullscreenState() throws {
        let (controller, workspaceId) = try makeFixture()
        let oldToken = WindowToken(pid: 468_132, windowId: 468_133)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 468_134)
        track([oldToken], in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(oldToken))

        controller.layoutRefreshController.restoreNativeFullscreenAfterStructuralReplacement(
            from: oldToken,
            to: newToken,
            appFullscreen: true
        )

        XCTAssertNotNil(controller.workspaceManager.nativeFullscreenRecord(for: oldToken))
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: oldToken), .nativeFullscreen)
        XCTAssertFalse(
            controller.layoutRefreshController
                .consumeNativeFullscreenRestoredFrameApply(for: oldToken)
        )
    }

    func testSeenEligibleTokenClearsItsMissCount() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_110, windowId: 468_111)
        track([token], in: workspaceId, controller: controller)

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [token],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    func testLiveReadmissionClearsPriorMissObservation() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_112, windowId: 468_113)
        track([token], in: workspaceId, controller: controller)
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle[handle],
            1
        )

        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId
        )

        XCTAssertNil(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle[handle]
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    func testRekeyPreservesMissObservationThroughStableHandle() throws {
        let (controller, workspaceId) = try makeFixture()
        let oldToken = WindowToken(pid: 468_116, windowId: 468_117)
        let newToken = WindowToken(pid: 468_118, windowId: 468_119)
        track([oldToken], in: workspaceId, controller: controller)
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: oldToken))

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [oldToken],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )

        let entry = try XCTUnwrap(
            controller.workspaceManager.rekeyWindow(
                from: oldToken,
                to: newToken,
                newAXRef: WindowAdmissionTestSupport.axRef(for: newToken)
            )
        )

        XCTAssertEqual(entry.token, newToken)
        XCTAssertTrue(controller.workspaceManager.handle(for: newToken) === handle)
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [newToken],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [newToken]
        )
    }

    func testSameTokenReincarnationStartsWithFreshMissObservation() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_120, windowId: 468_121)
        track([token], in: workspaceId, controller: controller)
        let oldHandle = try XCTUnwrap(controller.workspaceManager.handle(for: token))

        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertNotNil(
            controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        )
        track([token], in: workspaceId, controller: controller)
        let newHandle = try XCTUnwrap(controller.workspaceManager.handle(for: token))

        XCTAssertFalse(oldHandle === newHandle)
        XCTAssertFalse(controller.workspaceManager.handle(for: oldHandle.id) === oldHandle)
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertNil(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle[oldHandle]
        )
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle[newHandle],
            1
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    func testMissingDetectionObservationsDoNotCommitOrInvalidateRuntimeState() throws {
        let (controller, workspaceId) = try makeFixture()
        let token = WindowToken(pid: 468_122, windowId: 468_123)
        track([token], in: workspaceId, controller: controller)
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))

        let observationSeq = controller.workspaceManager.worldSeq
        let observationTrace = controller.workspaceManager.reconcileTraceDump()
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(controller.workspaceManager.worldSeq, observationSeq)
        XCTAssertEqual(controller.workspaceManager.reconcileTraceDump(), observationTrace)
        XCTAssertEqual(controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle.count, 1)
        XCTAssertEqual(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle[handle],
            1
        )
        XCTAssertTrue(
            controller.workspaceManager.isSeqEpochCurrent(
                observationSeq,
                domains: .layoutCommit
            )
        )

        let resetSeq = controller.workspaceManager.worldSeq
        let resetTrace = controller.workspaceManager.reconcileTraceDump()
        controller.layoutRefreshController.resetMissingDetectionCounts()
        XCTAssertEqual(controller.workspaceManager.worldSeq, resetSeq)
        XCTAssertEqual(controller.workspaceManager.reconcileTraceDump(), resetTrace)
        XCTAssertTrue(
            controller.layoutRefreshController.layoutState.consecutiveMissCountByHandle.isEmpty
        )
        XCTAssertTrue(
            controller.workspaceManager.isSeqEpochCurrent(
                resetSeq,
                domains: .layoutCommit
            )
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                eligibleKeys: [token],
                requiredConsecutiveMisses: 2
            ).map(\.token),
            [token]
        )
    }

    private func makeFixture() throws -> (WMController, WorkspaceDescriptor.ID) {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        return (controller, workspaceId)
    }

    private func track(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) {
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
    }
}
