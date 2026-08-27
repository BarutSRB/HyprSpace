// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ScratchpadRevealTests: XCTestCase {
    func testAssignParksEachWindowAndSlotHoldsThemAll() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_001, windowId: 971_101, to: fixture)
        let second = addFloatingWindow(pid: 971_002, windowId: 971_102, to: fixture)

        XCTAssertEqual(assign(first, to: 1, in: fixture), .executed)
        XCTAssertEqual(assign(second, to: 1, in: fixture), .executed)

        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadMembers(in: 1), [first, second])
        for token in [first, second] {
            XCTAssertEqual(
                fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
                true
            )
        }
    }

    func testAssigningAMemberToItsOwnSlotReturnsItToTheLayout() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_011, windowId: 971_111, to: fixture)
        XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        fixture.controller.workspaceManager.setHiddenState(nil, for: token)

        XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)

        XCTAssertNil(fixture.controller.workspaceManager.scratchpadIndex(for: token))
        XCTAssertTrue(fixture.controller.workspaceManager.scratchpadMembers(in: 1).isEmpty)
    }

    func testAssigningToAnotherSlotMovesTheWindow() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_021, windowId: 971_121, to: fixture)
        XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)

        XCTAssertEqual(assign(token, to: 8, in: fixture), .executed)

        XCTAssertTrue(fixture.controller.workspaceManager.scratchpadMembers(in: 1).isEmpty)
        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadMembers(in: 8), [token])
    }

    func testEmptySlotToggleIsNotFound() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(fixture.controller.toggleScratchpad(9), .notFound)
        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
    }

    func testRevealingASlotParksTheSlotThatWasShowing() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_031, windowId: 971_131, to: fixture)
        let second = addFloatingWindow(pid: 971_032, windowId: 971_132, to: fixture)
        XCTAssertEqual(assign(first, to: 1, in: fixture), .executed)
        XCTAssertEqual(assign(second, to: 2, in: fixture), .executed)

        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 1)
        try completeReveal(first, in: fixture)

        XCTAssertEqual(fixture.controller.toggleScratchpad(2), .executed)

        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 2)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: first)?.isScratchpad,
            true
        )
    }

    func testTogglingTheRevealedSlotParksItAgain() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_041, windowId: 971_141, to: fixture)
        XCTAssertEqual(assign(token, to: 3, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        try completeReveal(token, in: fixture)

        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
    }

    func testBarToggleOffDoesNotRequestUnhideForHiddenMember() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_042, windowId: 971_142, to: fixture)
        XCTAssertEqual(assign(token, to: 3, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        try completeReveal(token, in: fixture)
        fixture.controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .service)
        AppVisibilityTrace.shared.beginCapture()
        defer { AppVisibilityTrace.shared.endCapture() }

        XCTAssertEqual(
            fixture.controller.activateScratchpadFromBar(index: 3, on: fixture.monitor.id),
            .executed
        )

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertTrue(fixture.controller.workspaceManager.isAppHidden(pid: token.pid))
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
        XCTAssertNil(fixture.controller.intentLedger.openAppRevealFocusIntent(pid: token.pid))
        XCTAssertFalse(
            AppVisibilityTrace.shared.dump().contains("event=reveal pid=\(token.pid)")
        )
    }

    func testRevealedMembersFollowTheActiveWorkspace() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_051, windowId: 971_151, to: fixture)
        XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(token, in: fixture)

        let second = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        fixture.controller.rehomeRevealedScratchpad(activeWorkspaceIds: [second])

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), second)
    }

    func testParkedMembersDoNotFollowTheActiveWorkspace() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_061, windowId: 971_161, to: fixture)
        XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        let parkedWorkspace = fixture.controller.workspaceManager.workspace(for: token)

        let second = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        fixture.controller.rehomeRevealedScratchpad(activeWorkspaceIds: [second])

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), parkedWorkspace)
    }

    func testThreeMemberRevealCompletesAsOneGroupOutOfOrder() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_071, windowId: 971_171, to: fixture)
        let second = addFloatingWindow(pid: 971_072, windowId: 971_172, to: fixture)
        let third = addFloatingWindow(pid: 971_073, windowId: 971_173, to: fixture)
        for token in [first, second, third] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()

        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)

        try completeReveal(third, in: fixture)
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        try completeReveal(first, in: fixture)
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        try completeReveal(second, in: fixture, completeFronting: false)

        for token in [first, second, third] {
            XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: token))
        }
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        XCTAssertTrue(fixture.focusRecorder.orderedWindowIds.isEmpty)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        try confirmScratchpadFrontingStage(
            first,
            source: .focusedWindowChanged,
            in: fixture
        )
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        fixture.controller.noteScratchpadStackingAppActivation(
            pid: second.pid,
            source: .workspaceDidActivateApplication
        )
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        fixture.controller.noteScratchpadStackingAppActivation(
            pid: first.pid,
            source: .workspaceDidActivateApplication
        )
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(second.windowId)]
        )
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        fixture.controller.noteScratchpadStackingAppActivation(
            pid: second.pid,
            source: .workspaceDidActivateApplication
        )
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(second.windowId)]
        )
        try confirmScratchpadFrontingStage(
            second,
            source: .focusedWindowChanged,
            in: fixture
        )
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(second.windowId), UInt32(third.windowId)]
        )
        XCTAssertEqual(
            fixture.controller.intentLedger.activeManagedRequest?.origin,
            .keyboardOrProgrammatic
        )
        try confirmScratchpadFrontingStage(third, in: fixture)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testStackingContinuationAbortsWhenAnotherAppBecomesFrontmost() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_074, windowId: 971_174, to: fixture)
        let second = addFloatingWindow(pid: 971_075, windowId: 971_175, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        var continuations: [@MainActor () -> Void] = []
        fixture.controller.scheduleScratchpadStackingContinuation = { continuation in
            continuations.append(continuation)
        }
        fixture.focusRecorder.reset()

        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])

        try confirmScratchpadFrontingStage(first, in: fixture)
        XCTAssertEqual(continuations.count, 1)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])

        fixture.focusRecorder.frontmostPID = 971_999
        continuations.removeFirst()()

        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testStackingContinuationAbortsForSameAppDifferentWindowFocus() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_074, windowId: 971_181, to: fixture)
        let second = addFloatingWindow(pid: 971_075, windowId: 971_182, to: fixture)
        let external = addFloatingWindow(pid: 971_074, windowId: 971_183, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        var continuations: [@MainActor () -> Void] = []
        fixture.controller.scheduleScratchpadStackingContinuation = { continuation in
            continuations.append(continuation)
        }
        fixture.focusRecorder.reset()

        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        try confirmScratchpadFrontingStage(first, in: fixture)
        XCTAssertEqual(continuations.count, 1)

        XCTAssertTrue(
            fixture.controller.workspaceManager.setManagedFocus(
                external,
                in: fixture.workspaceId,
                onMonitor: fixture.monitor.id
            )
        )
        fixture.focusRecorder.frontmostPID = external.pid
        continuations.removeFirst()()

        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testSameAppMembersAreFrontedIndividually() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_076, windowId: 971_176, to: fixture)
        let second = addFloatingWindow(pid: 971_076, windowId: 971_177, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()

        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])

        try confirmScratchpadFrontingStage(first, in: fixture)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(second.windowId)]
        )
        try confirmScratchpadFrontingStage(
            second,
            source: .focusedWindowChanged,
            in: fixture
        )

        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testStackingRetryExhaustionAdvancesToNextMember() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_077, windowId: 971_178, to: fixture)
        let second = addFloatingWindow(pid: 971_078, windowId: 971_179, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        let exhaustedRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
        fixture.controller.hasStartedServices = true
        defer { fixture.controller.hasStartedServices = false }

        for _ in 0 ... AXEventHandler.activationRetryLimit {
            fixture.controller.axEventHandler.handleActivationFactsResolved(
                ActivationFacts(
                    pid: first.pid,
                    source: .focusedWindowChanged,
                    origin: .retry,
                    observationGeneration: 0,
                    requestedAtSeq: UInt64.max,
                    focusedWindow: nil
                )
            )
        }

        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(second.windowId)]
        )
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: exhaustedRequestId)?.phase, .cancelled)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, second)
    }

    func testStackingSupersessionKeepsReplacementFocusAuthoritative() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_079, windowId: 971_180, to: fixture)
        let second = addFloatingWindow(pid: 971_080, windowId: 971_181, to: fixture)
        let replacement = addFloatingWindow(pid: 971_081, windowId: 971_182, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        let stackingRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )

        let replacementRequest = try XCTUnwrap(fixture.controller.focusWindow(replacement))

        XCTAssertEqual(fixture.controller.intentLedger.intent(id: stackingRequestId)?.phase, .superseded)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, replacementRequest.requestId)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(replacement.windowId)]
        )
        try confirmScratchpadFrontingStage(replacement, in: fixture)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(replacement.windowId)]
        )
    }

    func testStackingSameTokenRefocusKeepsExplicitFocusAuthoritative() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_083, windowId: 971_183, to: fixture)
        let second = addFloatingWindow(pid: 971_084, windowId: 971_184, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        let stackingRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )

        let explicitRequest = try XCTUnwrap(fixture.controller.focusWindow(first))

        XCTAssertEqual(explicitRequest.requestId, stackingRequestId)
        try confirmScratchpadFrontingStage(first, in: fixture)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(first.windowId)]
        )
    }

    func testNativeFullscreenPlaceholderFocusAbortsStacking() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_085, windowId: 971_185, to: fixture)
        let second = addFloatingWindow(pid: 971_086, windowId: 971_186, to: fixture)
        let fullscreen = addFloatingWindow(pid: 971_087, windowId: 971_187, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        let stackingRequest = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(
            fixture.controller.workspaceManager.markNativeFullscreenSuspended(
                fullscreen,
                ownsNonManagedFocus: false
            )
        )

        XCTAssertNil(fixture.controller.focusWindow(fullscreen))

        XCTAssertEqual(fixture.controller.workspaceManager.nonManagedFocusToken, fullscreen)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(
            fixture.controller.intentLedger.intent(id: stackingRequest.requestId)?.phase,
            .cancelled
        )
        fixture.controller.axEventHandler.handleIntentExpired(stackingRequest.requestId)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(first.windowId)])
    }

    func testDeferredDwindleGroupFocusAbortsStacking() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.workspaceConfigurations = fixture.controller.settings.workspaceConfigurations.map {
            $0.name == "1" ? $0.with(layoutType: .dwindle) : $0
        }
        fixture.controller.workspaceManager.applySettings()
        fixture.controller.dwindleLayoutHandler.enableDwindleLayout()
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let inactive = addTilingWindow(pid: 971_088, windowId: 971_188, to: fixture)
        let active = addTilingWindow(pid: 971_089, windowId: 971_189, to: fixture)
        fixture.controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: inactive, to: fixture.workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: active, to: fixture.workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: fixture.workspaceId, screen: fixture.monitor.visibleFrame)
            XCTAssertTrue(engine.groupWindow(direction: .left, in: fixture.workspaceId))
            _ = engine.calculateLayout(for: fixture.workspaceId, screen: fixture.monitor.visibleFrame)
        }
        fixture.controller.layoutRefreshController.resetState()
        XCTAssertEqual(engine.activeToken(in: fixture.workspaceId), active)

        let first = addFloatingWindow(pid: 971_090, windowId: 971_190, to: fixture)
        let second = addFloatingWindow(pid: 971_091, windowId: 971_191, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture, completeFronting: false)
        let stackingRequestId = try XCTUnwrap(
            fixture.controller.intentLedger.activeManagedRequest?.requestId
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.withEngineMutationScope {
                engine.activateWindowOutcome(active, in: fixture.workspaceId)
            },
            .activated
        )
        let inactiveEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: inactive))
        let group = try XCTUnwrap(engine.tileSnapshot(for: inactive, in: fixture.workspaceId))
        XCTAssertEqual(inactiveEntry.mode, .tiling)
        XCTAssertEqual(inactiveEntry.layoutReason, .standard)
        XCTAssertEqual(fixture.controller.workspaceManager.activeLayoutKind(for: fixture.workspaceId), .dwindle)
        XCTAssertEqual(
            fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            fixture.workspaceId
        )
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.activeToken, active)
        let blocker = blockLayoutRefresh(fixture)
        defer { unblockLayoutRefresh(fixture, blocker: blocker) }

        XCTAssertNil(fixture.controller.focusWindow(inactive))

        XCTAssertEqual(engine.activeToken(in: fixture.workspaceId), inactive)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(fixture.controller.intentLedger.intent(id: stackingRequestId)?.phase, .cancelled)
        let postLayout = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, inactive)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds.last, UInt32(inactive.windowId))
        XCTAssertFalse(fixture.focusRecorder.focusedWindowIds.contains(UInt32(second.windowId)))
    }

    func testRehomeWaitsForWorkspaceFocusHandoffBeforeRestacking() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_077, windowId: 971_178, to: fixture)
        let second = addFloatingWindow(pid: 971_078, windowId: 971_179, to: fixture)
        let workspaceFocus = addFloatingWindow(pid: 971_079, windowId: 971_180, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 1, in: fixture), .executed)
        }
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        try completeReveal(first, in: fixture)
        try completeReveal(second, in: fixture)

        let secondWorkspace = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        fixture.controller.reassignManagedWindow(workspaceFocus, to: secondWorkspace)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")
        fixture.controller.rehomeRevealedScratchpad(activeWorkspaceIds: [secondWorkspace])
        fixture.focusRecorder.reset()

        fixture.controller.focusWindow(workspaceFocus)
        fixture.focusRecorder.frontmostPID = nil
        fixture.controller.resumeRehomedScratchpadStackingAfterFocusHandoff()
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(workspaceFocus.windowId)]
        )

        try confirmScratchpadFrontingStage(
            workspaceFocus,
            source: .focusedWindowChanged,
            in: fixture
        )
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(workspaceFocus.windowId)]
        )

        fixture.focusRecorder.frontmostPID = workspaceFocus.pid
        fixture.controller.noteScratchpadStackingAppActivation(
            pid: workspaceFocus.pid,
            source: .workspaceDidActivateApplication
        )
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(workspaceFocus.windowId), UInt32(first.windowId)]
        )

        try confirmScratchpadFrontingStage(first, in: fixture)
        try confirmScratchpadFrontingStage(second, in: fixture)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [
                UInt32(workspaceFocus.windowId),
                UInt32(first.windowId),
                UInt32(second.windowId)
            ]
        )
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testExternalInvalidationStillReparksEveryGroupMember() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_081, windowId: 971_181, to: fixture)
        let second = addFloatingWindow(pid: 971_082, windowId: 971_182, to: fixture)
        let third = addFloatingWindow(pid: 971_083, windowId: 971_183, to: fixture)
        for token in [first, second, third] {
            XCTAssertEqual(assign(token, to: 2, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(2), .executed)
        let transactionIds = try Dictionary(
            uniqueKeysWithValues: [first, second, third].map { token in
                (
                    token,
                    try XCTUnwrap(
                        fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                            forWindowId: token.windowId
                        )
                    )
                )
            }
        )
        _ = fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")

        for token in [third, first, second] {
            try completeReveal(
                token,
                in: fixture,
                transactionId: XCTUnwrap(transactionIds[token])
            )
        }

        for token in [first, second, third] {
            XCTAssertEqual(
                fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
                true
            )
        }
        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        XCTAssertTrue(fixture.focusRecorder.orderedWindowIds.isEmpty)
    }

    func testCancellationDiscardsGroupCompletion() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_091, windowId: 971_191, to: fixture)
        let second = addFloatingWindow(pid: 971_092, windowId: 971_192, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 4, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)

        fixture.controller.layoutRefreshController.cancelPendingScratchpadReveal(for: first)
        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        try completeReveal(second, in: fixture)

        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        XCTAssertTrue(fixture.focusRecorder.orderedWindowIds.isEmpty)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: first)?.isScratchpad,
            true
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: second)?.isScratchpad,
            true
        )
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 4)
    }

    func testResetClearsRevealedSlotWhenEveryMemberIsStillPending() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_093, windowId: 971_193, to: fixture)
        let second = addFloatingWindow(pid: 971_094, windowId: 971_194, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 4, in: fixture), .executed)
        }
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)

        fixture.controller.layoutRefreshController.resetState()

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        for token in [first, second] {
            XCTAssertNil(
                fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                    forWindowId: token.windowId
                )
            )
        }
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 4)
    }

    func testResetKeepsRevealedSlotWhenAVisibleMemberSurvives() throws {
        let fixture = try makeFixture()
        let visible = addFloatingWindow(pid: 971_095, windowId: 971_195, to: fixture)
        let pending = addFloatingWindow(pid: 971_096, windowId: 971_196, to: fixture)
        for token in [visible, pending] {
            XCTAssertEqual(assign(token, to: 4, in: fixture), .executed)
        }
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)
        try completeReveal(visible, in: fixture, completeFronting: false)

        fixture.controller.layoutRefreshController.resetState()

        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 4)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: visible))
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: pending)?.isScratchpad,
            true
        )
    }

    func testPartialFailureFocusesOnlyTheSurvivingMember() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_101, windowId: 971_201, to: fixture)
        let second = addFloatingWindow(pid: 971_102, windowId: 971_202, to: fixture)
        let third = addFloatingWindow(pid: 971_103, windowId: 971_203, to: fixture)
        for token in [first, second, third] {
            XCTAssertEqual(assign(token, to: 5, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(5), .executed)

        try completeReveal(third, in: fixture, failureReason: .contextUnavailable)
        try completeReveal(first, in: fixture, failureReason: .contextUnavailable)
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        try completeReveal(second, in: fixture)

        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(second.windowId)])
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: first)?.isScratchpad,
            true
        )
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: second))
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: third)?.isScratchpad,
            true
        )
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 5)
    }

    func testTotalFailureClearsOptimisticRevealedSlot() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_111, windowId: 971_211, to: fixture)
        let second = addFloatingWindow(pid: 971_112, windowId: 971_212, to: fixture)
        for token in [first, second] {
            XCTAssertEqual(assign(token, to: 6, in: fixture), .executed)
        }
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)

        try completeReveal(first, in: fixture, failureReason: .contextUnavailable)
        try completeReveal(second, in: fixture, failureReason: .contextUnavailable)

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        for token in [first, second] {
            XCTAssertEqual(
                fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
                true
            )
        }
    }

    func testPartialParkingClearsSlotAndAllowsAnotherSlot() throws {
        let fixture = try makeFixture()
        let parked = addFloatingWindow(pid: 971_113, windowId: 971_213, to: fixture)
        let unparked = addFloatingWindow(pid: 971_114, windowId: 971_214, to: fixture)
        let replacement = addFloatingWindow(pid: 971_115, windowId: 971_215, to: fixture)
        XCTAssertEqual(assign(parked, to: 6, in: fixture), .executed)
        XCTAssertEqual(assign(unparked, to: 6, in: fixture), .executed)
        XCTAssertEqual(assign(replacement, to: 7, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)
        try completeReveal(parked, in: fixture)
        try completeReveal(unparked, in: fixture)
        _ = fixture.controller.workspaceManager.cancelCurrentManagedFocusRequest()
        _ = fixture.controller.workspaceManager.setManagedFocus(
            unparked,
            in: fixture.workspaceId,
            onMonitor: fixture.monitor.id
        )
        XCTAssertEqual(fixture.controller.workspaceManager.focusedToken, unparked)
        fixture.controller.workspaceManager.setInteractionPolicy(
            WindowInteractionPolicy(
                tracksInModel: true,
                mayFocus: true,
                mayActivateApp: true,
                mayRaise: true,
                mayOrder: true,
                mayWriteFrame: true,
                mayBorder: true,
                mayPark: false
            ),
            for: unparked
        )

        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: parked)?.isScratchpad,
            true
        )
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: unparked))
        XCTAssertEqual(fixture.controller.toggleScratchpad(7), .executed)
        try completeReveal(replacement, in: fixture)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 7)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: replacement))
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: unparked))
    }

    func testUnavailableParkingLeavesFailedMemberRevealableAndRetryable() throws {
        let fixture = try makeFixture()
        let parked = addFloatingWindow(pid: 971_116, windowId: 971_216, to: fixture)
        let unavailable = addFloatingWindow(pid: 971_117, windowId: 971_217, to: fixture)
        for token in [parked, unavailable] {
            XCTAssertEqual(assign(token, to: 6, in: fixture), .executed)
        }
        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)
        try completeReveal(parked, in: fixture)
        try completeReveal(unavailable, in: fixture)
        fixture.controller.axManager.invalidateAppliedFrame(for: unavailable.windowId)
        fixture.controller.axManager.markParkPending(
            for: unavailable.windowId,
            pid: unavailable.pid
        )
        XCTAssertTrue(
            fixture.controller.axManager.pendingParkWindowIds.contains(unavailable.windowId)
        )
        fixture.controller.layoutRefreshController.fastFrameProvider = { token, _ in
            token == unavailable ? nil : CGRect(x: 120, y: 80, width: 900, height: 620)
        }

        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)

        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: parked)?.isScratchpad,
            true
        )
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: unavailable))
        XCTAssertFalse(
            fixture.controller.axManager.pendingParkWindowIds.contains(unavailable.windowId)
        )
        fixture.controller.layoutRefreshController.fastFrameProvider = { _, _ in
            CGRect(x: 120, y: 80, width: 900, height: 620)
        }

        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)
        try completeReveal(parked, in: fixture)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 6)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: unavailable))
        XCTAssertEqual(fixture.controller.toggleScratchpad(6), .executed)
        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        for token in [parked, unavailable] {
            XCTAssertEqual(
                fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
                true
            )
        }
    }

    func testAdoptionDetachesExistingTransactionFromPriorGroup() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_121, windowId: 971_221, to: fixture)
        XCTAssertEqual(assign(token, to: 7, in: fixture), .executed)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        let hiddenState = try XCTUnwrap(fixture.controller.workspaceManager.hiddenState(for: token))
        var priorGroupCompletions = 0
        let priorGroupId = fixture.controller.layoutRefreshController.beginScratchpadRevealGroup(index: 7) { _ in
            priorGroupCompletions += 1
        }
        let transactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: CGRect(x: 120, y: 80, width: 900, height: 620),
                monitor: fixture.monitor,
                revealGroupId: priorGroupId
            )
        )
        fixture.controller.layoutRefreshController.sealScratchpadRevealGroup(priorGroupId)
        fixture.focusRecorder.reset()

        XCTAssertEqual(fixture.controller.toggleScratchpad(7), .executed)
        XCTAssertEqual(priorGroupCompletions, 1)
        XCTAssertEqual(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: token.windowId
            ),
            transactionId
        )
        try completeReveal(token, in: fixture, transactionId: transactionId)

        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: token))
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(token.windowId)])
    }

    func testRekeyedTransactionStillCompletesItsGroup() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_131, windowId: 971_231, to: fixture)
        XCTAssertEqual(assign(token, to: 8, in: fixture), .executed)
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(8), .executed)
        let transactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: token.windowId
            )
        )
        let rekeyed = WindowToken(pid: token.pid, windowId: 971_232)
        let newAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(rekeyed.pid),
            windowId: rekeyed.windowId
        )
        let entry = try XCTUnwrap(
            fixture.controller.workspaceManager.rekeyWindow(
                from: token,
                to: rekeyed,
                newAXRef: newAXRef
            )
        )
        fixture.controller.layoutRefreshController.rekeyPendingRevealTransaction(
            from: token,
            to: rekeyed,
            entry: entry
        )

        try completeReveal(rekeyed, in: fixture, transactionId: transactionId)

        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: rekeyed))
        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadMembers(in: 8), [rekeyed])
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(rekeyed.windowId)])
    }

    func testSupersededGroupCannotStealFocusFromNewSlot() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_141, windowId: 971_241, to: fixture)
        let second = addFloatingWindow(pid: 971_142, windowId: 971_242, to: fixture)
        let replacement = addFloatingWindow(pid: 971_143, windowId: 971_243, to: fixture)
        XCTAssertEqual(assign(first, to: 1, in: fixture), .executed)
        XCTAssertEqual(assign(second, to: 1, in: fixture), .executed)
        XCTAssertEqual(assign(replacement, to: 2, in: fixture), .executed)
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        let firstTransactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: first.windowId
            )
        )
        let secondTransactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: second.windowId
            )
        )

        XCTAssertEqual(fixture.controller.toggleScratchpad(2), .executed)
        try completeReveal(replacement, in: fixture)
        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(replacement.windowId)])
        try completeReveal(first, in: fixture, transactionId: firstTransactionId)
        try completeReveal(second, in: fixture, transactionId: secondTransactionId)

        XCTAssertEqual(fixture.focusRecorder.focusedWindowIds, [UInt32(replacement.windowId)])
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 2)
        for token in [first, second] {
            XCTAssertEqual(
                fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
                true
            )
        }
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: replacement))
    }

    func testSameSlotToggleCancelsPendingGroupWithoutLateFocus() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_151, windowId: 971_251, to: fixture)
        XCTAssertEqual(assign(token, to: 3, in: fixture), .executed)
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        let transactionId = try XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: token.windowId
            )
        )

        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        XCTAssertNil(fixture.controller.workspaceManager.revealedScratchpadIndex())
        try completeReveal(token, in: fixture, transactionId: transactionId)

        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
    }

    func testAppHiddenLogicalParkPreservesGeometryAndReparksOnUnhide() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_161, windowId: 971_261, to: fixture)
        XCTAssertEqual(assign(token, to: 9, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(9), .executed)
        try completeReveal(token, in: fixture)
        let storedFrame = CGRect(x: 380, y: 240, width: 720, height: 540)
        fixture.controller.workspaceManager.setFloatingState(
            FloatingState(
                lastFrame: storedFrame,
                normalizedOrigin: CGPoint(x: 0.15, y: 0.12),
                referenceMonitorId: fixture.monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        fixture.controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .service)

        XCTAssertEqual(fixture.controller.toggleScratchpad(9), .executed)

        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.floatingState(for: token)?.lastFrame,
            storedFrame
        )
        fixture.controller.workspaceManager.setAppHidden(false, pid: token.pid, source: .service)
        fixture.controller.reconcileScratchpadMembersAfterAppUnhide(pid: token.pid)

        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.floatingState(for: token)?.lastFrame,
            storedFrame
        )
    }

    func testPolicyDeniedWindowCannotJoinScratchpad() throws {
        let fixture = try makeFixture()
        let policy = WindowInteractionPolicy(
            tracksInModel: true,
            mayFocus: true,
            mayActivateApp: true,
            mayRaise: true,
            mayOrder: true,
            mayWriteFrame: true,
            mayBorder: true,
            mayPark: false
        )
        let token = addFloatingWindow(
            pid: 971_171,
            windowId: 971_271,
            interactionPolicy: policy,
            to: fixture
        )

        XCTAssertEqual(assign(token, to: 1, in: fixture), .notFound)
        XCTAssertNil(fixture.controller.workspaceManager.scratchpadIndex(for: token))
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: token))
    }

    func testExplicitSelectionAdoptsInFlightGroupAndKeepsSlotRevealed() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_181, windowId: 971_281, to: fixture)
        let selected = addFloatingWindow(pid: 971_182, windowId: 971_282, to: fixture)
        XCTAssertEqual(assign(first, to: 1, in: fixture), .executed)
        XCTAssertEqual(assign(selected, to: 1, in: fixture), .executed)
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(1), .executed)
        let initialTransactionIds = try Dictionary(
            uniqueKeysWithValues: [first, selected].map { token in
                (
                    token,
                    try XCTUnwrap(
                        fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                            forWindowId: token.windowId
                        )
                    )
                )
            }
        )

        XCTAssertEqual(
            fixture.controller.revealScratchpadWindow(selected, index: 1, on: nil),
            .executed
        )
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 1)
        for token in [first, selected] {
            XCTAssertEqual(
                fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                    forWindowId: token.windowId
                ),
                initialTransactionIds[token]
            )
        }

        try completeReveal(selected, in: fixture)
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 1)
        try completeReveal(first, in: fixture)

        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 1)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(selected.windowId)]
        )
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: first))
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: selected))
    }

    func testExplicitSelectionRelocationCancelsAndReissuesInFlightGroup() throws {
        let fixture = try makeFixture()
        let first = addFloatingWindow(pid: 971_191, windowId: 971_291, to: fixture)
        let selected = addFloatingWindow(pid: 971_192, windowId: 971_292, to: fixture)
        XCTAssertEqual(assign(first, to: 2, in: fixture), .executed)
        XCTAssertEqual(assign(selected, to: 2, in: fixture), .executed)
        fixture.focusRecorder.reset()
        XCTAssertEqual(fixture.controller.toggleScratchpad(2), .executed)
        let oldTransactionIds = try Dictionary(
            uniqueKeysWithValues: [first, selected].map { token in
                (
                    token,
                    try XCTUnwrap(
                        fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                            forWindowId: token.windowId
                        )
                    )
                )
            }
        )
        let secondWorkspace = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")

        XCTAssertEqual(
            fixture.controller.revealScratchpadWindow(selected, index: 2, on: nil),
            .executed
        )
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 2)
        for token in [first, selected] {
            XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), secondWorkspace)
            XCTAssertNotEqual(
                fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                    forWindowId: token.windowId
                ),
                oldTransactionIds[token]
            )
        }

        for token in [first, selected] {
            try completeReveal(
                token,
                in: fixture,
                transactionId: XCTUnwrap(oldTransactionIds[token])
            )
        }
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
        try completeReveal(first, in: fixture)
        try completeReveal(selected, in: fixture)

        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 2)
        XCTAssertEqual(
            fixture.focusRecorder.focusedWindowIds,
            [UInt32(first.windowId), UInt32(selected.windowId)]
        )
    }

    func testLogicalParkedMemberRelocatesAndRehomesWithVisibleSibling() throws {
        let fixture = try makeFixture()
        let visible = addFloatingWindow(pid: 971_201, windowId: 971_301, to: fixture)
        let appHidden = addFloatingWindow(pid: 971_202, windowId: 971_302, to: fixture)
        XCTAssertEqual(assign(visible, to: 3, in: fixture), .executed)
        XCTAssertEqual(assign(appHidden, to: 3, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        try completeReveal(visible, in: fixture)
        try completeReveal(appHidden, in: fixture)
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: appHidden.pid,
            source: .service
        )
        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: appHidden)?.isScratchpad,
            true
        )
        let secondWorkspace = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        )
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "2")

        XCTAssertEqual(fixture.controller.toggleScratchpad(3), .executed)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: visible), secondWorkspace)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: appHidden), secondWorkspace)
        try completeReveal(visible, in: fixture)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: visible))
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: appHidden)?.isScratchpad,
            true
        )

        let thirdWorkspace = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "3", createIfMissing: true)
        )
        _ = fixture.controller.workspaceManager.focusWorkspace(named: "3")
        fixture.controller.rehomeRevealedScratchpad(activeWorkspaceIds: [thirdWorkspace])

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: visible), thirdWorkspace)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: appHidden), thirdWorkspace)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: appHidden)?.isScratchpad,
            true
        )
        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: appHidden.pid,
            source: .service
        )
        fixture.controller.reconcileScratchpadMembersAfterAppUnhide(pid: appHidden.pid)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: appHidden)?.isScratchpad,
            true
        )
        try completeReveal(appHidden, in: fixture)

        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: appHidden))
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: appHidden), thirdWorkspace)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 3)
    }

    func testNativeFullscreenExitReparksHiddenScratchpadMemberWithoutFocusing() throws {
        let fixture = try makeFixture()
        let token = addFloatingWindow(pid: 971_211, windowId: 971_311, to: fixture)
        XCTAssertEqual(assign(token, to: 4, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)
        try completeReveal(token, in: fixture)
        XCTAssertTrue(
            fixture.controller.workspaceManager.markNativeFullscreenSuspended(
                token,
                ownsNonManagedFocus: false
            )
        )
        XCTAssertEqual(fixture.controller.toggleScratchpad(4), .executed)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
        XCTAssertFalse(fixture.controller.axManager.pendingParkWindowIds.contains(token.windowId))
        fixture.focusRecorder.reset()
        let suspendedEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: suspendedEntry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: false,
            bindCurrentPidRequest: false
        )

        XCTAssertEqual(fixture.controller.workspaceManager.layoutReason(for: token), .standard)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: token)?.isScratchpad,
            true
        )
        XCTAssertTrue(fixture.controller.axManager.pendingParkWindowIds.contains(token.windowId))
        XCTAssertTrue(fixture.focusRecorder.focusedWindowIds.isEmpty)
    }

    func testNativeFullscreenExitRestoresMemberIntoRevealedScratchpadSlot() throws {
        let fixture = try makeFixture()
        let visible = addFloatingWindow(pid: 971_221, windowId: 971_321, to: fixture)
        let fullscreen = addFloatingWindow(pid: 971_222, windowId: 971_322, to: fixture)
        XCTAssertEqual(assign(visible, to: 5, in: fixture), .executed)
        XCTAssertEqual(assign(fullscreen, to: 5, in: fixture), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(5), .executed)
        try completeReveal(visible, in: fixture)
        try completeReveal(fullscreen, in: fixture)
        XCTAssertTrue(
            fixture.controller.workspaceManager.markNativeFullscreenSuspended(
                fullscreen,
                ownsNonManagedFocus: false
            )
        )
        XCTAssertEqual(fixture.controller.toggleScratchpad(5), .executed)
        XCTAssertEqual(fixture.controller.toggleScratchpad(5), .executed)
        try completeReveal(visible, in: fixture)
        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 5)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: fullscreen)?.isScratchpad,
            true
        )
        let suspendedEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: fullscreen))

        fixture.controller.reconcileScratchpadMembersAfterAppUnhide(pid: fullscreen.pid)

        XCTAssertEqual(fixture.controller.workspaceManager.layoutReason(for: fullscreen), .nativeFullscreen)
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: fullscreen)?.isScratchpad,
            true
        )
        XCTAssertNil(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: fullscreen.windowId
            )
        )

        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: suspendedEntry,
            isWorkspaceActive: true,
            appFullscreen: false,
            confirmRequest: false,
            bindCurrentPidRequest: false
        )

        XCTAssertEqual(fixture.controller.workspaceManager.revealedScratchpadIndex(), 5)
        XCTAssertNotNil(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(
                forWindowId: fullscreen.windowId
            )
        )
        XCTAssertEqual(
            fixture.controller.workspaceManager.hiddenState(for: fullscreen)?.isScratchpad,
            true
        )
        try completeReveal(fullscreen, in: fixture)
        XCTAssertNil(fixture.controller.workspaceManager.hiddenState(for: fullscreen))
        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadIndex(for: fullscreen), 5)
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let focusRecorder: FocusRecorder
    }

    private final class FocusRecorder {
        var focusedWindowIds: [UInt32] = []
        var orderedWindowIds: [UInt32] = []
        var frontmostPID: pid_t?

        func reset() {
            focusedWindowIds.removeAll()
            orderedWindowIds.removeAll()
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMScratchpadRevealTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let focusRecorder = FocusRecorder()
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    focusRecorder.frontmostPID = pid
                    focusRecorder.focusedWindowIds.append(windowId)
                },
                raiseWindow: { _ in },
                orderWindow: { windowId in
                    focusRecorder.orderedWindowIds.append(windowId)
                }
            )
        )
        controller.scheduleScratchpadStackingContinuation = { $0() }
        controller.axEventHandler.frontmostApplicationPIDProvider = { focusRecorder.frontmostPID }
        let monitor = Monitor(
            id: .init(displayId: 971_901),
            displayId: 971_901,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "ScratchpadReveal"
        )
        controller.layoutRefreshController.fastFrameProvider = { _, _ in
            CGRect(x: 120, y: 80, width: 900, height: 620)
        }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        return Fixture(
            controller: controller,
            monitor: monitor,
            workspaceId: workspaceId,
            focusRecorder: focusRecorder
        )
    }

    @discardableResult
    private func addFloatingWindow(
        pid: pid_t,
        windowId: Int,
        interactionPolicy: WindowInteractionPolicy = .full,
        to fixture: Fixture
    ) -> WindowToken {
        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: fixture.workspaceId,
            mode: .floating,
            interactionPolicy: interactionPolicy
        )
        fixture.controller.workspaceManager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 120, y: 80, width: 900, height: 620),
                normalizedOrigin: CGPoint(x: 0.05, y: 0.05),
                referenceMonitorId: fixture.monitor.id,
                restoreToFloating: true
            ),
            for: token
        )
        return token
    }

    private func addTilingWindow(
        pid: pid_t,
        windowId: Int,
        to fixture: Fixture
    ) -> WindowToken {
        fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: fixture.workspaceId,
            mode: .tiling
        )
    }

    private func blockLayoutRefresh(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return blocker
    }

    private func unblockLayoutRefresh(
        _ fixture: Fixture,
        blocker: Task<Void, Never>
    ) {
        blocker.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func assign(
        _ token: WindowToken,
        to index: ScratchpadIndex,
        in fixture: Fixture
    ) -> ExternalCommandResult {
        let manager = fixture.controller.workspaceManager
        _ = manager.cancelCurrentManagedFocusRequest()
        XCTAssertTrue(
            manager.setManagedFocus(
                token,
                in: manager.workspace(for: token) ?? fixture.workspaceId,
                onMonitor: fixture.monitor.id
            )
        )
        return fixture.controller.assignFocusedWindowToScratchpad(index)
    }

    private func completeReveal(
        _ token: WindowToken,
        in fixture: Fixture,
        transactionId explicitTransactionId: UInt64? = nil,
        failureReason: AXFrameWriteFailureReason? = nil,
        completeFronting: Bool = true
    ) throws {
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        let transactionId = try explicitTransactionId ?? XCTUnwrap(
            fixture.controller.layoutRefreshController.pendingRevealTransactionId(forWindowId: token.windowId)
        )
        let targetFrame = CGRect(x: 120, y: 80, width: 900, height: 620)
        fixture.controller.layoutRefreshController.completePendingRevealTransaction(
            with: AXFrameApplyResult(
                pid: entry.pid,
                windowId: entry.windowId,
                expectedWindow: entry.axRef,
                targetFrame: targetFrame,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    observedFrame: failureReason == nil ? targetFrame : nil,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: failureReason
                )
            ),
            transactionId: transactionId
        )
        if completeFronting {
            try completeScratchpadFronting(in: fixture)
        }
    }

    private func confirmScratchpadFrontingStage(
        _ token: WindowToken,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        in fixture: Fixture
    ) throws {
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, token)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        fixture.controller.axEventHandler.handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: true,
            appFullscreen: false,
            source: source,
            activeRequestId: request.requestId
        )
    }

    private func completeScratchpadFronting(in fixture: Fixture) throws {
        for _ in 0 ..< 32 {
            guard let request = fixture.controller.intentLedger.activeManagedRequest else { return }
            try confirmScratchpadFrontingStage(request.token, in: fixture)
        }
        XCTFail("Scratchpad fronting did not settle")
    }
}
