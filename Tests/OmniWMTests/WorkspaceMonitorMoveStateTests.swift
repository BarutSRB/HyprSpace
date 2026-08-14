// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceMonitorMoveStateTests: XCTestCase {
    private struct Fixture {
        let settings: SettingsStore
        let manager: WorkspaceManager
        let left: Monitor
        let center: Monitor
        let right: Monitor
    }

    func testConflictAndSameTargetNoOpAreAtomic() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 961_001,
            windowId: 961_101,
            workspaceId: workspaceId,
            manager: manager
        )
        let initialSeq = manager.worldSeq
        let initialEntry = try XCTUnwrap(manager.entry(for: token))

        let conflict = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id
        )

        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertTrue(conflict.affectedWorkspaces.isEmpty)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token), initialEntry)

        let noOp = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.left.id,
            force: true
        )

        XCTAssertEqual(noOp.status, .executed)
        XCTAssertTrue(noOp.affectedWorkspaces.isEmpty)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.entry(for: token), initialEntry)
    }

    func testVisibleMoveUsesPriorSourceReplacementWithoutSwappingDestination() throws {
        let fixture = makeFixture(
            assignments: [("1", 0), ("2", 0), ("3", 1), ("4", 2), ("5", 0)]
        )
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let priorWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let destinationWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        let interactionWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "4"))
        let inactiveWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "5"))

        XCTAssertTrue(
            manager.setActiveWorkspace(
                priorWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                movedWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                destinationWorkspaceId,
                on: fixture.center.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                interactionWorkspaceId,
                on: fixture.right.id,
                updateInteractionMonitor: false
            )
        )
        _ = manager.setInteractionMonitor(fixture.right.id)

        let outcome = manager.moveWorkspaceToMonitor(
            movedWorkspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(outcome.affectedWorkspaces, [movedWorkspaceId, priorWorkspaceId])
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, priorWorkspaceId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, movedWorkspaceId)
        XCTAssertEqual(manager.monitorForWorkspace(destinationWorkspaceId)?.id, fixture.center.id)
        XCTAssertNotEqual(manager.activeWorkspace(on: fixture.left.id)?.id, destinationWorkspaceId)
        XCTAssertEqual(manager.interactionMonitorId, fixture.right.id)

        let inactiveOutcome = manager.moveWorkspaceToMonitor(
            inactiveWorkspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(inactiveOutcome.status, .executed)
        XCTAssertEqual(inactiveOutcome.affectedWorkspaces, [inactiveWorkspaceId])
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, priorWorkspaceId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, inactiveWorkspaceId)
        XCTAssertEqual(manager.monitorForWorkspace(movedWorkspaceId)?.id, fixture.center.id)
    }

    func testConfirmedFocusAndPendingRequestTransferWithAllWindowProjections() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 0), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let replacementWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let focusedToken = addWindow(
            pid: 962_001,
            windowId: 962_101,
            workspaceId: workspaceId,
            manager: manager
        )
        let pendingToken = addWindow(
            pid: 962_002,
            windowId: 962_102,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        manager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 80, y: 70, width: 240, height: 180),
                normalizedOrigin: CGPoint(x: 0.4, y: 0.3),
                referenceMonitorId: fixture.left.id,
                restoreToFloating: true
            ),
            for: pendingToken
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                replacementWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                workspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(manager.setManagedFocus(focusedToken, in: workspaceId, onMonitor: fixture.left.id))
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: workspaceId,
                onMonitor: fixture.left.id,
                requestId: 42
            )
        )

        let engine = NiriLayoutEngine()
        manager.niriEngine = engine
        manager.withEngineMutationScope(in: workspaceId) {
            engine.moveWorkspace(workspaceId, to: fixture.left.id, monitor: fixture.left)
        }
        let originalRoot = try XCTUnwrap(engine.root(for: workspaceId))

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(outcome.affectedWorkspaces, [workspaceId, replacementWorkspaceId])
        XCTAssertEqual(manager.focusedToken, focusedToken)
        XCTAssertEqual(manager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, workspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.center.id)
        XCTAssertEqual(manager.interactionMonitorId, fixture.center.id)
        XCTAssertEqual(manager.previousInteractionMonitorId, fixture.left.id)
        XCTAssertTrue(engine.root(for: workspaceId) === originalRoot)
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), fixture.center.id)

        for token in [focusedToken, pendingToken] {
            let entry = try XCTUnwrap(manager.entry(for: token))
            XCTAssertEqual(entry.observedState.monitorId, fixture.center.id)
            XCTAssertEqual(entry.desiredState.monitorId, fixture.center.id)
            XCTAssertEqual(entry.restoreIntent?.workspaceId, workspaceId)
            XCTAssertEqual(entry.restoreIntent?.preferredMonitor?.displayId, fixture.center.displayId)
        }
    }

    func testConfirmedFocusMoveRejectsDifferentPendingWorkspaceWithoutMutation() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let pendingWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let focusedToken = addWindow(
            pid: 962_101,
            windowId: 962_201,
            workspaceId: movedWorkspaceId,
            manager: manager
        )
        let pendingToken = addWindow(
            pid: 962_102,
            windowId: 962_202,
            workspaceId: pendingWorkspaceId,
            manager: manager
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                focusedToken,
                in: movedWorkspaceId,
                onMonitor: fixture.left.id
            )
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: pendingWorkspaceId,
                onMonitor: fixture.center.id,
                requestId: 43
            )
        )
        let initialSeq = manager.worldSeq
        let initialFocusedEntry = try XCTUnwrap(manager.entry(for: focusedToken))
        let initialPendingEntry = try XCTUnwrap(manager.entry(for: pendingToken))

        let outcome = manager.moveWorkspaceToMonitor(
            movedWorkspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .stateConflict)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: movedWorkspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, movedWorkspaceId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, pendingWorkspaceId)
        XCTAssertEqual(manager.focusedToken, focusedToken)
        XCTAssertEqual(manager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, pendingWorkspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.center.id)
        XCTAssertEqual(manager.entry(for: focusedToken), initialFocusedEntry)
        XCTAssertEqual(manager.entry(for: pendingToken), initialPendingEntry)
    }

    func testPendingOnlyWorkspaceMoveRejectsWithoutMutation() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let pendingToken = addWindow(
            pid: 962_103,
            windowId: 962_203,
            workspaceId: workspaceId,
            manager: manager
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: workspaceId,
                onMonitor: fixture.left.id,
                requestId: 44
            )
        )
        XCTAssertNil(manager.focusedToken)
        let initialSeq = manager.worldSeq
        let initialEntry = try XCTUnwrap(manager.entry(for: pendingToken))

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .stateConflict)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, workspaceId)
        XCTAssertEqual(manager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(manager.pendingFocusedWorkspaceId, workspaceId)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.left.id)
        XCTAssertEqual(manager.entry(for: pendingToken), initialEntry)
    }

    func testPendingDestinationAndNonManagedInteractionRemainProtected() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let destinationWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let interactionWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        let pendingToken = addWindow(
            pid: 963_001,
            windowId: 963_101,
            workspaceId: destinationWorkspaceId,
            manager: manager
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: destinationWorkspaceId,
                onMonitor: fixture.center.id,
                requestId: 7
            )
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        let nonManagedToken = WindowToken(pid: 963_999, windowId: 963_199)
        XCTAssertTrue(
            manager.enterNonManagedFocus(
                preservePendingManagedFocus: true,
                target: nonManagedToken
            )
        )

        let outcome = manager.moveWorkspaceToMonitor(
            movedWorkspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(outcome.affectedWorkspaces, [movedWorkspaceId])
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, destinationWorkspaceId)
        XCTAssertEqual(manager.pendingFocusedToken, pendingToken)
        XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.center.id)
        XCTAssertTrue(manager.isNonManagedFocusActive)
        XCTAssertEqual(manager.nonManagedFocusToken, nonManagedToken)
        XCTAssertEqual(manager.interactionMonitorId, fixture.right.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.right.id)?.id, interactionWorkspaceId)
    }

    func testInactiveMoveScrubsPreviousWorkspaceHistoryOnSource() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 0), ("3", 1), ("4", 2)])
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let sourceWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))

        XCTAssertTrue(
            manager.setActiveWorkspace(
                movedWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                sourceWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertEqual(manager.previousWorkspace(on: fixture.left.id)?.id, movedWorkspaceId)
        _ = manager.setInteractionMonitor(fixture.right.id)

        let outcome = manager.moveWorkspaceToMonitor(
            movedWorkspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, sourceWorkspaceId)
        XCTAssertNotEqual(manager.previousWorkspace(on: fixture.left.id)?.id, movedWorkspaceId)
    }

    func testEmptyNonInteractionDestinationActivatesMovedWorkspaceAndPreservesRootIdentity() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        _ = manager.setInteractionMonitor(fixture.right.id)
        let engine = NiriLayoutEngine()
        manager.niriEngine = engine
        manager.withEngineMutationScope(in: workspaceId) {
            engine.moveWorkspace(workspaceId, to: fixture.left.id, monitor: fixture.left)
        }
        let originalRoot = try XCTUnwrap(engine.root(for: workspaceId))
        let initialSeq = manager.worldSeq

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(outcome.affectedWorkspaces, [workspaceId])
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, workspaceId)
        XCTAssertEqual(manager.interactionMonitorId, fixture.right.id)
        XCTAssertEqual(manager.worldSeq, initialSeq + 2)
        XCTAssertTrue(engine.root(for: workspaceId) === originalRoot)
        XCTAssertEqual(engine.monitorContaining(workspace: workspaceId), fixture.center.id)
    }

    func testFloatingTranslationPreservesNormalizedOriginAndExcludesHiddenAndScratchpadWindows() throws {
        let fixture = makeFixture(
            assignments: [("1", 0), ("2", 2)],
            centerSize: CGSize(width: 1000, height: 700)
        )
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        _ = manager.setInteractionMonitor(fixture.right.id)
        let visibleToken = addWindow(
            pid: 964_001,
            windowId: 964_101,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        let hiddenToken = addWindow(
            pid: 964_002,
            windowId: 964_102,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        let scratchToken = addWindow(
            pid: 964_003,
            windowId: 964_103,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        let oversizedToken = addWindow(
            pid: 964_005,
            windowId: 964_105,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        let normalizedOrigin = CGPoint(x: 0.73, y: 0.21)
        let proportionalFrame = CGRect(x: 40, y: 30, width: 240, height: 180)
        let oversizedFrame = CGRect(x: 40, y: 30, width: 1200, height: 800)

        for token in [visibleToken, hiddenToken, scratchToken] {
            manager.setFloatingState(
                FloatingState(
                    lastFrame: proportionalFrame,
                    normalizedOrigin: normalizedOrigin,
                    referenceMonitorId: fixture.left.id,
                    restoreToFloating: true
                ),
                for: token
            )
        }
        manager.setFloatingState(
            FloatingState(
                lastFrame: oversizedFrame,
                normalizedOrigin: normalizedOrigin,
                referenceMonitorId: fixture.left.id,
                restoreToFloating: true
            ),
            for: oversizedToken
        )
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.left.id,
                reason: .workspaceInactive
            ),
            for: hiddenToken
        )
        XCTAssertTrue(manager.setScratchpadToken(scratchToken))
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.left.id,
                reason: .scratchpad
            ),
            for: scratchToken
        )

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .executed)
        XCTAssertEqual(outcome.floatingRelocations.map(\.token), [visibleToken, oversizedToken])
        let visibleState = try XCTUnwrap(manager.floatingState(for: visibleToken))
        XCTAssertEqual(visibleState.normalizedOrigin, normalizedOrigin)
        XCTAssertEqual(visibleState.referenceMonitorId, fixture.center.id)
        XCTAssertEqual(
            visibleState.lastFrame.minX,
            fixture.center.visibleFrame.minX
                + normalizedOrigin.x * (fixture.center.visibleFrame.width - proportionalFrame.width),
            accuracy: 0.001
        )
        XCTAssertEqual(
            visibleState.lastFrame.minY,
            fixture.center.visibleFrame.minY
                + normalizedOrigin.y * (fixture.center.visibleFrame.height - proportionalFrame.height),
            accuracy: 0.001
        )
        XCTAssertEqual(visibleState.lastFrame.size, proportionalFrame.size)
        let oversizedState = try XCTUnwrap(manager.floatingState(for: oversizedToken))
        XCTAssertEqual(oversizedState.lastFrame.origin, fixture.center.visibleFrame.origin)
        XCTAssertEqual(oversizedState.lastFrame.size, oversizedFrame.size)
        XCTAssertEqual(manager.floatingState(for: hiddenToken)?.normalizedOrigin, normalizedOrigin)
        XCTAssertEqual(manager.floatingState(for: hiddenToken)?.referenceMonitorId, fixture.center.id)
        XCTAssertEqual(manager.floatingState(for: hiddenToken)?.lastFrame, visibleState.lastFrame)
        XCTAssertEqual(manager.floatingState(for: scratchToken)?.referenceMonitorId, fixture.left.id)
    }

    func testNonTransferableConfirmedFocusRejectsWithoutMutation() throws {
        for kind in ["native", "scratch"] {
            let fixture = makeFixture(assignments: [("1", 0), ("2", 2)])
            let manager = fixture.manager
            let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
            let token = addWindow(
                pid: kind == "native" ? 965_001 : 965_002,
                windowId: kind == "native" ? 965_101 : 965_102,
                workspaceId: workspaceId,
                mode: kind == "native" ? .tiling : .floating,
                manager: manager
            )
            XCTAssertTrue(manager.setManagedFocus(token, in: workspaceId, onMonitor: fixture.left.id))
            if kind == "native" {
                manager.setLayoutReason(.nativeFullscreen, for: token)
            } else {
                XCTAssertTrue(manager.setScratchpadToken(token))
            }
            let initialSeq = manager.worldSeq
            let initialEntry = try XCTUnwrap(manager.entry(for: token))

            let outcome = manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            )

            XCTAssertEqual(outcome.status, .stateConflict)
            XCTAssertEqual(manager.worldSeq, initialSeq)
            XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
            XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
            XCTAssertEqual(manager.focusedToken, token)
            XCTAssertEqual(manager.entry(for: token), initialEntry)
        }
    }

    func testSuspendedNativeFullscreenMemberRejectsMoveWithoutMutation() throws {
        for suspensionSource in ["record", "entry"] {
            let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
            let manager = fixture.manager
            let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
            let nativeFullscreenToken = addWindow(
                pid: suspensionSource == "record" ? 965_003 : 965_005,
                windowId: suspensionSource == "record" ? 965_103 : 965_105,
                workspaceId: workspaceId,
                manager: manager
            )
            _ = addWindow(
                pid: suspensionSource == "record" ? 965_004 : 965_006,
                windowId: suspensionSource == "record" ? 965_104 : 965_106,
                workspaceId: workspaceId,
                manager: manager
            )
            if suspensionSource == "record" {
                XCTAssertTrue(manager.markNativeFullscreenSuspended(nativeFullscreenToken))
                XCTAssertEqual(manager.nativeFullscreenRecord(for: nativeFullscreenToken)?.transition, .suspended)
            } else {
                manager.setLayoutReason(.nativeFullscreen, for: nativeFullscreenToken)
                XCTAssertNil(manager.nativeFullscreenRecord(for: nativeFullscreenToken))
            }
            let initialSeq = manager.worldSeq
            let initialEntry = try XCTUnwrap(manager.entry(for: nativeFullscreenToken))

            let outcome = manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            )

            XCTAssertEqual(outcome.status, .stateConflict)
            XCTAssertEqual(manager.worldSeq, initialSeq)
            XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
            XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
            XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, workspaceId)
            XCTAssertEqual(manager.entry(for: nativeFullscreenToken), initialEntry)
        }
    }

    func testEnterRequestedNativeFullscreenRecordRejectsMoveWithStandardEntryWithoutMutation() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_007,
            windowId: 965_107,
            workspaceId: workspaceId,
            manager: manager
        )
        XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token)?.transition, .enterRequested)
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .standard)
        let initialSeq = manager.worldSeq
        let initialEntry = try XCTUnwrap(manager.entry(for: token))
        let initialRecord = try XCTUnwrap(manager.nativeFullscreenRecord(for: token))

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .stateConflict)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, workspaceId)
        XCTAssertEqual(manager.entry(for: token), initialEntry)
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token), initialRecord)
    }

    func testVisibleNonfocusedScratchpadRejectsMoveWithoutMutation() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_008,
            windowId: 965_108,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        XCTAssertTrue(manager.setScratchpadToken(token))
        XCTAssertNil(manager.focusedToken)
        XCTAssertNil(manager.hiddenState(for: token))
        let initialSeq = manager.worldSeq
        let initialEntry = try XCTUnwrap(manager.entry(for: token))

        let outcome = manager.moveWorkspaceToMonitor(
            workspaceId,
            to: fixture.center.id,
            force: true
        )

        XCTAssertEqual(outcome.status, .stateConflict)
        XCTAssertEqual(manager.worldSeq, initialSeq)
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token), initialEntry)
    }

    func testNativeFullscreenEnterExpiryRemovesRecord() throws {
        let fixture = makeFixture(assignments: [("1", 0)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 971_001,
            windowId: 971_101,
            workspaceId: workspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertTrue(manager.enterNonManagedFocus(target: token))
        let generation = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionGeneration)

        XCTAssertTrue(manager.expireNativeFullscreenTransition(originalToken: token, generation: generation))
        XCTAssertNil(manager.nativeFullscreenRecord(for: token))
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .standard)
        XCTAssertFalse(manager.hasPendingNativeFullscreenTransition)
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
    }

    func testNativeFullscreenTransitionExpiryRespectsGeneration() throws {
        let fixture = makeFixture(assignments: [("1", 0)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 971_002,
            windowId: 971_102,
            workspaceId: workspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspaceId))
        let enterGeneration = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionGeneration)

        XCTAssertTrue(manager.markNativeFullscreenSuspended(token))
        let suspendedGeneration = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionGeneration)
        XCTAssertNotEqual(enterGeneration, suspendedGeneration)

        XCTAssertFalse(manager.expireNativeFullscreenTransition(originalToken: token, generation: enterGeneration))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token)?.transition, .suspended)

        XCTAssertTrue(manager.requestNativeFullscreenExit(token))
        let exitGeneration = try XCTUnwrap(manager.nativeFullscreenRecord(for: token)?.transitionGeneration)
        XCTAssertNotEqual(suspendedGeneration, exitGeneration)

        XCTAssertFalse(manager.expireNativeFullscreenTransition(originalToken: token, generation: suspendedGeneration))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token)?.transition, .exitRequested)

        XCTAssertTrue(manager.expireNativeFullscreenTransition(originalToken: token, generation: exitGeneration))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token)?.transition, .suspended)
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .nativeFullscreen)
    }

    func testNativeFullscreenTransitionTimeoutOwnershipFollowsRecordState() throws {
        let fixture = makeFixture(assignments: [("1", 0)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 971_008,
            windowId: 971_108,
            workspaceId: workspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspaceId))
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 1)

        XCTAssertTrue(manager.markNativeFullscreenSuspended(token, ownsNonManagedFocus: false))
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 0)

        XCTAssertTrue(manager.requestNativeFullscreenExit(token))
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 1)
        manager.cancelNativeFullscreenTransitionTimeouts()
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 0)
        manager.resumeNativeFullscreenTransitionTimeouts()
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 1)

        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: token))
        XCTAssertEqual(manager.nativeFullscreenTransitionTimeoutCount, 0)
    }

    func testNativeFullscreenTransitionQueriesAreScopedAndIncludeExit() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1)])
        let manager = fixture.manager
        let firstWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let secondWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let firstToken = addWindow(
            pid: 971_003,
            windowId: 971_103,
            workspaceId: firstWorkspaceId,
            manager: manager
        )
        let secondToken = addWindow(
            pid: 971_004,
            windowId: 971_104,
            workspaceId: secondWorkspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.requestNativeFullscreenEnter(firstToken, in: firstWorkspaceId))
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition)
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition(for: firstToken))
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition(in: firstWorkspaceId))
        XCTAssertFalse(manager.hasPendingNativeFullscreenTransition(for: secondToken))
        XCTAssertFalse(manager.hasPendingNativeFullscreenTransition(in: secondWorkspaceId))

        XCTAssertTrue(manager.markNativeFullscreenSuspended(firstToken, ownsNonManagedFocus: false))
        XCTAssertFalse(manager.hasPendingNativeFullscreenTransition)
        XCTAssertTrue(manager.requestNativeFullscreenExit(firstToken))
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition)
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition(for: firstToken))
        XCTAssertTrue(manager.hasPendingNativeFullscreenTransition(in: firstWorkspaceId))
        XCTAssertFalse(manager.showsNativeFullscreenPlaceholder(for: firstToken))
    }

    func testNativeFullscreenFocusOwnershipIsExactAcrossMultipleRecords() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1)])
        let manager = fixture.manager
        let firstWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let secondWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let firstToken = addWindow(
            pid: 971_005,
            windowId: 971_105,
            workspaceId: firstWorkspaceId,
            manager: manager
        )
        let secondToken = addWindow(
            pid: 971_006,
            windowId: 971_106,
            workspaceId: secondWorkspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.markNativeFullscreenSuspended(firstToken, ownsNonManagedFocus: false))
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertTrue(
            manager.selectNativeFullscreenPlaceholder(
                firstToken,
                in: firstWorkspaceId,
                onMonitor: fixture.left.id
            )
        )
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, firstToken)
        XCTAssertTrue(manager.markNativeFullscreenSuspended(secondToken))
        XCTAssertTrue(manager.isNonManagedFocusActive)
        XCTAssertEqual(manager.nonManagedFocusToken, secondToken)
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, secondToken)
        XCTAssertNil(manager.renderableFocusToken)

        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: firstToken))
        XCTAssertTrue(manager.isNonManagedFocusActive)
        XCTAssertEqual(manager.nonManagedFocusToken, secondToken)
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, secondToken)

        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: secondToken))
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
    }

    func testManagedFocusConfirmationClearsNativeFullscreenOwner() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1)])
        let manager = fixture.manager
        let fullscreenWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let managedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let fullscreenToken = addWindow(
            pid: 971_009,
            windowId: 971_109,
            workspaceId: fullscreenWorkspaceId,
            manager: manager
        )
        let managedToken = addWindow(
            pid: 971_010,
            windowId: 971_110,
            workspaceId: managedWorkspaceId,
            manager: manager
        )

        XCTAssertTrue(manager.markNativeFullscreenSuspended(fullscreenToken))
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, fullscreenToken)
        XCTAssertTrue(
            manager.setManagedFocus(
                managedToken,
                in: managedWorkspaceId,
                onMonitor: fixture.center.id
            )
        )
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertEqual(manager.renderableFocusToken, managedToken)
    }

    func testTopologyDrivenNativeFullscreenSuspensionIsFocusNeutral() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1)])
        let manager = fixture.manager
        let fullscreenWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let managedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let fullscreenToken = addWindow(
            pid: 971_011,
            windowId: 971_111,
            workspaceId: fullscreenWorkspaceId,
            manager: manager
        )
        let managedToken = addWindow(
            pid: 971_012,
            windowId: 971_112,
            workspaceId: managedWorkspaceId,
            manager: manager
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                managedToken,
                in: managedWorkspaceId,
                onMonitor: fixture.center.id
            )
        )
        XCTAssertNil(manager.lastFocusedToken(in: fullscreenWorkspaceId))
        manager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(displayIdentifier: "left", spaceIds: [1], currentSpaceId: 1),
                    .init(displayIdentifier: "center", spaceIds: [2], currentSpaceId: 2)
                ],
                activeSpaceId: 2,
                fullscreenSpaceIds: [1],
                windowSpace: [fullscreenToken.windowId: 1]
            )
        )

        XCTAssertTrue(manager.reconcileNativeFullscreenWithTopology(for: fullscreenToken))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: fullscreenToken)?.transition, .suspended)
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertEqual(manager.focusedToken, managedToken)
        XCTAssertEqual(manager.renderableFocusToken, managedToken)
        XCTAssertNil(manager.lastFocusedToken(in: fullscreenWorkspaceId))
    }

    func testTopologyDrivenNativeFullscreenRestorePreservesExactFocusOwner() throws {
        let fixture = makeFixture(assignments: [("1", 0)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 971_013,
            windowId: 971_113,
            workspaceId: workspaceId,
            manager: manager
        )
        XCTAssertTrue(manager.markNativeFullscreenSuspended(token))
        XCTAssertEqual(manager.activeNativeFullscreenFocusOwnerToken, token)
        manager.commitSpaceTopology(
            SpaceTopology(
                displays: [
                    .init(displayIdentifier: "left", spaceIds: [1, 2], currentSpaceId: 1)
                ],
                activeSpaceId: 1,
                fullscreenSpaceIds: [2],
                windowSpace: [token.windowId: 1]
            )
        )

        XCTAssertTrue(manager.reconcileNativeFullscreenWithTopology(for: token))
        XCTAssertNil(manager.nativeFullscreenRecord(for: token))
        XCTAssertEqual(manager.layoutReason(for: token), .standard)
        XCTAssertTrue(manager.isNonManagedFocusActive)
        XCTAssertEqual(manager.nonManagedFocusToken, token)
    }

    func testNativeFullscreenOwnerRekeysAndDefinitiveRemovalClearsMode() throws {
        let fixture = makeFixture(assignments: [("1", 0)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let originalToken = addWindow(
            pid: 971_007,
            windowId: 971_107,
            workspaceId: workspaceId,
            manager: manager
        )
        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 971_108)

        XCTAssertTrue(manager.markNativeFullscreenSuspended(originalToken))
        XCTAssertNotNil(
            manager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(replacementToken.pid),
                    windowId: replacementToken.windowId
                )
            )
        )
        XCTAssertEqual(manager.nonManagedFocusToken, replacementToken)
        XCTAssertEqual(manager.nativeFullscreenRecord(for: replacementToken)?.currentToken, replacementToken)

        XCTAssertNotNil(manager.removeWindow(pid: replacementToken.pid, windowId: replacementToken.windowId))
        XCTAssertFalse(manager.isNonManagedFocusActive)
        XCTAssertNil(manager.nonManagedFocusToken)
        XCTAssertNil(manager.nativeFullscreenRecord(for: replacementToken))
    }

    func testReusedOriginalTokenCannotMutateRekeyedFullscreenRecord() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1)])
        let manager = fixture.manager
        let firstWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let secondWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let originalToken = addWindow(
            pid: 971_014,
            windowId: 971_114,
            workspaceId: firstWorkspaceId,
            manager: manager
        )
        let replacementToken = WindowToken(pid: originalToken.pid, windowId: 971_115)
        XCTAssertTrue(manager.markNativeFullscreenSuspended(originalToken))
        XCTAssertNotNil(
            manager.rekeyWindow(
                from: originalToken,
                to: replacementToken,
                newAXRef: AXWindowRef(
                    element: AXUIElementCreateApplication(replacementToken.pid),
                    windowId: replacementToken.windowId
                )
            )
        )
        let reusedToken = addWindow(
            pid: originalToken.pid,
            windowId: originalToken.windowId,
            workspaceId: secondWorkspaceId,
            manager: manager
        )

        XCTAssertEqual(reusedToken, originalToken)
        XCTAssertFalse(manager.requestNativeFullscreenEnter(reusedToken, in: secondWorkspaceId))
        XCTAssertFalse(manager.markNativeFullscreenSuspended(reusedToken))
        XCTAssertNil(manager.nativeFullscreenRecord(for: reusedToken))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: replacementToken)?.currentToken, replacementToken)
        XCTAssertEqual(manager.nativeFullscreenRecord(for: replacementToken)?.workspaceId, firstWorkspaceId)
        XCTAssertNil(manager.lastFocusedToken(in: secondWorkspaceId))

        XCTAssertNotNil(manager.removeWindow(pid: reusedToken.pid, windowId: reusedToken.windowId))
        XCTAssertNotNil(manager.nativeFullscreenRecord(for: replacementToken))
    }

    func testConfigurationReapplyDefersExitRequestedNativeFullscreenUntilRestore() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_009,
            windowId: 965_109,
            workspaceId: workspaceId,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(manager.markNativeFullscreenSuspended(token))
        XCTAssertTrue(manager.requestNativeFullscreenExit(token))
        XCTAssertEqual(manager.nativeFullscreenRecord(for: token)?.transition, .exitRequested)
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.center.id)
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .nativeFullscreen)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))
        XCTAssertTrue(outcomes.isEmpty)

        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: token))

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .standard)
        XCTAssertEqual(manager.entry(for: token)?.observedState.monitorId, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.desiredState.monitorId, fixture.left.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].status, .executed)
        XCTAssertTrue(outcomes[0].affectedWorkspaces.contains(workspaceId))
    }

    func testConfigurationReapplyDefersVisibleScratchpadUntilHidden() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_010,
            windowId: 965_110,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        manager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 80, y: 60, width: 240, height: 180),
                normalizedOrigin: CGPoint(x: 0.35, y: 0.6),
                referenceMonitorId: fixture.left.id,
                restoreToFloating: true
            ),
            for: token
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(manager.setScratchpadToken(token))
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.center.id)
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.center.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))
        XCTAssertTrue(outcomes.isEmpty)

        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: fixture.center.id,
                reason: .scratchpad
            ),
            for: token
        )

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.observedState.monitorId, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.desiredState.monitorId, fixture.left.id)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.center.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].floatingRelocations.isEmpty)
    }

    func testConfigurationReapplyDefersVisibleScratchpadUntilReassigned() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let scratchDestinationId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let token = addWindow(
            pid: 965_016,
            windowId: 965_116,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(manager.setScratchpadToken(token))
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))

        manager.setWorkspace(for: token, to: scratchDestinationId)

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.workspace(for: token), scratchDestinationId)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testConfigurationReapplyDefersHiddenAppUntilLayoutStateRestores() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_014,
            windowId: 965_114,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        manager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 80, y: 60, width: 240, height: 180),
                normalizedOrigin: CGPoint(x: 0.35, y: 0.6),
                referenceMonitorId: fixture.left.id,
                restoreToFloating: true
            ),
            for: token
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        manager.setAppHidden(true, pid: token.pid, source: .ax)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.center.id)
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.center.id)
        XCTAssertTrue(manager.isAppHidden(token))
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))
        XCTAssertTrue(outcomes.isEmpty)

        manager.setAppHidden(false, pid: token.pid, source: .ax)

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.layoutReason, .standard)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.left.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0].floatingRelocations.map(\.token), [token])
    }

    func testConfigurationReapplyDefersConflictingPendingFocusUntilCancellation() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let pendingWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        let focusedToken = addWindow(
            pid: 965_011,
            windowId: 965_111,
            workspaceId: movedWorkspaceId,
            manager: manager
        )
        let pendingToken = addWindow(
            pid: 965_012,
            windowId: 965_112,
            workspaceId: pendingWorkspaceId,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                movedWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                focusedToken,
                in: movedWorkspaceId,
                onMonitor: fixture.center.id
            )
        )
        XCTAssertTrue(
            manager.beginManagedFocusRequest(
                pendingToken,
                in: pendingWorkspaceId,
                onMonitor: fixture.right.id,
                requestId: 45
            )
        )
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: movedWorkspaceId)?.runtimeMonitorOverride)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(movedWorkspaceId))
        XCTAssertTrue(outcomes.isEmpty)

        XCTAssertTrue(
            manager.cancelManagedFocusRequest(
                matching: pendingToken,
                workspaceId: pendingWorkspaceId,
                requestId: 45
            )
        )

        XCTAssertNil(manager.descriptor(for: movedWorkspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(movedWorkspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.focusedToken, focusedToken)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testDeferredConfigurationReapplyDrainsWhenInteractionReturnsToSource() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 965_013,
            windowId: 965_113,
            workspaceId: workspaceId,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(manager.setManagedFocus(token, in: workspaceId, onMonitor: fixture.center.id))
        XCTAssertTrue(manager.setInteractionMonitor(fixture.right.id))
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))

        XCTAssertTrue(manager.setInteractionMonitor(fixture.center.id))

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testDeferredConfigurationReapplyDrainsWhenFocusedWorkspaceBecomesVisible() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2), ("4", 1)])
        let manager = fixture.manager
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let alternateWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "4"))
        let token = addWindow(
            pid: 965_015,
            windowId: 965_115,
            workspaceId: workspaceId,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(manager.setManagedFocus(token, in: workspaceId, onMonitor: fixture.center.id))
        XCTAssertTrue(
            manager.setActiveWorkspace(
                alternateWorkspaceId,
                on: fixture.center.id,
                updateInteractionMonitor: false
            )
        )
        var outcomes: [WorkspaceMonitorMoveOutcome] = []
        manager.onDeferredWorkspaceMonitorMove = { outcomes.append($0) }

        manager.applySettings()

        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.contains(workspaceId))
        XCTAssertTrue(outcomes.isEmpty)

        let focusedWorkspace = try XCTUnwrap(manager.focusWorkspace(id: workspaceId))

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(focusedWorkspace.workspace.id, workspaceId)
        XCTAssertEqual(focusedWorkspace.monitor.id, fixture.left.id)
        XCTAssertEqual(manager.interactionMonitorId, fixture.left.id)
        XCTAssertTrue(manager.pendingRuntimeMonitorOverrideClearWorkspaceIds.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testSettingsReapplyClearsOverrideAndReturnsWindowStateHome() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2)])
        let manager = fixture.manager
        manager.persistedRestoreBundleIdProvider = { _ in "com.omniwm.workspace-move-test" }
        let workspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let token = addWindow(
            pid: 966_001,
            windowId: 966_101,
            workspaceId: workspaceId,
            mode: .floating,
            manager: manager
        )
        let normalizedOrigin = CGPoint(x: 0.35, y: 0.6)
        manager.setFloatingState(
            FloatingState(
                lastFrame: CGRect(x: 80, y: 60, width: 240, height: 180),
                normalizedOrigin: normalizedOrigin,
                referenceMonitorId: fixture.left.id,
                restoreToFloating: true
            ),
            for: token
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertNotNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.center.id)
        manager.flushPersistedWindowRestoreCatalogNow()
        let persistedEntry = try XCTUnwrap(
            fixture.settings.loadPersistedWindowRestoreCatalog().entries.first {
                $0.identity?.windowId == token.windowId
            }
        )
        XCTAssertEqual(persistedEntry.restoreIntent.preferredMonitor?.displayId, fixture.left.displayId)

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.left.id
            ).status,
            .executed
        )
        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.left.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                workspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )

        manager.applySettings()

        XCTAssertNil(manager.descriptor(for: workspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(workspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, workspaceId)
        XCTAssertEqual(manager.entry(for: token)?.observedState.monitorId, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.desiredState.monitorId, fixture.left.id)
        XCTAssertEqual(manager.entry(for: token)?.restoreIntent?.preferredMonitor?.displayId, fixture.left.displayId)
        XCTAssertEqual(manager.floatingState(for: token)?.referenceMonitorId, fixture.left.id)
        XCTAssertEqual(manager.floatingState(for: token)?.normalizedOrigin, normalizedOrigin)
    }

    func testInactiveOverrideDoesNotBecomeVisibleWhenTargetReconnects() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 1), ("3", 2), ("4", 0)])
        let manager = fixture.manager
        let destinationWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "4"))
        let focusedToken = addWindow(
            pid: 967_001,
            windowId: 967_101,
            workspaceId: destinationWorkspaceId,
            manager: manager
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                destinationWorkspaceId,
                on: fixture.center.id,
                updateInteractionMonitor: true
            )
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                focusedToken,
                in: destinationWorkspaceId,
                onMonitor: fixture.center.id
            )
        )

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                movedWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, destinationWorkspaceId)

        manager.applyMonitorConfigurationChange([fixture.left, fixture.right])
        manager.applyMonitorConfigurationChange([fixture.left, fixture.center, fixture.right])

        XCTAssertEqual(manager.monitorForWorkspace(movedWorkspaceId)?.id, fixture.center.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, destinationWorkspaceId)
        XCTAssertEqual(manager.focusedToken, focusedToken)
    }

    func testReconnectPrioritizesConfirmedAndPendingFocusOverRuntimeOverrideRestore() throws {
        for focusKind in ["confirmed", "pending"] {
            let fixture = makeFixture(
                assignments: [("1", 0), ("2", 0), ("3", 1), ("4", 2)],
                centerSize: CGSize(width: 100, height: 400)
            )
            let manager = fixture.manager
            let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
            let protectedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
            let protectedToken = addWindow(
                pid: focusKind == "confirmed" ? 967_101 : 967_102,
                windowId: focusKind == "confirmed" ? 967_201 : 967_202,
                workspaceId: protectedWorkspaceId,
                manager: manager
            )

            XCTAssertEqual(
                manager.moveWorkspaceToMonitor(
                    movedWorkspaceId,
                    to: fixture.center.id,
                    force: true
                ).status,
                .executed
            )
            XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, movedWorkspaceId)

            manager.applyMonitorConfigurationChange([fixture.left, fixture.right])
            XCTAssertTrue(
                manager.setActiveWorkspace(
                    movedWorkspaceId,
                    on: fixture.left.id,
                    updateInteractionMonitor: false
                )
            )
            XCTAssertTrue(
                manager.setActiveWorkspace(
                    protectedWorkspaceId,
                    on: fixture.right.id,
                    updateInteractionMonitor: true
                )
            )
            var displacedPendingToken: WindowToken?
            if focusKind == "confirmed" {
                XCTAssertTrue(
                    manager.setManagedFocus(
                        protectedToken,
                        in: protectedWorkspaceId,
                        onMonitor: fixture.right.id
                    )
                )
                let pendingToken = addWindow(
                    pid: 967_103,
                    windowId: 967_203,
                    workspaceId: movedWorkspaceId,
                    manager: manager
                )
                XCTAssertTrue(
                    manager.beginManagedFocusRequest(
                        pendingToken,
                        in: movedWorkspaceId,
                        onMonitor: fixture.left.id,
                        requestId: 46
                    )
                )
                displacedPendingToken = pendingToken
            } else {
                XCTAssertTrue(
                    manager.beginManagedFocusRequest(
                        protectedToken,
                        in: protectedWorkspaceId,
                        onMonitor: fixture.right.id,
                        requestId: 45
                    )
                )
            }
            XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, movedWorkspaceId)
            XCTAssertEqual(manager.activeWorkspace(on: fixture.right.id)?.id, protectedWorkspaceId)

            manager.applyMonitorConfigurationChange([fixture.left, fixture.center, fixture.right])

            XCTAssertNotNil(manager.descriptor(for: movedWorkspaceId)?.runtimeMonitorOverride)
            XCTAssertEqual(manager.monitorForWorkspace(movedWorkspaceId)?.id, fixture.center.id)
            XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, protectedWorkspaceId)
            XCTAssertNotEqual(manager.activeWorkspace(on: fixture.center.id)?.id, movedWorkspaceId)
            XCTAssertEqual(manager.interactionMonitorId, fixture.center.id)
            if focusKind == "confirmed" {
                XCTAssertEqual(manager.focusedToken, protectedToken)
                XCTAssertEqual(manager.pendingFocusedToken, displacedPendingToken)
                XCTAssertEqual(manager.pendingFocusedWorkspaceId, movedWorkspaceId)
                XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.center.id)
            } else {
                XCTAssertEqual(manager.pendingFocusedToken, protectedToken)
                XCTAssertEqual(manager.pendingFocusedWorkspaceId, protectedWorkspaceId)
                XCTAssertEqual(manager.pendingFocusedMonitorId, fixture.center.id)
            }
        }
    }

    func testReconnectIgnoresPreservedManagedFocusWhileNonManagedFocusIsActive() throws {
        let fixture = makeFixture(
            assignments: [("1", 0), ("2", 0), ("3", 1), ("4", 2)],
            centerSize: CGSize(width: 100, height: 400)
        )
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let preservedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "3"))
        let preservedToken = addWindow(
            pid: 967_104,
            windowId: 967_204,
            workspaceId: preservedWorkspaceId,
            manager: manager
        )

        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                movedWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        manager.applyMonitorConfigurationChange([fixture.left, fixture.right])
        XCTAssertTrue(
            manager.setActiveWorkspace(
                movedWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: false
            )
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                preservedWorkspaceId,
                on: fixture.right.id,
                updateInteractionMonitor: true
            )
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                preservedToken,
                in: preservedWorkspaceId,
                onMonitor: fixture.right.id
            )
        )
        XCTAssertTrue(
            manager.enterNonManagedFocus(
                preserveFocusedToken: true,
                target: WindowToken(pid: 967_999, windowId: 967_299)
            )
        )

        manager.applyMonitorConfigurationChange([fixture.left, fixture.center, fixture.right])

        XCTAssertEqual(manager.activeWorkspace(on: fixture.center.id)?.id, movedWorkspaceId)
        XCTAssertEqual(manager.focusedToken, preservedToken)
        XCTAssertTrue(manager.isNonManagedFocusActive)
        XCTAssertEqual(manager.interactionMonitorId, fixture.right.id)
    }

    func testConfigurationReapplyDoesNotDisplaceFocusedHomeWorkspace() throws {
        let fixture = makeFixture(assignments: [("1", 0), ("2", 0), ("3", 1), ("4", 2)])
        let manager = fixture.manager
        let movedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "1"))
        let focusedWorkspaceId = try XCTUnwrap(manager.workspaceId(named: "2"))
        let focusedToken = addWindow(
            pid: 968_001,
            windowId: 968_101,
            workspaceId: focusedWorkspaceId,
            manager: manager
        )
        _ = manager.setInteractionMonitor(fixture.right.id)
        XCTAssertEqual(
            manager.moveWorkspaceToMonitor(
                movedWorkspaceId,
                to: fixture.center.id,
                force: true
            ).status,
            .executed
        )
        XCTAssertTrue(
            manager.setActiveWorkspace(
                focusedWorkspaceId,
                on: fixture.left.id,
                updateInteractionMonitor: true
            )
        )
        XCTAssertTrue(
            manager.setManagedFocus(
                focusedToken,
                in: focusedWorkspaceId,
                onMonitor: fixture.left.id
            )
        )

        manager.applySettings()

        XCTAssertNil(manager.descriptor(for: movedWorkspaceId)?.runtimeMonitorOverride)
        XCTAssertEqual(manager.monitorForWorkspace(movedWorkspaceId)?.id, fixture.left.id)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.left.id)?.id, focusedWorkspaceId)
        XCTAssertEqual(manager.focusedToken, focusedToken)
        XCTAssertEqual(manager.interactionMonitorId, fixture.left.id)
    }

    private func makeFixture(
        assignments: [(String, Int)],
        centerSize: CGSize = CGSize(width: 600, height: 400)
    ) -> Fixture {
        let left = makeMonitor(
            displayId: 960_001,
            name: "Left",
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let center = makeMonitor(
            displayId: 960_002,
            name: "Center",
            frame: CGRect(origin: CGPoint(x: 600, y: 0), size: centerSize)
        )
        let right = makeMonitor(
            displayId: 960_003,
            name: "Right",
            frame: CGRect(x: 600 + centerSize.width, y: 0, width: 600, height: 400)
        )
        let monitors = [left, center, right]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMWorkspaceMonitorMoveStateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        settings.workspaceConfigurations = assignments.map { name, monitorIndex in
            WorkspaceConfiguration(
                name: name,
                monitorAssignment: .specificDisplay(OutputId(from: monitors[monitorIndex])),
                layoutType: .niri
            )
        }
        let manager = WorkspaceManager(settings: settings)
        manager.applyMonitorConfigurationChange(monitors)
        manager.applySettings()
        return Fixture(
            settings: settings,
            manager: manager,
            left: left,
            center: center,
            right: right
        )
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        frame: CGRect
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }

    @discardableResult
    private func addWindow(
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        manager: WorkspaceManager
    ) -> WindowToken {
        manager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(pid),
                windowId: windowId
            ),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: mode
        )
    }
}
