// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@testable import OmniWM
import XCTest

final class ExternalFocusInvariantTests: XCTestCase {
    func testVerifiedParentMustMatchManagedSelection() {
        let selected = WindowToken(pid: 1, windowId: 10)
        let parent = WindowToken(pid: 1, windowId: 11)
        let snapshot = Self.snapshot(selected: selected, parent: parent, windows: [selected, parent])

        XCTAssertTrue(
            InvariantChecks.validate(snapshot: snapshot)
                .contains { $0.code == "external_focus_parent_selection_mismatch" }
        )
    }

    func testVerifiedParentMustExistAndRemainLive() {
        let parent = WindowToken(pid: 2, windowId: 20)
        let missing = Self.snapshot(selected: parent, parent: parent, windows: [])
        let destroyed = Self.snapshot(
            selected: parent,
            parent: parent,
            windows: [parent],
            lifecyclePhase: .destroyed
        )

        XCTAssertTrue(
            InvariantChecks.validate(snapshot: missing)
                .contains { $0.code == "external_focus_parent_missing" }
        )
        XCTAssertTrue(
            InvariantChecks.validate(snapshot: destroyed)
                .contains { $0.code == "external_focus_parent_destroyed" }
        )
    }

    func testVerifiedParentMustNotMatchExternalChild() {
        let token = WindowToken(pid: 3, windowId: 30)
        let snapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                selectedManagedToken: token,
                nativeFocusOwner: .external(
                    pid: token.pid,
                    windowId: token.windowId,
                    verifiedManagedParentToken: token
                )
            ),
            windows: [Self.window(token: token, workspaceId: WorkspaceDescriptor.ID())]
        )

        XCTAssertTrue(
            InvariantChecks.validate(snapshot: snapshot)
                .contains { $0.code == "external_focus_parent_matches_child" }
        )
    }

    func testHiddenExternalApplicationDowngradesIdentityAndClearsParentContinuity() {
        let workspaceId = WorkspaceDescriptor.ID()
        let parent = WindowToken(pid: 4, windowId: 40)
        let child = WindowToken(pid: 4, windowId: 41)
        let snapshot = ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                selectedManagedToken: parent,
                nativeFocusOwner: .external(
                    pid: child.pid,
                    windowId: child.windowId,
                    verifiedManagedParentToken: parent
                )
            ),
            windows: [Self.window(token: parent, workspaceId: workspaceId)]
        )

        let plan = StateReducer.reduce(
            event: .hiddenApplicationsChanged(
                pids: [child.pid],
                affectedWorkspaceIds: [workspaceId],
                source: .workspaceManager
            ),
            existingEntry: nil,
            currentSnapshot: snapshot,
            monitors: []
        )

        XCTAssertEqual(plan.focusSession?.selectedManagedToken, parent)
        XCTAssertEqual(plan.focusSession?.nativeFocusOwner.externalIdentity?.pid, child.pid)
        XCTAssertNil(plan.focusSession?.nativeFocusOwner.externalToken)
        XCTAssertNil(
            plan.focusSession?.nativeFocusOwner.externalIdentity?.verifiedManagedParentToken
        )
    }

    private static func snapshot(
        selected: WindowToken,
        parent: WindowToken,
        windows: [WindowToken],
        lifecyclePhase: WindowLifecyclePhase = .tiled
    ) -> ReconcileSnapshot {
        let workspaceId = WorkspaceDescriptor.ID()
        let child = WindowToken(pid: selected.pid, windowId: selected.windowId + 100)
        return ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: FocusSessionSnapshot(
                selectedManagedToken: selected,
                nativeFocusOwner: .external(
                    pid: child.pid,
                    windowId: child.windowId,
                    verifiedManagedParentToken: parent
                )
            ),
            windows: windows.map {
                Self.window(token: $0, workspaceId: workspaceId, lifecyclePhase: lifecyclePhase)
            }
        )
    }

    private static func window(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        lifecyclePhase: WindowLifecyclePhase = .tiled
    ) -> ReconcileWindowSnapshot {
        ReconcileWindowSnapshot(
            token: token,
            workspaceId: workspaceId,
            mode: .tiling,
            lifecyclePhase: lifecyclePhase,
            observedState: .initial(workspaceId: workspaceId, monitorId: nil),
            desiredState: .initial(
                workspaceId: workspaceId,
                monitorId: nil,
                disposition: .tiling
            ),
            restoreIntent: nil
        )
    }
}
