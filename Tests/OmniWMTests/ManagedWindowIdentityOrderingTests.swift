// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class IdentityOrderingGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }
}

@MainActor
final class ManagedWindowIdentityOrderingTests: XCTestCase {
    private enum WaitError: Error {
        case timedOut
    }

    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let original: WindowToken
        let predecessor: WindowToken
        let successor: WindowToken
        let refs: [WindowToken: AXWindowRef]
        let handle: WindowHandle
        let node: NiriWindow
        let column: NiriContainer
        let viewport: ViewportState
        let spaceId: UInt64
        let frame: CGRect
        let metadata: ManagedReplacementMetadata

        var handler: AXEventHandler {
            controller.axEventHandler
        }

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        func stop() {
            controller.hasStartedServices = false
            controller.factResolver.stop()
            controller.eventIntake.close()
            handler.resetManagedReplacementState()
            controller.layoutRefreshController.fullRescanEnumerationSnapshotForTests = nil
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            handler.managedWindowIdentityRebindAcknowledgementProvider = nil
            handler.managedWindowIdentityRebindFinalizationProvider = nil
            controller.axManager.cleanup()
        }
    }

    func testSharedSourceRebindWaitsThroughAcknowledgementAndFinalizationAcrossRescans() async throws {
        let fixture = try await makeFixture(suffix: 0)
        let bAcknowledgement = IdentityOrderingGate()
        let bFinalization = IdentityOrderingGate()
        let cAcknowledgement = IdentityOrderingGate()
        defer {
            bAcknowledgement.release()
            bFinalization.release()
            cAcknowledgement.release()
            fixture.stop()
        }
        var calls: [WindowToken] = []
        var sources: [WindowToken] = []
        var bFinalizing = false
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { source, target in
            sources.append(source.token)
            calls.append(target.token)
            await (target.token == fixture.predecessor ? bAcknowledgement : cAcknowledgement).wait()
            return true
        }
        fixture.handler.managedWindowIdentityRebindFinalizationProvider = { _, target in
            if target.token == fixture.predecessor {
                bFinalizing = true
                await bFinalization.wait()
            }
            return true
        }

        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { calls == [fixture.predecessor] }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        let attempt = fixture.handler.admissionRetryStateByWindowId[UInt32(fixture.successor.windowId)]?.attempt
        for _ in 0 ..< 3 {
            XCTAssertTrue(fixture.handler.retryAdmissionAfterFrameChange(windowId: UInt32(fixture.successor.windowId)))
        }
        XCTAssertEqual(
            fixture.handler.admissionRetryStateByWindowId[UInt32(fixture.successor.windowId)]?.attempt,
            attempt
        )
        await rescan(
            fixture,
            selected: fixture.successor,
            visible: [fixture.original, fixture.predecessor, fixture.successor]
        )
        XCTAssertEqual(calls, [fixture.predecessor])
        assertPreservedSource(fixture, target: fixture.successor, expected: fixture.original)
        assertCanonical(fixture, token: fixture.original)

        bAcknowledgement.release()
        try await waitFor { bFinalizing }
        await rescan(fixture, selected: fixture.successor, visible: [fixture.predecessor, fixture.successor])
        XCTAssertEqual(calls, [fixture.predecessor])
        assertPreservedSource(fixture, target: fixture.successor, expected: fixture.predecessor)
        assertCanonical(fixture, token: fixture.predecessor)

        bFinalization.release()
        try await waitFor { calls.count == 2 }
        XCTAssertEqual(calls, [fixture.predecessor, fixture.successor])
        XCTAssertEqual(sources, [fixture.original, fixture.predecessor])
        await rescan(fixture, selected: fixture.successor, visible: [fixture.predecessor, fixture.successor])
        assertCanonical(fixture, token: fixture.predecessor)
        cAcknowledgement.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        assertCanonical(fixture, token: fixture.successor)
    }

    func testFailedPredecessorRetriesBeforeQueuedSuccessor() async throws {
        let fixture = try await makeFixture(suffix: 1)
        let firstAttempt = IdentityOrderingGate()
        let secondAttempt = IdentityOrderingGate()
        defer {
            firstAttempt.release()
            secondAttempt.release()
            fixture.stop()
        }
        var calls: [WindowToken] = []
        var sources: [WindowToken] = []
        var bAttempts = 0
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { source, target in
            sources.append(source.token)
            calls.append(target.token)
            if target.token == fixture.predecessor {
                bAttempts += 1
                let attempt = bAttempts
                await (attempt == 1 ? firstAttempt : secondAttempt).wait()
                return attempt != 1
            }
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { bAttempts == 1 }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        firstAttempt.release()
        try await waitFor { bAttempts == 2 }
        XCTAssertEqual(calls, [fixture.predecessor, fixture.predecessor])
        assertCanonical(fixture, token: fixture.original)
        secondAttempt.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        XCTAssertEqual(calls, [fixture.predecessor, fixture.predecessor, fixture.successor])
        XCTAssertEqual(sources, [fixture.original, fixture.original, fixture.predecessor])
        assertCanonical(fixture, token: fixture.successor)
    }

    func testPromotedWaitingRetryReservesOrderBeforeLaterIdentityRequest() async throws {
        let fixture = try await makeFixture(suffix: 7)
        let acknowledgement = IdentityOrderingGate()
        defer {
            acknowledgement.release()
            fixture.stop()
        }
        var calls: [WindowToken] = []
        var sources: [WindowToken] = []
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { source, target in
            sources.append(source.token)
            calls.append(target.token)
            if target.token == fixture.predecessor { await acknowledgement.wait() }
            return true
        }
        XCTAssertTrue(fixture.handler.scheduleCandidateAdmissionRetry(
            windowId: UInt32(fixture.predecessor.windowId),
            pid: fixture.predecessor.pid,
            axRef: try XCTUnwrap(fixture.refs[fixture.predecessor]),
            reason: .degenerateGeometry
        ))
        try enqueue(fixture.predecessor, from: fixture.original, dispatch: false, fixture: fixture)
        try enqueue(fixture.successor, from: fixture.original, dispatch: false, fixture: fixture)
        let predecessorOrder = try XCTUnwrap(fixture.handler
            .admissionRetryStateByWindowId[UInt32(fixture.predecessor.windowId)]?
            .identityRebindSource?.requestOrder)
        let successorOrder = try XCTUnwrap(fixture.handler
            .admissionRetryStateByWindowId[UInt32(fixture.successor.windowId)]?
            .identityRebindSource?.requestOrder)
        XCTAssertLessThan(predecessorOrder, successorOrder)
        XCTAssertTrue(fixture.handler.retryAdmissionAfterFrameChange(windowId: UInt32(fixture.successor.windowId)))
        XCTAssertTrue(fixture.handler.retryAdmissionAfterFrameChange(windowId: UInt32(fixture.predecessor.windowId)))
        try await waitFor { calls == [fixture.predecessor] }
        assertCanonical(fixture, token: fixture.original)
        acknowledgement.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        XCTAssertEqual(calls, [fixture.predecessor, fixture.successor])
        XCTAssertEqual(sources, [fixture.original, fixture.predecessor])
        assertCanonical(fixture, token: fixture.successor)
    }

    func testCancellationRetainsExecutionOwnershipUntilAcknowledgementUnwinds() async throws {
        let fixture = try await makeFixture(suffix: 2)
        let acknowledgement = IdentityOrderingGate()
        defer {
            acknowledgement.release()
            fixture.stop()
        }
        var calls: [WindowToken] = []
        var sources: [WindowToken] = []
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { source, target in
            sources.append(source.token)
            calls.append(target.token)
            if target.token == fixture.predecessor { await acknowledgement.wait() }
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { calls == [fixture.predecessor] }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        fixture.handler.cancelCreatedWindowRetry(windowId: UInt32(fixture.predecessor.windowId))
        XCTAssertTrue(fixture.handler.retryAdmissionAfterFrameChange(windowId: UInt32(fixture.successor.windowId)))
        await rescan(fixture, selected: fixture.successor, visible: [fixture.original, fixture.successor])
        XCTAssertEqual(calls, [fixture.predecessor])
        assertCanonical(fixture, token: fixture.original)
        acknowledgement.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        XCTAssertEqual(calls, [fixture.predecessor, fixture.successor])
        XCTAssertEqual(sources, [fixture.original, fixture.original])
        assertCanonical(fixture, token: fixture.successor)
    }

    func testDestroyedQueuedTargetNeverStartsOrRemovesCanonicalWindow() async throws {
        let fixture = try await makeFixture(suffix: 3)
        let acknowledgement = IdentityOrderingGate()
        defer {
            acknowledgement.release()
            fixture.stop()
        }
        var calls: [WindowToken] = []
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { _, target in
            calls.append(target.token)
            await acknowledgement.wait()
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { calls == [fixture.predecessor] }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        fixture.handler.handleRemoved(
            pid: fixture.successor.pid,
            winId: fixture.successor.windowId,
            axRef: try XCTUnwrap(fixture.refs[fixture.successor])
        )
        XCTAssertFalse(fixture.handler.activeAdmissionRetryWindowIds.contains(fixture.successor.windowId))
        assertCanonical(fixture, token: fixture.original)
        acknowledgement.release()
        try await waitUntilSettled(fixture.predecessor, fixture: fixture)
        XCTAssertEqual(calls, [fixture.predecessor])
        assertCanonical(fixture, token: fixture.predecessor)
    }

    func testQueuedTargetIncarnationReplacementRejectsOldDestroyAndUsesCurrentSource() async throws {
        let fixture = try await makeFixture(suffix: 4)
        let acknowledgement = IdentityOrderingGate()
        defer {
            acknowledgement.release()
            fixture.stop()
        }
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(fixture.original.pid + 50),
            windowId: fixture.successor.windowId
        )
        var calls: [WindowToken] = []
        var successorSource: WindowToken?
        var successorUsedNewIncarnation = false
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { source, target in
            calls.append(target.token)
            if target.token == fixture.predecessor {
                await acknowledgement.wait()
            } else {
                successorSource = source.token
                successorUsedNewIncarnation = CFEqual(target.axRef.element, replacementRef.element)
            }
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { calls == [fixture.predecessor] }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        try enqueue(fixture.successor, from: fixture.original, axRef: replacementRef, fixture: fixture)
        fixture.handler.handleRemoved(
            pid: fixture.successor.pid,
            winId: fixture.successor.windowId,
            axRef: try XCTUnwrap(fixture.refs[fixture.successor])
        )
        XCTAssertTrue(fixture.handler.activeAdmissionRetryWindowIds.contains(fixture.successor.windowId))
        acknowledgement.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        XCTAssertEqual(calls, [fixture.predecessor, fixture.successor])
        XCTAssertEqual(successorSource, fixture.predecessor)
        XCTAssertTrue(successorUsedNewIncarnation)
        XCTAssertTrue(CFEqual(
            try XCTUnwrap(fixture.manager.entry(for: fixture.successor)).axRef.element,
            replacementRef.element
        ))
        assertCanonical(fixture, token: fixture.successor)
    }

    func testDifferentHandlesInSameProcessCanRebindConcurrently() async throws {
        let fixture = try await makeFixture(suffix: 5)
        let firstAcknowledgement = IdentityOrderingGate()
        let secondAcknowledgement = IdentityOrderingGate()
        defer {
            firstAcknowledgement.release()
            secondAcknowledgement.release()
            fixture.stop()
        }
        let sibling = WindowToken(pid: fixture.original.pid, windowId: fixture.successor.windowId + 1)
        let replacement = WindowToken(pid: fixture.original.pid, windowId: fixture.successor.windowId + 2)
        let siblingRef = WindowAdmissionTestSupport.axRef(for: sibling)
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(fixture.original.pid + 60),
            windowId: replacement.windowId
        )
        _ = fixture.manager.addWindow(
            siblingRef,
            pid: sibling.pid,
            windowId: sibling.windowId,
            to: fixture.workspaceId,
            lifetimeAuthority: .directLifecycle,
            managedReplacementMetadata: fixture.metadata
        )
        let siblingHandle = try XCTUnwrap(fixture.manager.handle(for: sibling))
        var calls: [WindowToken] = []
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { _, target in
            calls.append(target.token)
            await (target.token == fixture.predecessor ? firstAcknowledgement : secondAcknowledgement).wait()
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { calls == [fixture.predecessor] }
        try enqueue(replacement, from: sibling, axRef: replacementRef, fixture: fixture)
        try await waitFor { calls.count == 2 }
        XCTAssertEqual(calls, [fixture.predecessor, replacement])
        secondAcknowledgement.release()
        try await waitUntilSettled(replacement, fixture: fixture)
        XCTAssertTrue(fixture.manager.handle(for: fixture.original) === fixture.handle)
        XCTAssertTrue(fixture.manager.handle(for: replacement) === siblingHandle)
        firstAcknowledgement.release()
        try await waitUntilSettled(fixture.predecessor, fixture: fixture)
        XCTAssertEqual(
            Set(fixture.manager.entries(forPid: fixture.original.pid).map(\.token)),
            [fixture.predecessor, replacement]
        )
        XCTAssertTrue(fixture.manager.handle(for: fixture.predecessor) === fixture.handle)
        XCTAssertTrue(fixture.manager.handle(for: replacement) === siblingHandle)
    }

    func testQueuedFocusContinuationRemainsLiveAndReplaysAfterCanonicalRebind() async throws {
        let fixture = try await makeFixture(suffix: 6)
        let acknowledgement = IdentityOrderingGate()
        defer {
            acknowledgement.release()
            fixture.stop()
        }
        var predecessorStarted = false
        var focusReads: [pid_t] = []
        let successorRef = try XCTUnwrap(fixture.refs[fixture.successor])
        fixture.controller.factResolver.factProvider = { pid in
            focusReads.append(pid)
            return FocusedWindowFact(axRef: successorRef, isFullscreen: false, isSystemModalSurface: false)
        }
        fixture.handler.frontmostApplicationPIDProvider = { fixture.original.pid }
        fixture.controller.eventIntake.open(sink: fixture.controller.eventInterpreter)
        fixture.handler.managedWindowIdentityRebindAcknowledgementProvider = { _, target in
            if target.token == fixture.predecessor {
                predecessorStarted = true
                await acknowledgement.wait()
            }
            return true
        }
        try enqueue(fixture.predecessor, from: fixture.original, fixture: fixture)
        try await waitFor { predecessorStarted }
        try enqueue(fixture.successor, from: fixture.original, fixture: fixture)
        XCTAssertTrue(fixture.handler.retainFocusedAdmissionContinuation(
            .init(
                token: fixture.successor,
                source: .focusedWindowChanged,
                observationGeneration: 0,
                callbackGeneration: nil
            ),
            windowId: UInt32(fixture.successor.windowId)
        ))
        XCTAssertTrue(fixture.handler.hasLiveFocusedAdmissionContinuation(for: fixture.successor))
        XCTAssertTrue(focusReads.isEmpty)
        acknowledgement.release()
        try await waitUntilSettled(fixture.successor, fixture: fixture)
        XCTAssertEqual(focusReads, [fixture.original.pid])
        XCTAssertEqual(fixture.manager.nativeManagedFocusToken, fixture.successor)
        XCTAssertEqual(fixture.manager.borderFocusToken, fixture.successor)
        assertCanonical(fixture, token: fixture.successor)
    }

    private func makeFixture(suffix: Int) async throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ManagedIdentityOrdering")
        let manager = controller.workspaceManager
        let monitorId = UInt32(471_000 + suffix * 100)
        let monitor = Monitor(
            id: .init(displayId: monitorId),
            displayId: monitorId,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Identity Ordering"
        )
        manager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(id: workspaceId)
        controller.motionPolicy.animationsEnabled = false
        controller.niriLayoutHandler.enableNiriLayout()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        controller.axEventHandler.windowSubscriptionProvider = { _ in true }
        let pid = pid_t(monitorId + 1)
        let original = WindowToken(pid: pid, windowId: Int(monitorId + 2))
        let predecessor = WindowToken(pid: pid, windowId: Int(monitorId + 3))
        let successor = WindowToken(pid: pid, windowId: Int(monitorId + 4))
        let refs = Dictionary(uniqueKeysWithValues: [original, predecessor, successor].enumerated()
            .map { index, token in
                (
                    token,
                    AXWindowRef(element: AXUIElementCreateApplication(pid + pid_t(index)), windowId: token.windowId)
                )
            })
        let frame = CGRect(x: 120, y: 80, width: 720, height: 520)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.mitchellh.ghostty",
            workspaceId: workspaceId,
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "replacement",
            windowLevel: 0,
            parentWindowId: nil,
            frame: frame
        )
        _ = manager.addWindow(
            try XCTUnwrap(refs[original]),
            pid: pid,
            windowId: original.windowId,
            to: workspaceId,
            lifetimeAuthority: .directLifecycle,
            managedReplacementMetadata: metadata
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = manager.withEngineMutationScope(in: workspaceId, label: "identity_ordering_fixture") {
            engine.addWindow(token: original, to: workspaceId, afterSelection: nil)
        }
        let column = try XCTUnwrap(engine.column(of: node))
        let handle = try XCTUnwrap(manager.handle(for: original))
        XCTAssertTrue(manager.confirmManagedFocus(original, in: workspaceId, activateWorkspaceOnMonitor: false))
        var viewport = manager.niriViewportState(for: workspaceId)
        viewport.selectedNodeId = node.id
        viewport.activeColumnIndex = try XCTUnwrap(engine.columnIndex(of: column, in: workspaceId))
        manager.updateNiriViewportState(viewport, for: workspaceId)
        let spaceId = UInt64(monitorId + 10)
        manager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: "identity-ordering", spaceIds: [spaceId], currentSpaceId: spaceId)],
            activeSpaceId: spaceId,
            fullscreenSpaceIds: [],
            windowSpace: [original.windowId: spaceId]
        ))
        controller.hasStartedServices = true
        controller.axEventHandler.managedWindowIdentityRebindTargetIsAliveProvider = { $0 == pid }
        controller.axEventHandler.managedWindowIdentityRebindFinalizationProvider = { _, _ in true }
        return Fixture(
            controller: controller, workspaceId: workspaceId, original: original, predecessor: predecessor,
            successor: successor, refs: refs,
            handle: handle, node: node, column: column, viewport: viewport, spaceId: spaceId,
            frame: frame, metadata: metadata
        )
    }

    private func enqueue(
        _ target: WindowToken,
        from source: WindowToken,
        axRef: AXWindowRef? = nil,
        dispatch: Bool = true,
        fixture: Fixture
    ) throws {
        let ref = try XCTUnwrap(axRef ?? fixture.refs[target])
        guard case .pending = fixture.handler.rekeyManagedWindowIdentity(
            from: source,
            to: target,
            windowId: UInt32(target.windowId),
            axRef: ref,
            managedReplacementMetadata: fixture.metadata
        ) else {
            return XCTFail("Expected an asynchronous identity rebind")
        }
        if dispatch {
            XCTAssertTrue(fixture.handler.retryAdmissionAfterFrameChange(windowId: UInt32(target.windowId)))
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(5))
        }
        if !condition() {
            XCTFail("Identity rebind did not reach the expected phase")
            throw WaitError.timedOut
        }
    }

    private func waitUntilSettled(_ token: WindowToken, fixture: Fixture) async throws {
        try await waitFor {
            fixture.manager.entry(for: token) != nil
                && !fixture.handler.activeAdmissionRetryWindowIds.contains(token.windowId)
        }
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
    }

    private func assertPreservedSource(_ fixture: Fixture, target: WindowToken, expected: WindowToken) {
        let resolution = fixture.handler.resolveFullRescanIdentity(
            axRef: fixture.refs[target]!, pid: target.pid, windowId: target.windowId, observedAliases: nil
        )
        guard case let .preserve(source) = resolution else {
            return XCTFail("A pending replacement must preserve the current canonical source")
        }
        XCTAssertEqual(source, expected)
    }

    private func assertCanonical(_ fixture: Fixture, token: WindowToken) {
        XCTAssertEqual(fixture.manager.entries(forPid: fixture.original.pid).map(\.token), [token])
        XCTAssertTrue(fixture.manager.handle(for: token) === fixture.handle)
        XCTAssertEqual(fixture.manager.entry(for: token)?.workspaceId, fixture.workspaceId)
        XCTAssertTrue(fixture.controller.niriEngine?.findNode(for: token, in: fixture.workspaceId) === fixture.node)
        XCTAssertTrue(fixture.controller.niriEngine?.column(of: fixture.node) === fixture.column)
        XCTAssertEqual(fixture.controller.niriEngine?.columns(in: fixture.workspaceId).count, 1)
        XCTAssertEqual(fixture.manager.selectedManagedToken, token)
        let viewport = fixture.manager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(viewport.selectedNodeId, fixture.viewport.selectedNodeId)
        XCTAssertEqual(viewport.activeColumnIndex, fixture.viewport.activeColumnIndex)
        XCTAssertEqual(viewport.viewOffset, fixture.viewport.viewOffset)
        XCTAssertEqual(fixture.manager.spaceTopology.spaceForWindow(token.windowId), fixture.spaceId)
    }

    private func rescan(_ fixture: Fixture, selected: WindowToken, visible: [WindowToken]) async {
        func info(_ token: WindowToken) -> WindowServerInfo {
            WindowServerInfo(id: UInt32(token.windowId), pid: token.pid, level: 0, frame: fixture.frame)
        }
        let facts = AXWindowFacts(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
            title: "replacement", hasCloseButton: true, hasFullscreenButton: true,
            fullscreenButtonEnabled: true, hasZoomButton: true, hasMinimizeButton: true,
            appPolicy: .regular, bundleId: "com.mitchellh.ghostty", attributeFetchSucceeded: true
        )
        let ref = fixture.refs[selected]!
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: ref, axPid: selected.pid, role: facts.role, subrole: facts.subrole,
                admissionGeometry: .init(isSizeSettable: true, frame: fixture.frame), fullscreenAttribute: false,
                decisionEvidence: .init(facts: facts, sizeConstraints: .unconstrained)
            ),
            logicalPID: selected.pid, windowServerInfo: info(selected), windowServerOwnerPID: selected.pid,
            enumerationRoute: .persistent
        )
        fixture.controller.layoutRefreshController.fullRescanEnumerationSnapshotForTests = .init(
            windows: [candidate], successfullyEnumeratedPIDs: [selected.pid], failedPIDs: [],
            authoritativeTargetPIDs: [selected.pid], exactWindowIds: nil,
            identityAliasesByWindowId: [selected.windowId: .init(pids: [selected.pid], axRefs: [ref])],
            windowServerInfoByWindowId: Dictionary(uniqueKeysWithValues: visible.map { ($0.windowId, info($0)) })
        )
        fixture.controller.layoutRefreshController.requestFullRescan(
            reason: .appRulesChanged, scope: .targeted(appPIDs: [selected.pid], nativeSpaceIds: [])
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
    }
}
