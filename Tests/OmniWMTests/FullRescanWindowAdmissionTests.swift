// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class FullRescanManagedWindowRebindGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct PendingFullRescanIdentityRebindFixture {
    let controller: WMController
    let workspaceId: WorkspaceDescriptor.ID
    let sourceWindow: AXManagedWindowIdentity
    let targetWindow: AXManagedWindowIdentity
}

@MainActor
final class FullRescanWindowAdmissionTests: XCTestCase {
    func testFullRescanProbesRegularAppsWithoutVisibleProcessEvidence() {
        XCTAssertTrue(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .regular,
                hasDiscoveryEvidence: false
            )
        )
        XCTAssertTrue(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: true
            )
        )
        XCTAssertFalse(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false
            )
        )
        XCTAssertFalse(
            AXManager.shouldEnumerateForFullRescan(
                activationPolicy: .prohibited,
                hasDiscoveryEvidence: true
            )
        )
    }

    func testFullRescanPrefersPreservedLogicalPIDOverWindowServerOwner() {
        let windowId = 467_001
        let preservedPID: pid_t = 467_002
        let ownerPID: pid_t = 467_003
        let preserved = candidate(pid: preservedPID, windowId: windowId)
        let owner = candidate(pid: ownerPID, windowId: windowId)

        XCTAssertTrue(
            AXManager.shouldPreferFullRescanCandidate(
                preserved,
                over: owner,
                activationPolicyByPID: [preservedPID: .regular, ownerPID: .regular],
                ownerPID: ownerPID,
                existingPID: preservedPID
            )
        )
    }

    func testFullRescanPreservesManagedStateUntilDestinationAXContextCanRebind() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_937
        let helperPID: pid_t = 467_938
        let windowId = 467_939
        let logicalAXRef = AXWindowRef(element: AXUIElementCreateApplication(logicalPID), windowId: windowId)
        let helperAXRef = AXWindowRef(element: AXUIElementCreateApplication(helperPID), windowId: windowId)
        let oldToken = controller.workspaceManager.addWindow(
            logicalAXRef,
            pid: logicalPID,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let observedAliases = FullRescanWindowIdentityAliases(
            pids: [logicalPID, helperPID],
            axRefs: [logicalAXRef, helperAXRef]
        )

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: helperAXRef,
            pid: helperPID,
            windowId: windowId,
            observedAliases: observedAliases
        )

        guard case let .preserve(preservedToken) = resolution else {
            return XCTFail("Expected existing identity to remain authoritative until AX rebind")
        }
        XCTAssertEqual(preservedToken, oldToken)
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.workspaceId, workspaceId)
        XCTAssertEqual(controller.workspaceManager.entry(for: oldToken)?.mode, .floating)
        let retryState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(windowId)]
        )
        guard case let .identityRebind(oldWindow, newWindow, _, _, _) = retryState.trigger else {
            return XCTFail("Expected an identity-rebind retry")
        }
        XCTAssertEqual(oldWindow.token, oldToken)
        XCTAssertEqual(newWindow.token, WindowToken(pid: helperPID, windowId: windowId))
        controller.axEventHandler.cancelCreatedWindowRetry(windowId: UInt32(windowId))
    }

    func testDeferredCreateDrainPreservesAndCompletesFullRescanIdentityRebind() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalPID: pid_t = 467_947
        let helperPID: pid_t = 467_948
        let windowId: UInt32 = 467_949
        let logicalAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(logicalPID),
            windowId: Int(windowId)
        )
        let helperAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(helperPID),
            windowId: Int(windowId)
        )
        let oldToken = controller.workspaceManager.addWindow(
            logicalAXRef,
            pid: logicalPID,
            windowId: Int(windowId),
            to: workspaceId,
            mode: .floating
        )
        let originalHandle = try XCTUnwrap(controller.workspaceManager.handle(for: oldToken))
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                oldToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.processCreatedWindow(windowId: windowId)
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: helperAXRef,
            pid: helperPID,
            windowId: Int(windowId),
            observedAliases: .init(
                pids: [logicalPID, helperPID],
                axRefs: [logicalAXRef, helperAXRef]
            )
        )
        guard case .preserve = resolution else {
            return XCTFail("Expected the managed identity to remain authoritative")
        }
        var originalState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]
        )
        originalState.task?.cancel()
        originalState.task = nil
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = originalState
        controller.axEventHandler.windowInfoProvider = { requestedWindowId in
            guard requestedWindowId == windowId else { return nil }
            return WindowServerInfo(
                id: windowId,
                pid: helperPID,
                level: 0,
                frame: CGRect(x: 0, y: 0, width: 640, height: 480)
            )
        }

        await controller.axEventHandler.drainDeferredCreatedWindows()

        let retainedState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[windowId]
        )
        XCTAssertEqual(retainedState.generation, originalState.generation)
        XCTAssertEqual(retainedState.attempt, originalState.attempt)
        guard case let .identityRebind(
            oldWindow,
            newWindow,
            managedReplacementMetadata,
            admissionHints,
            sizeConstraints
        ) = retainedState.trigger else {
            return XCTFail("Expected the identity-rebind retry to retain ownership")
        }
        XCTAssertEqual(oldWindow.token, oldToken)
        let newToken = WindowToken(pid: helperPID, windowId: Int(windowId))
        XCTAssertEqual(newWindow.token, newToken)
        let retainedEntry = try XCTUnwrap(controller.workspaceManager.entry(for: oldToken))
        XCTAssertEqual(retainedEntry.workspaceId, workspaceId)
        XCTAssertEqual(retainedEntry.mode, .floating)
        XCTAssertTrue(CFEqual(retainedEntry.axRef.element, logicalAXRef.element))
        XCTAssertTrue(controller.workspaceManager.selectedManagedHandle === originalHandle)

        let executionOwner: UInt64 = 467_949
        var runningState = retainedState
        runningState.executionPhase = .running(executionOwner)
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] = runningState
        controller.hasStartedServices = true
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { $0 == helperPID }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in true }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }

        await controller.axEventHandler.completeManagedWindowIdentityRebind(
            from: oldWindow,
            to: newWindow,
            windowId: windowId,
            retryGeneration: retainedState.generation,
            executionOwner: executionOwner,
            managedReplacementMetadata: managedReplacementMetadata,
            admissionHints: admissionHints,
            sizeConstraints: sizeConstraints
        )

        XCTAssertNil(controller.axEventHandler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        let reboundEntry = try XCTUnwrap(controller.workspaceManager.entry(for: newToken))
        XCTAssertEqual(reboundEntry.workspaceId, workspaceId)
        XCTAssertEqual(reboundEntry.mode, .floating)
        XCTAssertTrue(CFEqual(reboundEntry.axRef.element, helperAXRef.element))
        XCTAssertTrue(controller.workspaceManager.handle(for: newToken) === originalHandle)
        XCTAssertTrue(controller.workspaceManager.entry(for: originalHandle)?.token == newToken)
        XCTAssertTrue(controller.workspaceManager.selectedManagedHandle === originalHandle)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, newToken)
        XCTAssertEqual(controller.workspaceManager.allEntries().count, 1)
    }

    func testFullRescanPreservesExactActiveIdentityRebindWithoutSameWindowIdEntry() throws {
        let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 1)

        let resolution = fixture.controller.axEventHandler.resolveFullRescanIdentity(
            axRef: fixture.targetWindow.axRef,
            pid: fixture.targetWindow.token.pid,
            windowId: fixture.targetWindow.token.windowId,
            observedAliases: nil
        )

        guard case let .preserve(preservedToken) = resolution else {
            return XCTFail("Expected the active identity rebind source to remain authoritative")
        }
        XCTAssertEqual(preservedToken, fixture.sourceWindow.token)
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: fixture.sourceWindow.token))
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: fixture.targetWindow.token))
        XCTAssertEqual(fixture.controller.workspaceManager.allEntries().count, 1)
        XCTAssertNotNil(
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ]
        )
    }

    func testFullRescanProcessesOrdinaryExhaustedDestroyedAndMismatchedRebindTargets() throws {
        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 2)
            var state = try XCTUnwrap(
                fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                    UInt32(fixture.targetWindow.token.windowId)
                ]
            )
            state.trigger = .candidate(
                token: fixture.targetWindow.token,
                axRef: fixture.targetWindow.axRef
            )
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ] = state
            assertProcessesUntrackedFullRescanCandidate(fixture)
        }

        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 3)
            var state = try XCTUnwrap(
                fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                    UInt32(fixture.targetWindow.token.windowId)
                ]
            )
            state.exhausted = true
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ] = state
            assertProcessesUntrackedFullRescanCandidate(fixture)
        }

        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 4)
            var state = try XCTUnwrap(
                fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                    UInt32(fixture.targetWindow.token.windowId)
                ]
            )
            state.identityRebindTargetDestroyed = true
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ] = state
            assertProcessesUntrackedFullRescanCandidate(fixture)
        }

        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 5)
            let mismatchedTargetRef = AXWindowRef(
                element: AXUIElementCreateApplication(fixture.targetWindow.token.pid + 20),
                windowId: fixture.targetWindow.token.windowId
            )
            var state = try XCTUnwrap(
                fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                    UInt32(fixture.targetWindow.token.windowId)
                ]
            )
            state.axRef = mismatchedTargetRef
            state.trigger = .identityRebind(
                oldWindow: fixture.sourceWindow,
                newWindow: AXManagedWindowIdentity(
                    token: fixture.targetWindow.token,
                    axRef: mismatchedTargetRef
                ),
                managedReplacementMetadata: nil,
                admissionHints: nil,
                sizeConstraints: nil
            )
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ] = state
            assertProcessesUntrackedFullRescanCandidate(fixture)
        }

        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 6)
            let unrelatedToken = WindowToken(
                pid: fixture.targetWindow.token.pid,
                windowId: fixture.targetWindow.token.windowId + 1
            )
            let unrelatedWindow = AXManagedWindowIdentity(
                token: unrelatedToken,
                axRef: AXWindowRef(
                    element: fixture.targetWindow.axRef.element,
                    windowId: unrelatedToken.windowId
                )
            )
            var state = try XCTUnwrap(
                fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                    UInt32(fixture.targetWindow.token.windowId)
                ]
            )
            state.trigger = .identityRebind(
                oldWindow: fixture.sourceWindow,
                newWindow: unrelatedWindow,
                managedReplacementMetadata: nil,
                admissionHints: nil,
                sizeConstraints: nil
            )
            fixture.controller.axEventHandler.admissionRetryStateByWindowId[
                UInt32(fixture.targetWindow.token.windowId)
            ] = state
            assertProcessesUntrackedFullRescanCandidate(fixture)
        }

        do {
            let fixture = try pendingFullRescanIdentityRebindFixture(suffix: 7)
            assertProcessesUntrackedFullRescanCandidate(
                fixture,
                pid: fixture.targetWindow.token.pid + 1
            )
        }
    }

    func testFullRescanProcessesIdentityRebindWithMissingOrReplacedSource() throws {
        let missingSource = try pendingFullRescanIdentityRebindFixture(
            suffix: 8,
            tracksSource: false
        )
        assertProcessesUntrackedFullRescanCandidate(missingSource)

        let replacedSource = try pendingFullRescanIdentityRebindFixture(suffix: 9)
        let replacementSourceRef = AXWindowRef(
            element: AXUIElementCreateApplication(replacedSource.sourceWindow.token.pid + 30),
            windowId: replacedSource.sourceWindow.token.windowId
        )
        XCTAssertNotNil(
            replacedSource.controller.workspaceManager.rekeyWindow(
                from: replacedSource.sourceWindow.token,
                to: replacedSource.sourceWindow.token,
                newAXRef: replacementSourceRef
            )
        )
        assertProcessesUntrackedFullRescanCandidate(replacedSource)
    }

    func testGhosttyIdentityRoundTripPreservesNiriAndRuntimeStateDuringFullRescan() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let monitor = Monitor(
            id: .init(displayId: 468_560),
            displayId: 468_560,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: "Ghostty Identity Test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        let engine = try XCTUnwrap(controller.niriEngine)
        let pid: pid_t = 468_560
        let restoredToken = WindowToken(pid: pid, windowId: 5_537)
        let transientToken = WindowToken(pid: pid, windowId: 5_617)
        let originalAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: restoredToken.windowId
        )
        _ = controller.workspaceManager.addWindow(
            originalAXRef,
            pid: restoredToken.pid,
            windowId: restoredToken.windowId,
            to: workspaceId
        )
        let originalNode = controller.workspaceManager.withEngineMutationScope(
            in: workspaceId,
            label: "ghostty_identity_round_trip"
        ) {
            let node = engine.addWindow(token: restoredToken, to: workspaceId, afterSelection: nil)
            engine.activateWindow(node.id, in: workspaceId)
            return node
        }
        let originalColumn = try XCTUnwrap(engine.column(of: originalNode))
        let originalHandle = try XCTUnwrap(controller.workspaceManager.handle(for: restoredToken))
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                restoredToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        var viewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        viewport.activeColumnIndex = try XCTUnwrap(
            engine.columnIndex(of: originalColumn, in: workspaceId)
        )
        viewport.selectedNodeId = originalNode.id
        controller.workspaceManager.updateNiriViewportState(viewport, for: workspaceId)
        let originalViewport = controller.workspaceManager.niriViewportState(for: workspaceId)
        let desktopSpaceId: UInt64 = 468_561
        controller.workspaceManager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(
                        displayIdentifier: "ghostty-test-display",
                        spaceIds: [desktopSpaceId],
                        currentSpaceId: desktopSpaceId
                    )
                ],
                activeSpaceId: desktopSpaceId,
                fullscreenSpaceIds: [],
                windowSpace: [restoredToken.windowId: desktopSpaceId]
            )
        )
        let appliedFrame = CGRect(x: 80, y: 60, width: 720, height: 520)
        controller.axManager.confirmFrameWrite(
            for: restoredToken.windowId,
            frame: appliedFrame
        )

        let transientAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: transientToken.windowId
        )
        guard case .committed = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: restoredToken,
            to: transientToken,
            windowId: UInt32(transientToken.windowId),
            axRef: transientAXRef
        ) else {
            return XCTFail("Expected the initial Ghostty identity change to commit synchronously")
        }
        XCTAssertNil(controller.workspaceManager.entry(for: restoredToken))
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [transientToken])
        XCTAssertTrue(controller.workspaceManager.handle(for: transientToken) === originalHandle)
        XCTAssertTrue(engine.findNode(for: transientToken, in: workspaceId) === originalNode)
        XCTAssertTrue(engine.column(of: originalNode) === originalColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 1)
        XCTAssertEqual(originalColumn.windowNodes.map(\.token), [transientToken])
        XCTAssertTrue(controller.workspaceManager.selectedManagedHandle === originalHandle)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, transientToken)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            originalViewport
        )
        XCTAssertNil(controller.workspaceManager.spaceTopology.spaceForWindow(restoredToken.windowId))
        XCTAssertEqual(
            controller.workspaceManager.spaceTopology.spaceForWindow(transientToken.windowId),
            desktopSpaceId
        )
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: restoredToken.windowId))
        XCTAssertEqual(
            controller.axManager.lastAppliedFrame(for: transientToken.windowId),
            appliedFrame
        )

        let restoredAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 2),
            windowId: restoredToken.windowId
        )
        let gate = FullRescanManagedWindowRebindGate()
        defer { gate.release() }
        let acknowledgementEntered = expectation(description: "Ghostty rebind acknowledgement entered")
        controller.hasStartedServices = true
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { $0 == pid }
        controller.axEventHandler.managedWindowIdentityRebindAcknowledgementProvider = { _, _ in
            acknowledgementEntered.fulfill()
            await gate.wait()
            return true
        }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        guard case .pending = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: transientToken,
            to: restoredToken,
            windowId: UInt32(restoredToken.windowId),
            axRef: restoredAXRef
        ) else {
            return XCTFail("Expected the restored Ghostty identity to wait for acknowledgement")
        }
        var retryState = try XCTUnwrap(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(restoredToken.windowId)]
        )
        retryState.task?.cancel()
        retryState.task = nil
        let executionOwner: UInt64 = 468_562
        retryState.executionPhase = .running(executionOwner)
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(restoredToken.windowId)] = retryState
        guard case let .identityRebind(
            oldWindow,
            newWindow,
            managedReplacementMetadata,
            admissionHints,
            sizeConstraints
        ) = retryState.trigger else {
            return XCTFail("Expected the reverse Ghostty identity rebind retry")
        }

        let completion = Task { @MainActor in
            await controller.axEventHandler.completeManagedWindowIdentityRebind(
                from: oldWindow,
                to: newWindow,
                windowId: UInt32(restoredToken.windowId),
                retryGeneration: retryState.generation,
                executionOwner: executionOwner,
                managedReplacementMetadata: managedReplacementMetadata,
                admissionHints: admissionHints,
                sizeConstraints: sizeConstraints
            )
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: restoredAXRef,
            pid: restoredToken.pid,
            windowId: restoredToken.windowId,
            observedAliases: nil
        )
        guard case let .preserve(preservedToken) = resolution else {
            gate.release()
            await completion.value
            return XCTFail("Expected full rescan to preserve the pending Ghostty source identity")
        }
        XCTAssertEqual(preservedToken, transientToken)
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [transientToken])
        XCTAssertNil(controller.workspaceManager.entry(for: restoredToken))
        XCTAssertTrue(engine.findNode(for: transientToken, in: workspaceId) === originalNode)
        XCTAssertTrue(engine.column(of: originalNode) === originalColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 1)
        XCTAssertEqual(originalColumn.windowNodes.map(\.token), [transientToken])
        XCTAssertTrue(controller.workspaceManager.selectedManagedHandle === originalHandle)
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            originalViewport
        )

        gate.release()
        await completion.value

        XCTAssertNil(controller.workspaceManager.entry(for: transientToken))
        XCTAssertEqual(controller.workspaceManager.allEntries().map(\.token), [restoredToken])
        XCTAssertTrue(controller.workspaceManager.handle(for: restoredToken) === originalHandle)
        XCTAssertTrue(controller.workspaceManager.selectedManagedHandle === originalHandle)
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, restoredToken)
        XCTAssertNil(engine.findNode(for: transientToken, in: workspaceId))
        XCTAssertTrue(engine.findNode(for: restoredToken, in: workspaceId) === originalNode)
        XCTAssertTrue(engine.column(of: originalNode) === originalColumn)
        XCTAssertEqual(engine.columns(in: workspaceId).count, 1)
        XCTAssertEqual(originalColumn.windowNodes.map(\.token), [restoredToken])
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            originalViewport
        )
        XCTAssertNil(controller.workspaceManager.spaceTopology.spaceForWindow(transientToken.windowId))
        XCTAssertEqual(
            controller.workspaceManager.spaceTopology.spaceForWindow(restoredToken.windowId),
            desktopSpaceId
        )
        XCTAssertNil(controller.axManager.lastAppliedFrame(for: transientToken.windowId))
        XCTAssertEqual(
            controller.axManager.lastAppliedFrame(for: restoredToken.windowId),
            appliedFrame
        )
        XCTAssertNil(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(restoredToken.windowId)]
        )
        XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
    }

    func testDeferredCreatePreservesOnlyUniqueStructuralReplacement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_950
        let oldToken = WindowToken(pid: pid, windowId: 467_951)
        let newToken = WindowToken(pid: pid, windowId: 467_952)
        let unrelatedToken = WindowToken(pid: pid, windowId: 467_953)
        let matchingFrame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let unrelatedFrame = CGRect(x: 1_200, y: 900, width: 420, height: 320)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: oldToken.windowId),
            pid: oldToken.pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: matchingFrame
            )
        )
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: unrelatedToken.windowId),
            pid: unrelatedToken.pid,
            windowId: unrelatedToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: unrelatedFrame
            )
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )

        deferCreatedWindow(newToken, controller: controller)
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: matchingFrame)

        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController
                .yieldToDeferredCreate(
                    token: newToken,
                    bundleId: bundleId,
                    mode: .tiling,
                    facts: facts,
                    scope: .all,
                    capturedWindowServerInfoByWindowId: [
                        newToken.windowId: replacementWindowInfo(token: newToken, frame: matchingFrame)
                    ],
                    entry: nil,
                    seenKeys: &seenKeys
                )
        )
        XCTAssertEqual(seenKeys, [oldToken])
        XCTAssertEqual(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[UInt32(newToken.windowId)]?
                .protectedTokens,
            [oldToken]
        )
        let missingEntries = controller.layoutRefreshController.confirmedMissingEntries(
            keys: seenKeys,
            requiredConsecutiveMisses: 2
        )
        XCTAssertEqual(missingEntries.map(\.token), [unrelatedToken])
        XCTAssertNil(controller.workspaceManager.entry(for: newToken))

        var rejectedSeenKeys: Set<WindowToken> = []
        XCTAssertFalse(
            controller.layoutRefreshController
                .yieldToDeferredCreate(
                    token: newToken,
                    bundleId: bundleId,
                    mode: .tiling,
                    facts: facts,
                    scope: .all,
                    capturedWindowServerInfoByWindowId: [:],
                    entry: try XCTUnwrap(controller.workspaceManager.entry(for: oldToken)),
                    seenKeys: &rejectedSeenKeys
                )
        )
        XCTAssertFalse(
            controller.layoutRefreshController
                .yieldToDeferredCreate(
                    token: WindowToken(pid: pid, windowId: newToken.windowId + 1),
                    bundleId: bundleId,
                    mode: .tiling,
                    facts: facts,
                    scope: .all,
                    capturedWindowServerInfoByWindowId: [:],
                    entry: nil,
                    seenKeys: &rejectedSeenKeys
                )
        )
        XCTAssertTrue(rejectedSeenKeys.isEmpty)
    }

    func testSuccessfulDeferredReplacementRekeyDoesNotScheduleMissingConfirmation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { controller.layoutRefreshController.resetState() }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_984
        let oldToken = WindowToken(pid: pid, windowId: 467_985)
        let newToken = WindowToken(pid: pid, windowId: 467_986)
        let frame = CGRect(x: 80, y: 60, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: oldToken),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        deferCreatedWindow(newToken, controller: controller)
        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: replacementFacts(token: newToken, bundleId: bundleId, frame: frame),
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        let result = controller.axEventHandler.rekeyManagedWindowIdentity(
            from: oldToken,
            to: newToken,
            windowId: UInt32(newToken.windowId),
            axRef: WindowAdmissionTestSupport.axRef(for: newToken)
        )

        guard case .committed = result else {
            return XCTFail("Expected synchronous replacement rekey")
        }
        XCTAssertNil(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[UInt32(newToken.windowId)]
        )
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope)
        XCTAssertNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testStructuralReplacementRestoreClearsPostRekeyNativeFullscreenState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_982
        let oldToken = WindowToken(pid: pid, windowId: 467_983)
        let newToken = WindowToken(pid: pid, windowId: 467_984)
        let frame = CGRect(x: 80, y: 60, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: oldToken),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId
        )
        XCTAssertTrue(controller.workspaceManager.requestNativeFullscreenEnter(oldToken, in: workspaceId))
        XCTAssertTrue(controller.workspaceManager.markNativeFullscreenSuspended(oldToken))
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: frame)

        XCTAssertTrue(
            controller.axEventHandler.rekeyStructuralManagedReplacement(
                match: .init(
                    token: oldToken,
                    workspaceId: workspaceId,
                    source: .liveInvisible
                ),
                token: newToken,
                windowId: UInt32(newToken.windowId),
                axRef: WindowAdmissionTestSupport.axRef(for: newToken),
                bundleId: bundleId,
                mode: .tiling,
                facts: facts
            )
        )
        controller.layoutRefreshController.restoreNativeFullscreenAfterStructuralReplacement(
            from: oldToken,
            to: newToken,
            appFullscreen: false
        )

        XCTAssertNil(controller.workspaceManager.entry(for: oldToken))
        XCTAssertNotNil(controller.workspaceManager.entry(for: newToken))
        XCTAssertNil(controller.workspaceManager.nativeFullscreenRecord(for: newToken))
        XCTAssertEqual(controller.workspaceManager.layoutReason(for: newToken), .standard)
        XCTAssertTrue(
            controller.layoutRefreshController
                .consumeNativeFullscreenRestoredFrameApply(for: newToken)
        )
    }

    func testDeferredReplacementRetryExhaustionSchedulesOneMissingConfirmation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_987
        let oldToken = WindowToken(pid: pid, windowId: 467_988)
        let newToken = WindowToken(pid: pid, windowId: 467_989)
        let frame = CGRect(x: 80, y: 60, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: oldToken),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        deferCreatedWindow(newToken, controller: controller)
        let scope = RescanScope.targeted(appPIDs: [pid], nativeSpaceIds: [])
        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: replacementFacts(token: newToken, bundleId: bundleId, frame: frame),
                scope: scope,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )
        let axRef = WindowAdmissionTestSupport.axRef(for: newToken)
        let trigger = AdmissionRetryTrigger.candidate(token: newToken, axRef: axRef)
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(newToken.windowId)] =
            AdmissionRetryState(
                expectedToken: newToken,
                axRef: axRef,
                reason: .factsDeferred,
                attempt: AXEventHandler.createdWindowRetryLimit,
                generation: 1,
                trigger: trigger,
                exhausted: false,
                executionPhase: .running(1)
            )

        XCTAssertFalse(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: UInt32(newToken.windowId),
                expectedToken: newToken,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: trigger
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.admissionRetryStateByWindowId[UInt32(newToken.windowId)]?
                .exhausted == true
        )
        XCTAssertNil(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[UInt32(newToken.windowId)]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)

        controller.axEventHandler.rejectDeferredReplacement(windowId: UInt32(newToken.windowId))

        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
    }

    func testAlreadyExhaustedRetrySettlesDeferredReplacementProtection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_995, windowId: 467_996)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 467_997)
        _ = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        let scope = RescanScope.targeted(appPIDs: [oldToken.pid], nativeSpaceIds: [])
        let windowId = UInt32(newToken.windowId)
        let axRef = WindowAdmissionTestSupport.axRef(for: newToken)
        let trigger = AdmissionRetryTrigger.candidate(token: newToken, axRef: axRef)
        controller.axEventHandler.protectDeferredReplacement(
            windowId: windowId,
            token: oldToken,
            scope: scope
        )
        controller.axEventHandler.admissionRetryStateByWindowId[windowId] =
            AdmissionRetryState(
                expectedToken: newToken,
                axRef: axRef,
                reason: .factsDeferred,
                attempt: AXEventHandler.createdWindowRetryLimit,
                generation: 1,
                trigger: trigger,
                exhausted: true
            )

        XCTAssertFalse(
            controller.axEventHandler.scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: newToken,
                axRef: axRef,
                reason: .factsDeferred,
                trigger: trigger
            )
        )
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[windowId]
        )
        XCTAssertEqual(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope, scope)
        XCTAssertNotNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testInactiveSpaceDeferredReplacementProtectsOnlyProvenSamePIDMatch() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_990
        let oldToken = WindowToken(pid: pid, windowId: 467_991)
        let newToken = WindowToken(pid: pid, windowId: 467_992)
        let unrelatedToken = WindowToken(pid: pid, windowId: 467_994)
        let frame = CGRect(x: 80, y: 60, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: oldToken),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        _ = WindowAdmissionTestSupport.track(
            unrelatedToken,
            in: workspaceId,
            controller: controller
        )
        var topology = SpaceTopology()
        topology.displays = [
            .init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1)
        ]
        topology.activeSpaceId = 1
        controller.workspaceManager.commitSpaceTopology(topology)
        deferCreatedWindow(newToken, controller: controller)
        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: replacementFacts(token: newToken, bundleId: bundleId, frame: frame),
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )
        controller.axEventHandler.windowInfoProvider = { windowId in
            self.replacementWindowInfo(
                token: WindowToken(pid: pid, windowId: Int(windowId)),
                frame: frame
            )
        }

        await controller.axEventHandler.drainDeferredCreatedWindows { _ in [2] }
        await controller.axEventHandler.drainDeferredCreatedWindows { _ in [2] }
        let firstProtectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: [oldToken, unrelatedToken],
                scope: .all
            )
        await controller.axEventHandler.drainDeferredCreatedWindows { _ in [2] }
        let secondProtectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: [oldToken, unrelatedToken],
                scope: .all
            )

        XCTAssertTrue(controller.axEventHandler.isCreatedWindowDeferred(UInt32(newToken.windowId)))
        XCTAssertEqual(firstProtectedTokens, [oldToken])
        XCTAssertEqual(secondProtectedTokens, [oldToken])
        let protection = try XCTUnwrap(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[UInt32(newToken.windowId)]
        )
        XCTAssertEqual(protection.protectedTokens, [oldToken])
        XCTAssertTrue(protection.fallbackProtectedTokens.isEmpty)
        XCTAssertFalse(protection.permitsPIDFallback)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingMissingConfirmationScope)
        XCTAssertNil(controller.layoutRefreshController.layoutState.missingConfirmationTask)
    }

    func testDeferredCreateDoesNotProtectReplacementOutsideCapturedCoverage() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_970
        let oldToken = WindowToken(pid: pid, windowId: 467_971)
        let newToken = WindowToken(pid: pid, windowId: 467_972)
        let frame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: oldToken.windowId),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        deferCreatedWindow(newToken, controller: controller)

        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: replacementFacts(token: newToken, bundleId: bundleId, frame: frame),
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                capturedWindowServerAuthoritativeWindowIds: [newToken.windowId],
                entry: nil,
                seenKeys: &seenKeys
            )
        )
        XCTAssertTrue(seenKeys.isEmpty)
    }

    func testStructuralReplacementAcceptsEmptyBoundedWindowServerAuthority() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_966
        let oldToken = WindowToken(pid: pid, windowId: 467_967)
        let newToken = WindowToken(pid: pid, windowId: 467_968)
        let frame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: oldToken),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: frame)

        XCTAssertNil(
            controller.axEventHandler.structuralReplacementMatch(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: facts,
                capturedWindowServerInfoByWindowId: [:]
            )
        )
        XCTAssertEqual(
            controller.axEventHandler.structuralReplacementMatch(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: facts,
                capturedWindowServerInfoByWindowId: [:],
                capturedWindowServerAuthoritativeWindowIds: [oldToken.windowId],
                capturedWindowServerAuthoritativePIDs: [pid]
            )?.token,
            oldToken
        )
    }

    func testPostSnapshotDeferredCreateProtectsOnlyMatchingPIDFromMissingRetirement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_973, windowId: 467_974)
        let newToken = WindowToken(pid: oldToken.pid, windowId: 467_975)
        let unrelatedToken = WindowToken(pid: 467_976, windowId: 467_977)
        for token in [oldToken, unrelatedToken] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        deferCreatedWindow(newToken, controller: controller)
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard windowId == UInt32(newToken.windowId) else { return nil }
            return self.replacementWindowInfo(
                token: newToken,
                frame: CGRect(x: 80, y: 60, width: 720, height: 520)
            )
        }
        let candidates: Set<WindowToken> = [oldToken, unrelatedToken]
        let protectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            )

        XCTAssertEqual(protectedTokens, [oldToken])
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: candidates.subtracting(protectedTokens),
                permitsMissingRetirement: true
            ).map(\.token),
            [unrelatedToken]
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: [oldToken],
                permitsMissingRetirement: true
            ).map(\.token),
            [oldToken]
        )
    }

    func testRuleReevaluationRetryDoesNotProtectMissingSiblingWindow() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_969
        let missingToken = WindowToken(pid: pid, windowId: 467_970)
        let retryToken = WindowToken(pid: pid, windowId: 467_971)
        _ = WindowAdmissionTestSupport.track(missingToken, in: workspaceId, controller: controller)
        let retryAXRef = WindowAdmissionTestSupport.axRef(for: retryToken)
        _ = controller.workspaceManager.addWindow(
            retryAXRef,
            pid: retryToken.pid,
            windowId: retryToken.windowId,
            to: workspaceId,
            mode: .floating
        )
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(retryToken.windowId)] =
            AdmissionRetryState(
                expectedToken: retryToken,
                axRef: retryAXRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: 1,
                trigger: .ruleReevaluation(token: retryToken, axRef: retryAXRef),
                exhausted: false
            )

        XCTAssertTrue(
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: [missingToken],
                scope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
            ).isEmpty
        )
        XCTAssertNil(
            controller.axEventHandler
                .deferredReplacementProtectionsByWindowId[UInt32(retryToken.windowId)]
        )
    }

    func testPIDLessDeferredCreateDoesNotBroadenMissingProtection() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let exactToken = WindowToken(pid: 467_984, windowId: 467_985)
        let unrelatedToken = WindowToken(pid: 467_986, windowId: 467_987)
        let pendingWindowId: UInt32 = 467_988
        for token in [exactToken, unrelatedToken] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        deferCreatedWindow(
            WindowToken(pid: 467_989, windowId: Int(pendingWindowId)),
            controller: controller
        )
        let candidates: Set<WindowToken> = [exactToken, unrelatedToken]

        XCTAssertTrue(
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            ).isEmpty
        )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: pendingWindowId,
            token: exactToken,
            scope: .all
        )
        XCTAssertEqual(
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            ),
            [exactToken]
        )
    }

    func testFactsDeferredCandidateProtectsOnlyMatchingPIDFromMissingRetirement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer {
            controller.axEventHandler.resetCreatedWindowRetryState()
            controller.layoutRefreshController.resetState()
        }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_978, windowId: 467_979)
        let unrelatedToken = WindowToken(pid: 467_980, windowId: 467_981)
        for token in [oldToken, unrelatedToken] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )

        let pendingToken = WindowToken(pid: oldToken.pid, windowId: 467_982)
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(pendingToken.windowId)] =
            AdmissionRetryState(
                expectedToken: pendingToken,
                axRef: WindowAdmissionTestSupport.axRef(for: pendingToken),
                reason: .factsDeferred,
                attempt: 1,
                generation: 1,
                trigger: .candidate(
                    token: pendingToken,
                    axRef: WindowAdmissionTestSupport.axRef(for: pendingToken)
                ),
                exhausted: false
            )
        let candidates: Set<WindowToken> = [oldToken, unrelatedToken]
        let protectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            )

        XCTAssertEqual(protectedTokens, [oldToken])
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: candidates.subtracting(protectedTokens),
                permitsMissingRetirement: true
            ).map(\.token),
            [unrelatedToken]
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: [oldToken],
                permitsMissingRetirement: true
            ).map(\.token),
            [oldToken]
        )
    }

    func testExhaustedFactsRetryReenablesMissingRetirement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let oldToken = WindowToken(pid: 467_980, windowId: 467_981)
        let pendingToken = WindowToken(pid: oldToken.pid, windowId: 467_983)
        let pendingAXRef = WindowAdmissionTestSupport.axRef(for: pendingToken)
        _ = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(pendingToken.windowId)] =
            AdmissionRetryState(
                expectedToken: pendingToken,
                axRef: pendingAXRef,
                reason: .factsDeferred,
                attempt: 8,
                generation: 1,
                trigger: .candidate(token: pendingToken, axRef: pendingAXRef),
                exhausted: true
            )
        let protectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: [oldToken],
                scope: .all
            )

        XCTAssertTrue(protectedTokens.isEmpty)
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: [],
                eligibleKeys: nil,
                permitsMissingRetirement: true
            ).map(\.token),
            [oldToken]
        )
    }

    func testDeferredCreateDoesNotProtectUnrelatedSamePIDWindow() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_954
        let oldToken = WindowToken(pid: pid, windowId: 467_955)
        let newToken = WindowToken(pid: pid, windowId: 467_956)
        let oldFrame = CGRect(x: 80, y: 60, width: 500, height: 400)
        let newFrame = CGRect(x: 1_400, y: 900, width: 300, height: 240)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: oldToken.windowId),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: oldFrame
            )
        )
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        deferCreatedWindow(newToken, controller: controller)
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: newFrame)

        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: facts,
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: newFrame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        XCTAssertTrue(seenKeys.isEmpty)
        let candidates: Set<WindowToken> = [oldToken]
        let protectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            )
        XCTAssertTrue(protectedTokens.isEmpty)
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: nil,
                factsAreDeferred: true,
                facts: facts,
                scope: .all,
                capturedWindowServerInfoByWindowId: [:],
                entry: nil,
                seenKeys: &seenKeys
            )
        )
        XCTAssertTrue(
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            ).isEmpty
        )
        XCTAssertEqual(
            controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                seenKeys: seenKeys,
                eligibleKeys: candidates.subtracting(protectedTokens),
                permitsMissingRetirement: true
            ).map(\.token),
            [oldToken]
        )
    }

    func testDeferredCreateDoesNotProtectAmbiguousStructuralReplacements() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_957
        let firstOldToken = WindowToken(pid: pid, windowId: 467_958)
        let secondOldToken = WindowToken(pid: pid, windowId: 467_959)
        let newToken = WindowToken(pid: pid, windowId: 467_960)
        let frame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        for token in [firstOldToken, secondOldToken] {
            _ = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: token.windowId),
                pid: pid,
                windowId: token.windowId,
                to: workspaceId,
                managedReplacementMetadata: replacementMetadata(
                    bundleId: bundleId,
                    workspaceId: workspaceId,
                    frame: frame
                )
            )
        }
        XCTAssertTrue(
            controller.layoutRefreshController.confirmedMissingEntries(
                keys: [],
                requiredConsecutiveMisses: 2
            ).isEmpty
        )
        deferCreatedWindow(newToken, controller: controller)
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: frame)

        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: facts,
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        XCTAssertTrue(seenKeys.isEmpty)
        let candidates: Set<WindowToken> = [firstOldToken, secondOldToken]
        let protectedTokens =
            controller.axEventHandler.protectMissingEntriesDuringUnsettledAdmission(
                candidates: candidates,
                scope: .all
            )
        XCTAssertTrue(protectedTokens.isEmpty)
        XCTAssertEqual(
            Set(
                controller.layoutRefreshController.confirmedMissingEntriesDuringFullRescan(
                    seenKeys: seenKeys,
                    eligibleKeys: candidates.subtracting(protectedTokens),
                    permitsMissingRetirement: true
                ).map(\.token)
            ),
            [firstOldToken, secondOldToken]
        )
    }

    func testDeferredCreateTreatsPendingDestroyAndLiveEntryAsOneReplacement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 467_961
        let oldToken = WindowToken(pid: pid, windowId: 467_962)
        let newToken = WindowToken(pid: pid, windowId: 467_963)
        let frame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let bundleId = replacementBundleId(pid)
        _ = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: oldToken.windowId),
            pid: pid,
            windowId: oldToken.windowId,
            to: workspaceId,
            managedReplacementMetadata: replacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                frame: frame
            )
        )
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.handleCGSEvent(.closed(windowId: UInt32(oldToken.windowId)))
        XCTAssertNotNil(controller.workspaceManager.entry(for: oldToken))
        deferCreatedWindow(newToken, controller: controller)
        let facts = replacementFacts(token: newToken, bundleId: bundleId, frame: frame)

        var seenKeys: Set<WindowToken> = []
        XCTAssertTrue(
            controller.layoutRefreshController.yieldToDeferredCreate(
                token: newToken,
                bundleId: bundleId,
                mode: .tiling,
                facts: facts,
                scope: .all,
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        XCTAssertEqual(seenKeys, [oldToken])
        controller.axEventHandler.resetManagedReplacementState()
    }

    func testFailedExistingEndpointCannotBeRetiredByUnprovenCandidate() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let existingPID: pid_t = 46_793
        let candidatePID: pid_t = 46_794
        let windowId = 46_795
        let existingAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(existingPID),
            windowId: windowId
        )
        let candidateAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(candidatePID),
            windowId: windowId
        )
        let existingToken = controller.workspaceManager.addWindow(
            existingAXRef,
            pid: existingPID,
            windowId: windowId,
            to: workspaceId
        )
        controller.workspaceManager.withEngineMutationScope {
            _ = controller.niriEngine?.addWindow(token: existingToken, to: workspaceId, afterSelection: nil)
        }

        let resolution = controller.axEventHandler.resolveFullRescanIdentity(
            axRef: candidateAXRef,
            pid: candidatePID,
            windowId: windowId,
            observedAliases: .init(pids: [candidatePID], axRefs: [candidateAXRef]),
            failedPIDs: [existingPID]
        )

        guard case let .preserve(preservedToken) = resolution else {
            return XCTFail("Expected failed existing endpoint to remain authoritative")
        }
        XCTAssertEqual(preservedToken, existingToken)
        let retained = try XCTUnwrap(controller.workspaceManager.entry(for: existingToken))
        XCTAssertTrue(CFEqual(retained.axRef.element, existingAXRef.element))
        XCTAssertNotNil(controller.niriEngine?.findNode(for: existingToken, in: workspaceId))
        XCTAssertNil(controller.workspaceManager.entry(for: WindowToken(pid: candidatePID, windowId: windowId)))
    }

    private func pendingFullRescanIdentityRebindFixture(
        suffix: Int,
        tracksSource: Bool = true
    ) throws -> PendingFullRescanIdentityRebindFixture {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid = pid_t(468_600 + suffix * 10)
        let sourceToken = WindowToken(pid: pid, windowId: 468_700 + suffix * 10)
        let targetToken = WindowToken(pid: pid, windowId: 468_800 + suffix * 10)
        let sourceWindow = AXManagedWindowIdentity(
            token: sourceToken,
            axRef: AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: sourceToken.windowId
            )
        )
        let targetWindow = AXManagedWindowIdentity(
            token: targetToken,
            axRef: AXWindowRef(
                element: AXUIElementCreateApplication(pid + 1),
                windowId: targetToken.windowId
            )
        )
        if tracksSource {
            _ = controller.workspaceManager.addWindow(
                sourceWindow.axRef,
                pid: sourceToken.pid,
                windowId: sourceToken.windowId,
                to: workspaceId
            )
        }
        controller.axEventHandler.admissionRetryStateByWindowId[UInt32(targetToken.windowId)] =
            AdmissionRetryState(
                expectedToken: targetToken,
                axRef: targetWindow.axRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: UInt64(468_900 + suffix),
                trigger: .identityRebind(
                    oldWindow: sourceWindow,
                    newWindow: targetWindow,
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                ),
                exhausted: false,
                executionPhase: .waiting
            )
        return PendingFullRescanIdentityRebindFixture(
            controller: controller,
            workspaceId: workspaceId,
            sourceWindow: sourceWindow,
            targetWindow: targetWindow
        )
    }

    private func assertProcessesUntrackedFullRescanCandidate(
        _ fixture: PendingFullRescanIdentityRebindFixture,
        pid: pid_t? = nil,
        axRef: AXWindowRef? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolution = fixture.controller.axEventHandler.resolveFullRescanIdentity(
            axRef: axRef ?? fixture.targetWindow.axRef,
            pid: pid ?? fixture.targetWindow.token.pid,
            windowId: fixture.targetWindow.token.windowId,
            observedAliases: nil
        )
        guard case let .process(entry) = resolution, entry == nil else {
            XCTFail("Expected normal admission processing", file: file, line: line)
            return
        }
    }

    private func candidate(pid: pid_t, windowId: Int) -> FullRescanWindowCandidate {
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
                    frame: CGRect(x: 0, y: 0, width: 640, height: 480)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .persistent
        )
    }

    private func deferCreatedWindow(
        _ token: WindowToken,
        controller: WMController
    ) {
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.processCreatedWindow(windowId: UInt32(token.windowId))
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
    }

    private func replacementBundleId(_ pid: pid_t) -> String {
        "com.omniwm.tests.deferred-replacement.\(pid)"
    }

    private func replacementMetadata(
        bundleId: String,
        workspaceId: WorkspaceDescriptor.ID,
        frame: CGRect
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "replacement",
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
    }

    private func replacementFacts(
        token: WindowToken,
        bundleId: String,
        frame: CGRect
    ) -> WindowRuleFacts {
        WindowRuleFacts(
            appName: "Replacement",
            ax: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "replacement",
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: bundleId,
                attributeFetchSucceeded: true
            ),
            sizeConstraints: nil,
            windowServer: replacementWindowInfo(token: token, frame: frame)
        )
    }

    private func replacementWindowInfo(
        token: WindowToken,
        frame: CGRect
    ) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: frame
        )
    }
}
