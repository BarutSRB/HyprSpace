// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class NativeSpaceInventoryStabilityTests: XCTestCase {
    @MainActor
    func testTopologyInventoryTaskTerminatesAfterOneGlobalFallback() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.serviceLifecycleManager
        let refreshController = controller.layoutRefreshController
        defer {
            refreshController.resetState()
            controller.isLockScreenActive = false
        }
        manager.topologyInventorySampleProvider = { nil }
        manager.topologyInventorySleeper = { _ in await Task.yield() }
        manager.beginPerformanceCapture()
        controller.isLockScreenActive = true

        manager.handleActiveSpaceDidChange()
        for _ in 0 ..< 100 {
            if manager.performanceSnapshot()?.topologyGlobalFallbacks == 1 {
                break
            }
            await Task.yield()
        }

        let terminalSnapshot = try XCTUnwrap(manager.performanceSnapshot())
        XCTAssertEqual(
            terminalSnapshot.topologySamples,
            UInt64(NativeSpaceInventoryStabilityGate.globalFallbackObservationCount)
        )
        XCTAssertEqual(terminalSnapshot.topologyGlobalFallbacks, 1)
        XCTAssertEqual(terminalSnapshot.globalFallbackTerminations, 1)
        XCTAssertEqual(terminalSnapshot.lastTopologyTerminalReason, .globalFallback)
        XCTAssertFalse(refreshController.layoutState.inventoryStabilityBarrierActive)

        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(manager.performanceSnapshot()?.topologySamples, terminalSnapshot.topologySamples)
        _ = manager.endPerformanceCapture()
    }

    @MainActor
    func testOscillatingTopologyInventoryTaskTerminatesAfterOneGlobalFallback() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.serviceLifecycleManager
        let refreshController = controller.layoutRefreshController
        let first = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 1)))
        let second = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 2)))
        var returnsFirst = true
        defer {
            refreshController.resetState()
            controller.isLockScreenActive = false
        }
        manager.topologyInventorySampleProvider = {
            defer { returnsFirst.toggle() }
            return returnsFirst ? first : second
        }
        manager.topologyInventorySleeper = { _ in await Task.yield() }
        manager.beginPerformanceCapture()
        controller.isLockScreenActive = true

        manager.handleActiveSpaceDidChange()
        for _ in 0 ..< 100 {
            if manager.performanceSnapshot()?.topologyGlobalFallbacks == 1 {
                break
            }
            await Task.yield()
        }

        let terminalSnapshot = try XCTUnwrap(manager.performanceSnapshot())
        XCTAssertEqual(
            terminalSnapshot.topologySamples,
            UInt64(NativeSpaceInventoryStabilityGate.globalFallbackObservationCount)
        )
        XCTAssertEqual(terminalSnapshot.topologyGlobalFallbacks, 1)
        XCTAssertEqual(terminalSnapshot.globalFallbackTerminations, 1)
        XCTAssertEqual(terminalSnapshot.lastTopologyTerminalReason, .globalFallback)
        XCTAssertFalse(refreshController.layoutState.inventoryStabilityBarrierActive)

        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(manager.performanceSnapshot()?.topologySamples, terminalSnapshot.topologySamples)
        _ = manager.endPerformanceCapture()
    }

    @MainActor
    func testUnlockRefreshWaitsForFirstUsableTopologySample() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.serviceLifecycleManager
        let refreshController = controller.layoutRefreshController
        let usableSample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology()))
        let firstWorkspaceId = WorkspaceDescriptor.ID()
        let secondWorkspaceId = WorkspaceDescriptor.ID()
        let probe = NativeSpaceInventoryTestProbe()
        defer {
            _ = manager.endPerformanceCapture()
            _ = refreshController.endPerformanceCapture()
            refreshController.resetState()
            controller.isLockScreenActive = false
        }
        manager.topologyInventorySampleProvider = { probe.sample }
        manager.topologyInventorySleeper = { _ in
            await withCheckedContinuation { continuation in
                probe.sleeper = continuation
            }
        }
        manager.beginPerformanceCapture()
        refreshController.beginPerformanceCapture()
        controller.isLockScreenActive = true
        refreshController.requestImmediateRelayout(
            reason: .layoutCommand,
            affectedWorkspaceIds: [firstWorkspaceId]
        )
        refreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [secondWorkspaceId]
        )

        controller.isLockScreenActive = false
        manager.handleUnlockDetected()
        for _ in 0 ..< 100 where probe.sleeper == nil {
            await Task.yield()
        }

        XCTAssertNotNil(probe.sleeper)
        XCTAssertTrue(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertTrue(refreshController.layoutState.isAwaitingPostUnlockTopologySample)
        XCTAssertEqual(refreshController.performanceSnapshot()?.refreshesStarted, 0)

        probe.sample = usableSample
        let firstSleep = probe.sleeper
        probe.sleeper = nil
        firstSleep?.resume()
        for _ in 0 ..< 100 {
            if refreshController.performanceSnapshot()?.refreshesStarted == 1,
               probe.sleeper != nil
            {
                break
            }
            await Task.yield()
        }
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        let snapshot = try XCTUnwrap(refreshController.performanceSnapshot())
        XCTAssertEqual(snapshot.refreshesStarted, 1)
        XCTAssertEqual(snapshot.refreshesCompleted, 1)
        XCTAssertFalse(refreshController.layoutState.isRefreshSuspendedForLockScreen)
        XCTAssertFalse(refreshController.layoutState.isAwaitingPostUnlockTopologySample)

        controller.isLockScreenActive = true
        let secondSleep = probe.sleeper
        probe.sleeper = nil
        secondSleep?.resume()
        for _ in 0 ..< 100 {
            if manager.performanceSnapshot()?.authoritativeTerminations == 1 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(manager.performanceSnapshot()?.authoritativeTerminations, 1)
    }

    func testTwoConsecutiveMatchingUsableSamplesReleaseCurrentAndActiveSpaces() throws {
        let topology = makeTopology(
            displays: [
                .init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1),
                .init(displayIdentifier: "secondary", spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 1
        )
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: topology))
        var gate = NativeSpaceInventoryStabilityGate()

        XCTAssertEqual(
            gate.observe(sample),
            .init(topologyToApply: sample)
        )
        XCTAssertEqual(
            gate.observe(sample),
            .init(authoritativeTopologyToApply: sample)
        )
    }

    func testIncompleteSampleBreaksConsecutiveAgreement() throws {
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology()))
        var gate = NativeSpaceInventoryStabilityGate()

        XCTAssertEqual(gate.observe(sample), .init(topologyToApply: sample))
        XCTAssertEqual(gate.observe(nil), .init())
        XCTAssertEqual(gate.observe(sample), .init(topologyToApply: sample))
        XCTAssertEqual(gate.observe(sample), .init(authoritativeTopologyToApply: sample))
    }

    func testTopologyChangeRestartsAgreement() throws {
        let first = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 1)))
        let second = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 2)))
        var gate = NativeSpaceInventoryStabilityGate()

        XCTAssertEqual(gate.observe(first), .init(topologyToApply: first))
        XCTAssertEqual(gate.observe(second), .init(topologyToApply: second))
        XCTAssertEqual(gate.observe(second), .init(authoritativeTopologyToApply: second))
    }

    func testTenthUnavailableObservationRequestsOneFallbackAndLateStabilityStillCompletes() throws {
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology()))
        var gate = NativeSpaceInventoryStabilityGate()

        for _ in 1 ..< NativeSpaceInventoryStabilityGate.globalFallbackObservationCount {
            XCTAssertFalse(gate.observe(nil).requestsGlobalFallback)
            XCTAssertFalse(gate.usesRetryInterval)
        }

        XCTAssertTrue(gate.observe(nil).requestsGlobalFallback)
        XCTAssertTrue(gate.usesRetryInterval)
        XCTAssertFalse(gate.observe(nil).requestsGlobalFallback)
        XCTAssertEqual(gate.observe(sample), .init(topologyToApply: sample))
        XCTAssertEqual(
            gate.observe(sample),
            .init(authoritativeTopologyToApply: sample)
        )
    }

    func testOscillatingSamplesRequestOnlyOneFallback() throws {
        let first = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 1)))
        let second = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 2)))
        var gate = NativeSpaceInventoryStabilityGate()
        var fallbackCount = 0

        for index in 0 ..< (NativeSpaceInventoryStabilityGate.globalFallbackObservationCount + 5) {
            let observation = gate.observe(index.isMultiple(of: 2) ? first : second)
            fallbackCount += observation.requestsGlobalFallback ? 1 : 0
        }

        XCTAssertEqual(fallbackCount, 1)
    }

    @MainActor
    func testGlobalFallbackMergesWithHeldTargetBeforeRelease() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.beginInventoryStabilityBarrier()
        refreshController.requestFullRescan(
            reason: .activeSpaceChanged,
            scope: .targeted(appPIDs: [], nativeSpaceIds: [91])
        )
        refreshController.requestFullRescan(
            reason: .staleFullRescan,
            scope: .all
        )
        refreshController.releaseInventoryStabilityHold()

        let active = try XCTUnwrap(refreshController.layoutState.activeRefresh)
        XCTAssertEqual(active.kind, .fullRescan)
        XCTAssertEqual(active.rescanScope, .all)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        XCTAssertNil(refreshController.layoutState.inventoryStabilityHeldFullRescan)
        XCTAssertTrue(refreshController.layoutState.inventoryStabilityBarrierActive)
    }

    func testEquivalentDisplayAndSpaceOrderingCountsAsAgreement() throws {
        let first = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            displays: [
                .init(displayIdentifier: "secondary", spaceIds: [4, 3], currentSpaceId: 3),
                .init(displayIdentifier: "primary", spaceIds: [2, 1], currentSpaceId: 1)
            ],
            activeSpaceId: 3
        )))
        let second = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            displays: [
                .init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1),
                .init(displayIdentifier: "secondary", spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 3
        )))
        var gate = NativeSpaceInventoryStabilityGate()

        XCTAssertEqual(gate.observe(first), .init(topologyToApply: first))
        XCTAssertEqual(gate.observe(second), .init(authoritativeTopologyToApply: second))
    }

    @MainActor
    func testStableTransitionQueriesMembershipAndReconcilesOnlyWhenAuthoritative() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 468_300, windowId: 468_301)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        var previousTopology = makeTopology()
        previousTopology.windowSpace[token.windowId] = 2
        controller.workspaceManager.commitSpaceTopology(previousTopology)
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            currentSpaceId: 2,
            fullscreenSpaceIds: [2]
        )))
        var gate = NativeSpaceInventoryStabilityGate()
        var membershipQueryCount = 0

        let provisional = try XCTUnwrap(gate.observe(sample).topologyToApply)
        controller.spaceTracker.refresh(
            using: provisional,
            windowMembershipUpdate: .carryForwardKnown,
            reconcilesNativeFullscreen: false,
            spaceIdsForWindow: { _ in
                membershipQueryCount += 1
                return [1]
            }
        )
        XCTAssertEqual(membershipQueryCount, 0)
        XCTAssertEqual(controller.workspaceManager.spaceTopology.activeSpaceId, 2)
        XCTAssertEqual(controller.workspaceManager.spaceTopology.displays.first?.currentSpaceId, 2)
        XCTAssertEqual(
            controller.workspaceManager.spaceTopology.windowSpace[token.windowId],
            2
        )
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: token), .standard)

        let authoritative = try XCTUnwrap(gate.observe(sample).authoritativeTopologyToApply)
        controller.spaceTracker.refresh(
            using: authoritative,
            windowMembershipUpdate: .query(preservesKnownOnMissing: true),
            spaceIdsForWindow: { _ in
                membershipQueryCount += 1
                return [2]
            }
        )
        XCTAssertEqual(membershipQueryCount, 1)
        XCTAssertEqual(
            controller.workspaceManager.spaceTopology.windowSpace[token.windowId],
            2
        )
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: token), .nativeFullscreen)
    }

    func testIncompleteTopologiesDoNotProduceUsableSamples() {
        XCTAssertNil(NativeSpaceTopologySample(topology: SpaceTopology()))
        XCTAssertNil(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 0)))
        XCTAssertNil(NativeSpaceTopologySample(topology: makeTopology(currentSpaceId: 9)))
        XCTAssertNil(NativeSpaceTopologySample(topology: makeTopology(activeSpaceId: 9)))
    }

    func testSampleRejectsPartialOrMismatchedDisplayInventory() throws {
        let firstUUID = "11111111-1111-1111-1111-111111111111"
        let secondUUID = "22222222-2222-2222-2222-222222222222"
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            displays: [
                .init(displayIdentifier: firstUUID, spaceIds: [1, 2], currentSpaceId: 1)
            ]
        )))

        XCTAssertFalse(sample.matchesExpectedDisplays(count: 2, displayUUIDs: nil))
        XCTAssertFalse(sample.matchesExpectedDisplays(
            count: 1,
            displayUUIDs: [secondUUID]
        ))
        XCTAssertTrue(sample.matchesExpectedDisplays(
            count: 1,
            displayUUIDs: [firstUUID]
        ))
    }

    func testMainDisplayIdentifierResolvesToExpectedMainDisplayUUID() throws {
        let mainUUID = "11111111-1111-1111-1111-111111111111"
        let secondaryUUID = "22222222-2222-2222-2222-222222222222"
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            displays: [
                .init(displayIdentifier: "Main", spaceIds: [1, 2], currentSpaceId: 1),
                .init(displayIdentifier: secondaryUUID, spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 1
        )))

        XCTAssertTrue(sample.matchesExpectedDisplays(
            count: 2,
            displayUUIDs: [mainUUID, secondaryUUID],
            displayUUIDAliases: ["Main": mainUUID]
        ))
        XCTAssertFalse(sample.matchesExpectedDisplays(
            count: 2,
            displayUUIDs: [mainUUID, secondaryUUID]
        ))
    }

    func testNumericDisplayIdentifierResolvesToExpectedDisplayUUID() throws {
        let firstUUID = "11111111-1111-1111-1111-111111111111"
        let secondUUID = "22222222-2222-2222-2222-222222222222"
        let sample = try XCTUnwrap(NativeSpaceTopologySample(topology: makeTopology(
            displays: [
                .init(displayIdentifier: "1", spaceIds: [1, 2], currentSpaceId: 1),
                .init(displayIdentifier: "2", spaceIds: [3, 4], currentSpaceId: 3)
            ],
            activeSpaceId: 1
        )))

        XCTAssertTrue(sample.matchesExpectedDisplays(
            count: 2,
            displayUUIDs: [firstUUID, secondUUID],
            displayUUIDAliases: ["1": firstUUID, "2": secondUUID]
        ))
        XCTAssertFalse(sample.matchesExpectedDisplays(
            count: 2,
            displayUUIDs: [firstUUID, secondUUID],
            displayUUIDAliases: ["1": firstUUID]
        ))
    }

    func testActiveOnlyStableNoOpRequestsNeitherEventNorRescan() {
        let topology = makeTopology()
        let request = NativeSpaceInventoryRequest(
            reason: .activeSpaceChanged,
            baseline: topology
        )
        let resolution = request.resolution(for: topology)

        XCTAssertFalse(resolution.recordsActiveSpaceChange)
        XCTAssertNil(resolution.rescanReason)
    }

    func testActiveOnlyStableDeltaRequestsEventAndRescan() {
        let request = NativeSpaceInventoryRequest(
            reason: .activeSpaceChanged,
            baseline: makeTopology(currentSpaceId: 1)
        )
        let changed = makeTopology(currentSpaceId: 2)
        let resolution = request.resolution(for: changed)

        XCTAssertTrue(resolution.recordsActiveSpaceChange)
        XCTAssertEqual(resolution.rescanReason, .activeSpaceChanged)
    }

    func testUnlockSurvivesCoalescedNoOpActiveSpaceNotification() {
        let topology = makeTopology()
        var request = NativeSpaceInventoryRequest(
            reason: .unlock,
            baseline: topology
        )

        request.merge(reason: .activeSpaceChanged)
        let resolution = request.resolution(for: topology)

        XCTAssertFalse(resolution.recordsActiveSpaceChange)
        XCTAssertEqual(resolution.rescanReason, .unlock)
        XCTAssertFalse(request.reconcilesWorkspaceMonitorState)
    }

    func testMonitorChangeSurvivesCoalescedUnlockAndNoOpActiveSpaceNotification() {
        let topology = makeTopology()
        var request = NativeSpaceInventoryRequest(
            reason: .activeSpaceChanged,
            baseline: topology
        )

        request.merge(reason: .unlock)
        request.merge(reason: .monitorConfigurationChanged)
        request.merge(reason: .activeSpaceChanged)
        let resolution = request.resolution(for: topology)

        XCTAssertFalse(resolution.recordsActiveSpaceChange)
        XCTAssertEqual(resolution.rescanReason, .monitorConfigurationChanged)
        XCTAssertTrue(request.reconcilesWorkspaceMonitorState)
    }

    func testCoalescedActiveSpaceDeltaRecordsEventWithoutReplacingUnlockReason() {
        var request = NativeSpaceInventoryRequest(
            reason: .unlock,
            baseline: makeTopology(currentSpaceId: 1)
        )

        request.merge(reason: .activeSpaceChanged)
        let changed = makeTopology(currentSpaceId: 2)
        let resolution = request.resolution(for: changed)

        XCTAssertTrue(resolution.recordsActiveSpaceChange)
        XCTAssertEqual(resolution.rescanReason, .unlock)
    }

    func testScopeIncludesPIDsKnownOnSelectedSpacesBeforeOrAfterRefresh() {
        var previous = makeTopology()
        previous.windowSpace = [10: 2, 20: 1]
        var current = makeTopology()
        current.windowSpace = [30: 2, 40: 1]

        XCTAssertEqual(
            NativeSpaceInventoryScopeResolver.scope(
                spaceIds: [2],
                topologies: [previous, current],
                managedWindows: [
                    .init(pid: 100, windowId: 10),
                    .init(pid: 200, windowId: 20),
                    .init(pid: 300, windowId: 30),
                    .init(pid: 400, windowId: 40)
                ]
            ),
            .targeted(
                appPIDs: [],
                nativeSpaceIds: [2],
                nativeSpaceWindowIdsByPID: [100: [10], 300: [30]]
            )
        )
    }

    func testScopeIncludesManagedWindowsFromSpaceMissingInCurrentTopology() {
        var previous = makeTopology(
            displays: [
                .init(displayIdentifier: "primary", spaceIds: [1, 2, 99], currentSpaceId: 99)
            ],
            currentSpaceId: 99,
            activeSpaceId: 99,
            fullscreenSpaceIds: [99]
        )
        previous.windowSpace = [10: 99, 20: 2]
        var current = makeTopology(
            displays: [
                .init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1)
            ]
        )
        current.windowSpace = [30: 1]

        XCTAssertEqual(
            NativeSpaceInventoryScopeResolver.scope(
                spaceIds: [1],
                topologies: [previous, current],
                managedWindows: [
                    .init(pid: 100, windowId: 10),
                    .init(pid: 200, windowId: 20),
                    .init(pid: 300, windowId: 30)
                ]
            ),
            .targeted(
                appPIDs: [],
                nativeSpaceIds: [1],
                nativeSpaceWindowIdsByPID: [100: [10], 300: [30]]
            )
        )
    }

    func testScopeFallsBackToAllForMissingOrInvalidSpaceEvidence() {
        XCTAssertEqual(
            NativeSpaceInventoryScopeResolver.scope(
                spaceIds: [],
                topologies: [makeTopology()],
                managedWindows: []
            ),
            .all
        )
        XCTAssertEqual(
            NativeSpaceInventoryScopeResolver.scope(
                spaceIds: [0],
                topologies: [makeTopology()],
                managedWindows: []
            ),
            .all
        )
    }

    private func makeTopology(
        displays: [SpaceTopology.DisplaySpaces]? = nil,
        currentSpaceId: UInt64 = 1,
        activeSpaceId: UInt64? = nil,
        fullscreenSpaceIds: Set<UInt64> = []
    ) -> SpaceTopology {
        SpaceTopology(
            displays: displays ?? [
                .init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: currentSpaceId)
            ],
            activeSpaceId: activeSpaceId ?? currentSpaceId,
            fullscreenSpaceIds: fullscreenSpaceIds,
            windowSpace: [:]
        )
    }
}

@MainActor
private final class NativeSpaceInventoryTestProbe {
    var sample: NativeSpaceTopologySample?
    var sleeper: CheckedContinuation<Void, Never>?
}
