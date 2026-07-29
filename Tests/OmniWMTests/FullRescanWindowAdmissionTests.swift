// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

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
        XCTAssertTrue(controller.workspaceManager.focusedHandle === originalHandle)

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
        XCTAssertTrue(controller.workspaceManager.focusedHandle === originalHandle)
        XCTAssertEqual(controller.workspaceManager.focusedToken, newToken)
        XCTAssertEqual(controller.workspaceManager.allEntries().count, 1)
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
            controller.workspaceManager.confirmedMissingEntries(
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
                    capturedWindowServerInfoByWindowId: [
                        newToken.windowId: replacementWindowInfo(token: newToken, frame: matchingFrame)
                    ],
                    entry: nil,
                    seenKeys: &seenKeys
                )
        )
        XCTAssertEqual(seenKeys, [oldToken])
        let missingEntries = controller.workspaceManager.confirmedMissingEntries(
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
                    capturedWindowServerInfoByWindowId: [:],
                    entry: nil,
                    seenKeys: &rejectedSeenKeys
                )
        )
        XCTAssertTrue(rejectedSeenKeys.isEmpty)
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
            controller.workspaceManager.confirmedMissingEntries(
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
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: newFrame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        XCTAssertTrue(seenKeys.isEmpty)
        XCTAssertEqual(
            controller.workspaceManager.confirmedMissingEntries(
                keys: seenKeys,
                requiredConsecutiveMisses: 2
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
            controller.workspaceManager.confirmedMissingEntries(
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
                capturedWindowServerInfoByWindowId: [
                    newToken.windowId: replacementWindowInfo(token: newToken, frame: frame)
                ],
                entry: nil,
                seenKeys: &seenKeys
            )
        )

        XCTAssertTrue(seenKeys.isEmpty)
        XCTAssertEqual(
            Set(
                controller.workspaceManager.confirmedMissingEntries(
                    keys: seenKeys,
                    requiredConsecutiveMisses: 2
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
