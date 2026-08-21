// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WorldStoreCommitTests: XCTestCase {
    func testCommitReusesReducerSnapshotWithoutPostReducerMutation() {
        let world = WorldStore()
        var snapshotCount = 0

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "projection_test", source: .command),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(focus: world.focus)
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(transaction.snapshot, Self.snapshot(focus: world.focus))
    }

    func testCommitBuildsCommittedSnapshotAfterResolvedPlanMutation() {
        let world = WorldStore()
        var snapshotCount = 0
        var nextFocus = FocusSessionSnapshot()
        nextFocus.isNonManagedFocusActive = true

        let transaction = world.commit(
            .userCommand(workspaceId: nil, label: "projection_test", source: .command),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(focus: world.focus)
            },
            resolvePlan: { plan, _, _ in
                var plan = plan
                plan.focusSession = nextFocus
                world.applyFocusSession(nextFocus)
                return plan
            }
        )

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(transaction.snapshot.focusSession, nextFocus)
    }

    func testCommitBuildsCommittedSnapshotForAfterPlanRemoval() {
        let world = WorldStore()
        let workspaceId = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 10, windowId: 20)
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(token.pid),
            windowId: token.windowId
        )
        _ = world.commit(
            .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                mode: .tiling,
                axRef: axRef,
                ruleEffects: .none,
                admissionHints: .none,
                interactionPolicy: .full,
                managedReplacementMetadata: nil,
                source: .workspaceManager
            ),
            monitors: [],
            snapshot: { Self.snapshot(world: world) },
            resolvePlan: { plan, _, _ in plan }
        )
        XCTAssertNotNil(world.entry(for: token))

        var snapshotCount = 0
        let transaction = world.commit(
            .windowRemoved(
                token: token,
                workspaceId: workspaceId,
                source: .workspaceManager
            ),
            monitors: [],
            snapshot: {
                snapshotCount += 1
                return Self.snapshot(world: world)
            },
            resolvePlan: { plan, _, _ in plan }
        )

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertNil(world.entry(for: token))
        XCTAssertFalse(transaction.snapshot.windows.contains { $0.token == token })
    }

    private static func snapshot(world: WorldStore) -> ReconcileSnapshot {
        snapshot(
            focus: world.focus,
            windows: world.allEntries().map {
                ReconcileWindowSnapshot(
                    token: $0.token,
                    workspaceId: $0.workspaceId,
                    mode: $0.mode,
                    lifecyclePhase: $0.lifecyclePhase,
                    observedState: $0.observedState,
                    desiredState: $0.desiredState,
                    restoreIntent: $0.restoreIntent,
                    interactionPolicy: $0.interactionPolicy
                )
            }
        )
    }

    private static func snapshot(
        focus: FocusSessionSnapshot,
        windows: [ReconcileWindowSnapshot] = []
    ) -> ReconcileSnapshot {
        ReconcileSnapshot(
            topologyProfile: TopologyProfile(sortedMonitors: []),
            focusSession: focus,
            windows: windows
        )
    }
}
