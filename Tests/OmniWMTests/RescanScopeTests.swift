// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class RescanScopeTests: XCTestCase {
    func testLifecycleCleanupReasonsDoNotRequireEnumeration() {
        XCTAssertEqual(RefreshReason.appTerminated.requestRoute, .relayout)
        XCTAssertEqual(RefreshReason.workspaceConfigChanged.requestRoute, .relayout)
        XCTAssertEqual(RefreshReason.appLaunched.requestRoute, .fullRescan)
        XCTAssertEqual(RefreshReason.activeSpaceChanged.requestRoute, .fullRescan)
    }

    func testTargetedScopesMergeAppRootsAndReplaceNativeSpaceEvidence() {
        let merged = RescanScope.targeted(
            appPIDs: [101],
            nativeSpaceIds: [201],
            nativeSpaceWindowIdsByPID: [101: [1_001]]
        ).merged(
            with: .targeted(
                appPIDs: [102],
                nativeSpaceIds: [202],
                nativeSpaceWindowIdsByPID: [102: [1_002]]
            )
        )

        XCTAssertEqual(
            merged,
            .targeted(
                appPIDs: [101, 102],
                nativeSpaceIds: [202],
                nativeSpaceWindowIdsByPID: [102: [1_002]]
            )
        )
    }

    func testAppOnlyScopePreservesExistingNativeSpaceEvidence() {
        let merged = RescanScope.targeted(
            appPIDs: [],
            nativeSpaceIds: [201],
            nativeSpaceWindowIdsByPID: [101: [1_001]]
        ).merged(
            with: .targeted(appPIDs: [102], nativeSpaceIds: [])
        )

        XCTAssertEqual(
            merged,
            .targeted(
                appPIDs: [102],
                nativeSpaceIds: [201],
                nativeSpaceWindowIdsByPID: [101: [1_001]]
            )
        )
    }

    func testGlobalScopeDominatesTargetedScope() {
        XCTAssertEqual(
            RescanScope.targeted(appPIDs: [101], nativeSpaceIds: [201])
                .merged(with: .all),
            .all
        )
        XCTAssertEqual(
            RescanScope.all.merged(
                with: .targeted(appPIDs: [101], nativeSpaceIds: [201])
            ),
            .all
        )
    }

    func testGlobalMissingConfirmationQueuesGlobalScope() {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.scheduleMissingConfirmation(scope: .all)

        XCTAssertEqual(refreshController.layoutState.pendingMissingConfirmationScope, .all)
        XCTAssertNotNil(refreshController.layoutState.missingConfirmationTask)
    }

    func testPendingFullRescansMergeTheirScopes() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = Task {}
        refreshController.layoutState.activeRefresh = .init(
            kind: .relayout,
            reason: .layoutCommand
        )
        defer { refreshController.resetState() }

        refreshController.requestFullRescan(
            reason: .appLaunched,
            scope: .targeted(appPIDs: [301], nativeSpaceIds: [])
        )
        refreshController.requestFullRescan(
            reason: .activeSpaceChanged,
            scope: .targeted(
                appPIDs: [],
                nativeSpaceIds: [401],
                nativeSpaceWindowIdsByPID: [302: [4_001]]
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.pendingRefresh).rescanScope,
            .targeted(
                appPIDs: [301],
                nativeSpaceIds: [401],
                nativeSpaceWindowIdsByPID: [302: [4_001]]
            )
        )
    }

    func testPendingGlobalRescanDominatesTargetedRequest() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .startup,
            rescanScope: .all
        )
        defer { refreshController.resetState() }

        refreshController.requestFullRescan(
            reason: .appLaunched,
            scope: .targeted(appPIDs: [501], nativeSpaceIds: [])
        )

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.activeRefresh).rescanScope,
            .all
        )
    }

    func testTargetedFullRescanSubsumesFollowingScopedRelayout() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let postLayoutAction = RefreshPostLayoutAction(action: {})
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [511], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [workspaceId],
                postLayout: postLayoutAction
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.rescanScope, .targeted(appPIDs: [511], nativeSpaceIds: []))
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertEqual(pending.affectedWorkspaceIds, [workspaceId])
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        XCTAssertNil(pending.followUpRefresh)
    }

    func testTargetedFullRescanSubsumesFollowingGlobalRelayout() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [512], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertTrue(pending.affectedWorkspaceIds.isEmpty)
        XCTAssertNil(pending.followUpRefresh)
    }

    func testRelayoutUpgradedByTargetedFullRescanIsSubsumed() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let postLayoutAction = RefreshPostLayoutAction(action: {})
        refreshController.layoutState.pendingRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId],
            postLayout: postLayoutAction
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .fullRescan,
                reason: .appLaunched,
                rescanScope: .targeted(appPIDs: [513], nativeSpaceIds: [])
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.rescanScope, .targeted(appPIDs: [513], nativeSpaceIds: []))
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertEqual(pending.affectedWorkspaceIds, [workspaceId])
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        XCTAssertNil(pending.followUpRefresh)
    }

    func testTargetedFullRescanMergesSubsumedRelayoutWorkspaceScopes() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [514], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .layoutCommand,
                affectedWorkspaceIds: [workspaceId]
            )
        )
        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertTrue(pending.affectedWorkspaceIds.isEmpty)
        XCTAssertNil(pending.followUpRefresh)
    }

    func testSubsumedGlobalRelayoutRetainsExplicitWorkspaceScope() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [514], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged
            )
        )
        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .overviewMutation,
                affectedWorkspaceIds: [workspaceId],
                postLayout: RefreshPostLayoutAction(
                    workspaceSeqs: [workspaceId: 0],
                    action: {}
                )
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertTrue(pending.affectedWorkspaceIds.isEmpty)
        XCTAssertEqual(pending.additionalAffectedWorkspaceIds, [workspaceId])
        XCTAssertTrue(
            refreshController.resolvedScheduledWorkspaceIds(pending)
                .contains(workspaceId)
        )
    }

    func testGlobalFullRescanSubsumesRelayoutInBothMergeOrders() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .startup
        )
        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                postLayout: RefreshPostLayoutAction(action: {})
            )
        )
        XCTAssertNil(refreshController.layoutState.pendingRefresh?.followUpRefresh)
        XCTAssertTrue(refreshController.layoutState.pendingRefresh?.subsumesRelayout == true)
        XCTAssertEqual(
            refreshController.layoutState.pendingRefresh?.postLayoutActions.count,
            1
        )

        refreshController.layoutState.pendingRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            postLayout: RefreshPostLayoutAction(action: {})
        )
        refreshController.mergePendingRefresh(
            .init(
                kind: .fullRescan,
                reason: .startup
            )
        )
        XCTAssertNil(refreshController.layoutState.pendingRefresh?.followUpRefresh)
        XCTAssertTrue(refreshController.layoutState.pendingRefresh?.subsumesRelayout == true)
        XCTAssertEqual(
            refreshController.layoutState.pendingRefresh?.postLayoutActions.count,
            1
        )
    }

    func testGlobalFullRescanPreservesNestedFollowUpMetadata() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let token = WindowToken(pid: 515, windowId: 5_015)
        let relocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 15, y: 25, width: 900, height: 700)
            ),
            allowsTerminalRecovery: true
        )
        var fullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .startup
        )
        fullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [token: relocation],
            reconcilesWorkspaceMonitorState: true,
            suppressesWindowActivation: true
        )
        refreshController.layoutState.pendingRefresh = fullRescan
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .fullRescan,
                reason: .appLaunched,
                rescanScope: .targeted(appPIDs: [515], nativeSpaceIds: [])
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.rescanScope, .all)
        XCTAssertFalse(pending.subsumesRelayout)
        XCTAssertTrue(pending.affectedWorkspaceIds.isEmpty)
        XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
        XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
        XCTAssertTrue(pending.suppressesWindowActivation)
        let followUp = try XCTUnwrap(pending.followUpRefresh)
        XCTAssertEqual(followUp.kind, .relayout)
        XCTAssertEqual(followUp.affectedWorkspaceIds, [workspaceId])
        XCTAssertEqual(followUp.workspaceMonitorRelocations[token], relocation)
        XCTAssertTrue(followUp.reconcilesWorkspaceMonitorState)
        XCTAssertTrue(followUp.suppressesWindowActivation)
    }

    func testGlobalFullRescanPreservesActionBearingWindowRemovalFollowUp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        var actionRan = false
        refreshController.layoutState.pendingRefresh = .init(
            kind: .windowRemoval,
            reason: .windowDestroyed,
            windowRemovalPayload: .init(
                workspaceId: workspaceId,
                layoutType: .niri,
                removedNodeId: nil,
                removedNiriColumn: false,
                niriOldFrames: [:],
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false
            )
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .overviewMutation,
                affectedWorkspaceIds: [workspaceId],
                postLayout: RefreshPostLayoutAction(action: {
                    actionRan = true
                })
            )
        )
        refreshController.mergePendingRefresh(
            .init(
                kind: .fullRescan,
                reason: .startup
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        XCTAssertEqual(pending.followUpRefresh?.kind, .immediateRelayout)
        XCTAssertEqual(pending.followUpRefresh?.affectedWorkspaceIds, [workspaceId])
        XCTAssertTrue(pending.suppressesWindowActivation)
        XCTAssertTrue(pending.followUpRefresh?.suppressesWindowActivation == true)
        for action in pending.postLayoutActions {
            action.runIfCurrent(using: controller.workspaceManager)
        }
        XCTAssertTrue(actionRan)
    }

    func testFullRescanRoutesNewerRelocationToRetainedFollowUp() throws {
        for scope in [
            RescanScope.all,
            .targeted(appPIDs: [516], nativeSpaceIds: [])
        ] {
            let controller = WindowAdmissionTestSupport.controller()
            let refreshController = controller.layoutRefreshController
            let workspaceId = UUID()
            let token = WindowToken(pid: 516, windowId: 5_016)
            let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                relocation: .init(
                    workspaceId: workspaceId,
                    token: token,
                    frame: CGRect(x: 16, y: 26, width: 800, height: 600)
                ),
                allowsTerminalRecovery: true
            )
            let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                relocation: .init(
                    workspaceId: workspaceId,
                    token: token,
                    frame: CGRect(x: 36, y: 46, width: 900, height: 700)
                ),
                allowsTerminalRecovery: false
            )
            var fullRescan = LayoutRefreshController.ScheduledRefresh(
                kind: .fullRescan,
                reason: .appLaunched,
                rescanScope: scope
            )
            fullRescan.followUpRefresh = .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [workspaceId],
                workspaceMonitorRelocations: [token: olderRelocation],
                reconcilesWorkspaceMonitorState: true
            )
            refreshController.layoutState.pendingRefresh = fullRescan
            defer { refreshController.resetState() }

            refreshController.mergePendingRefresh(
                .init(
                    kind: .immediateRelayout,
                    reason: .workspaceTransition,
                    affectedWorkspaceIds: [workspaceId],
                    workspaceMonitorRelocations: [newerRelocation],
                    reconcilesWorkspaceMonitorState: true
                )
            )

            let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
            XCTAssertFalse(pending.subsumesRelayout)
            XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
            XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
            let followUp = try XCTUnwrap(pending.followUpRefresh)
            XCTAssertEqual(followUp.kind, .immediateRelayout)
            XCTAssertEqual(
                followUp.workspaceMonitorRelocations[token],
                newerRelocation
            )
            XCTAssertTrue(followUp.reconcilesWorkspaceMonitorState)
        }
    }

    func testFullRescanAppliesActionBearingRelocationBeforeRetainedFollowUp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let token = WindowToken(pid: 517, windowId: 5_017)
        let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 17, y: 27, width: 800, height: 600)
            ),
            allowsTerminalRecovery: true
        )
        let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 37, y: 47, width: 900, height: 700)
            ),
            allowsTerminalRecovery: false
        )
        var actionRan = false
        var fullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
        )
        fullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [token: olderRelocation],
            reconcilesWorkspaceMonitorState: true
        )
        refreshController.layoutState.pendingRefresh = fullRescan
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .workspaceTransition,
                affectedWorkspaceIds: [workspaceId],
                postLayout: RefreshPostLayoutAction(action: {
                    actionRan = true
                }),
                workspaceMonitorRelocations: [newerRelocation],
                reconcilesWorkspaceMonitorState: true
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.workspaceMonitorRelocations[token], newerRelocation)
        XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        XCTAssertNil(pending.followUpRefresh?.workspaceMonitorRelocations[token])
        XCTAssertTrue(pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true)
        for action in pending.postLayoutActions {
            action.runIfCurrent(using: controller.workspaceManager)
        }
        XCTAssertTrue(actionRan)
    }

    func testActionBearingRelayoutPreservesDisjointFollowUpReconciliation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let primaryWorkspaceId = UUID()
        let followUpWorkspaceId = UUID()
        var fullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [517], nativeSpaceIds: [])
        )
        fullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [followUpWorkspaceId],
            reconcilesWorkspaceMonitorState: true
        )
        refreshController.layoutState.pendingRefresh = fullRescan
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .workspaceTransition,
                affectedWorkspaceIds: [primaryWorkspaceId],
                postLayout: RefreshPostLayoutAction(action: {}),
                reconcilesWorkspaceMonitorState: true
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        XCTAssertEqual(pending.affectedWorkspaceIds, [primaryWorkspaceId])
        XCTAssertTrue(pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true)
        XCTAssertEqual(
            pending.followUpRefresh?.affectedWorkspaceIds,
            [primaryWorkspaceId, followUpWorkspaceId]
        )
    }

    func testRetainedGlobalFollowUpKeepsExplicitWorkspaceScope() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        var fullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [518], nativeSpaceIds: [])
        )
        fullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged
        )
        refreshController.layoutState.pendingRefresh = fullRescan
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .overviewMutation,
                affectedWorkspaceIds: [workspaceId],
                postLayout: RefreshPostLayoutAction(action: {})
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        let followUp = try XCTUnwrap(pending.followUpRefresh)
        XCTAssertTrue(followUp.affectedWorkspaceIds.isEmpty)
        XCTAssertEqual(
            followUp.additionalAffectedWorkspaceIds,
            [workspaceId]
        )
        XCTAssertTrue(
            refreshController.resolvedFollowUpWorkspaceIds(followUp)
                .contains(workspaceId)
        )
    }

    func testWindowRemovalDefersDurableReconciliationInBothMergeOrders() throws {
        for windowRemovalFirst in [true, false] {
            let controller = WindowAdmissionTestSupport.controller()
            let refreshController = controller.layoutRefreshController
            let workspaceId = UUID()
            let windowRemoval = LayoutRefreshController.ScheduledRefresh(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                windowRemovalPayload: .init(
                    workspaceId: workspaceId,
                    layoutType: .niri,
                    removedNodeId: nil,
                    removedNiriColumn: false,
                    niriOldFrames: [:],
                    shouldRecoverFocus: false,
                    allowsPreferredRecoveryToken: false
                )
            )
            let relayout = LayoutRefreshController.ScheduledRefresh(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [workspaceId],
                reconcilesWorkspaceMonitorState: true
            )
            refreshController.layoutState.pendingRefresh =
                windowRemovalFirst ? windowRemoval : relayout
            defer { refreshController.resetState() }

            refreshController.mergePendingRefresh(
                windowRemovalFirst ? relayout : windowRemoval
            )

            let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .windowRemoval)
            XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
            XCTAssertTrue(
                pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true
            )
        }
    }

    func testWindowRemovalUpgradePreservesNewerNestedFollowUp() throws {
        for kind in [
            LayoutRefreshController.ScheduledRefreshKind.immediateRelayout,
            .relayout
        ] {
            let controller = WindowAdmissionTestSupport.controller()
            let refreshController = controller.layoutRefreshController
            let olderWorkspaceId = UUID()
            let newerWorkspaceId = UUID()
            let token = WindowToken(pid: 519, windowId: 5_019)
            let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                relocation: .init(
                    workspaceId: olderWorkspaceId,
                    token: token,
                    frame: CGRect(x: 19, y: 29, width: 800, height: 600)
                ),
                allowsTerminalRecovery: true
            )
            let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
                relocation: .init(
                    workspaceId: newerWorkspaceId,
                    token: token,
                    frame: CGRect(x: 39, y: 49, width: 900, height: 700)
                ),
                allowsTerminalRecovery: false
            )
            refreshController.layoutState.pendingRefresh = .init(
                kind: kind,
                reason: .workspaceTransition,
                affectedWorkspaceIds: [olderWorkspaceId],
                workspaceMonitorRelocations: [olderRelocation]
            )
            var windowRemoval = LayoutRefreshController.ScheduledRefresh(
                kind: .windowRemoval,
                reason: .windowDestroyed,
                windowRemovalPayload: .init(
                    workspaceId: newerWorkspaceId,
                    layoutType: .niri,
                    removedNodeId: nil,
                    removedNiriColumn: false,
                    niriOldFrames: [:],
                    shouldRecoverFocus: false,
                    allowsPreferredRecoveryToken: false
                )
            )
            windowRemoval.followUpRefresh = .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [newerWorkspaceId],
                workspaceMonitorRelocations: [token: newerRelocation],
                reconcilesWorkspaceMonitorState: true
            )
            defer { refreshController.resetState() }

            refreshController.mergePendingRefresh(windowRemoval)

            let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
            XCTAssertEqual(pending.kind, .windowRemoval)
            XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
            XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
            let followUp = try XCTUnwrap(pending.followUpRefresh)
            XCTAssertEqual(
                followUp.affectedWorkspaceIds,
                [olderWorkspaceId, newerWorkspaceId]
            )
            XCTAssertEqual(
                followUp.workspaceMonitorRelocations[token],
                newerRelocation
            )
            XCTAssertTrue(followUp.reconcilesWorkspaceMonitorState)
        }
    }

    func testNativeSpaceInventoryFailuresQueueOneGlobalFallback() throws {
        for failure in [
            NativeSpaceWindowInventoryResult.queryFailed,
            NativeSpaceWindowInventoryResult.unavailable
        ] {
            let controller = WindowAdmissionTestSupport.controller()
            let refreshController = controller.layoutRefreshController
            defer { refreshController.resetState() }
            refreshController.nativeSpaceWindowInventoryProvider = { _ in failure }
            refreshController.beginInventoryStabilityBarrier()

            XCTAssertThrowsError(
                try refreshController.resolveNativeSpaceRescanEvidence(
                    scope: .targeted(appPIDs: [], nativeSpaceIds: [901])
                )
            ) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertNil(refreshController.layoutState.activeRefresh)
            XCTAssertNil(refreshController.layoutState.pendingRefresh)
            let fallback = try XCTUnwrap(
                refreshController.layoutState.inventoryStabilityHeldFullRescan
            )
            XCTAssertEqual(fallback.kind, .fullRescan)
            XCTAssertEqual(fallback.reason, .staleFullRescan)
            XCTAssertEqual(fallback.rescanScope, .all)
        }
    }

    func testAuthoritativeEmptyNativeSpaceInventoryDoesNotFallback() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }
        refreshController.nativeSpaceWindowInventoryProvider = {
            XCTAssertEqual($0, [902])
            return .authoritative([902: []])
        }

        let evidence = try refreshController.resolveNativeSpaceRescanEvidence(
            scope: .targeted(appPIDs: [], nativeSpaceIds: [902])
        )

        XCTAssertTrue(evidence.resolvedPIDs.isEmpty)
        XCTAssertTrue(evidence.windowIds.isEmpty)
        XCTAssertTrue(evidence.windowServerInfoByWindowId.isEmpty)
        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        XCTAssertNil(refreshController.layoutState.inventoryStabilityHeldFullRescan)
    }

    func testHelperTerminationTargetsSurvivingLogicalRootsBeforeAliasCleanup() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let logicalToken = WindowToken(pid: 468_200, windowId: 468_201)
        let helperPID: pid_t = 468_202
        let helperToken = WindowToken(pid: helperPID, windowId: 468_203)
        let logicalAXRef = WindowAdmissionTestSupport.axRef(for: logicalToken)
        let helperAXRef = AXWindowRef(
            element: AXUIElementCreateApplication(helperPID),
            windowId: logicalToken.windowId
        )
        _ = controller.workspaceManager.addWindow(
            logicalAXRef,
            pid: logicalToken.pid,
            windowId: logicalToken.windowId,
            to: workspaceId
        )
        let helperTrackedAXRef = WindowAdmissionTestSupport.track(
            helperToken,
            in: workspaceId,
            controller: controller
        )
        controller.axEventHandler.updateIdentityAliases([
            logicalToken.windowId: .init(
                pids: [logicalToken.pid, helperPID],
                axRefs: [logicalAXRef, helperAXRef]
            )
        ])
        let rebindWindowId = UInt32(helperToken.windowId)
        controller.axEventHandler.admissionRetryStateByWindowId[rebindWindowId] =
            AdmissionRetryState(
                expectedToken: helperToken,
                axRef: helperTrackedAXRef,
                reason: .factsDeferred,
                attempt: 1,
                generation: 1,
                trigger: .identityRebind(
                    oldWindow: AXManagedWindowIdentity(
                        token: logicalToken,
                        axRef: logicalAXRef
                    ),
                    newWindow: AXManagedWindowIdentity(
                        token: helperToken,
                        axRef: helperTrackedAXRef
                    ),
                    managedReplacementMetadata: nil,
                    admissionHints: nil,
                    sizeConstraints: nil
                ),
                exhausted: false
            )
        controller.axEventHandler.protectDeferredReplacement(
            windowId: rebindWindowId,
            token: logicalToken,
            scope: .all
        )
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.processCreatedWindow(windowId: rebindWindowId)
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        XCTAssertTrue(controller.axEventHandler.isCreatedWindowDeferred(rebindWindowId))
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        controller.serviceLifecycleManager.handleAppTerminated(pid: helperPID)

        let activeRefresh = try XCTUnwrap(refreshController.layoutState.activeRefresh)
        XCTAssertEqual(activeRefresh.kind, .fullRescan)
        XCTAssertEqual(
            activeRefresh.rescanScope,
            .targeted(appPIDs: [logicalToken.pid], nativeSpaceIds: [])
        )
        XCTAssertEqual(
            controller.axEventHandler.identityAliasesByWindowId[logicalToken.windowId]?.current?.pids,
            [logicalToken.pid]
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: logicalToken))
        XCTAssertNil(controller.workspaceManager.entry(for: helperToken))
        XCTAssertNil(
            controller.axEventHandler.deferredReplacementProtectionsByWindowId[rebindWindowId]
        )
        XCTAssertFalse(controller.axEventHandler.isCreatedWindowDeferred(rebindWindowId))
    }

    func testInventoryStabilityBarrierHoldsFullRescanUntilEnded() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.beginInventoryStabilityBarrier()
        refreshController.requestFullRescan(reason: .startup)

        XCTAssertNil(refreshController.layoutState.activeRefresh)
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.inventoryStabilityHeldFullRescan).kind,
            .fullRescan
        )

        refreshController.endInventoryStabilityBarrier()

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.activeRefresh).kind,
            .fullRescan
        )
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
    }

    func testInventoryStabilityBarrierAllowsRelayoutWhileFullRescanWaits() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.beginInventoryStabilityBarrier()
        refreshController.requestImmediateRelayout(reason: .layoutCommand)
        refreshController.requestFullRescan(reason: .startup)

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.activeRefresh).kind,
            .immediateRelayout
        )
        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.inventoryStabilityHeldFullRescan).kind,
            .fullRescan
        )
    }

    func testInventoryStabilityBarrierDoesNotLetHeldFullRescanBlockLaterRelayout() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        defer { refreshController.resetState() }

        refreshController.beginInventoryStabilityBarrier()
        refreshController.requestFullRescan(reason: .startup)
        refreshController.requestImmediateRelayout(reason: .layoutCommand)

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.activeRefresh).kind,
            .immediateRelayout
        )
        XCTAssertNil(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.inventoryStabilityHeldFullRescan).kind,
            .fullRescan
        )
    }

    func testCancelledFullRescanScopeSurvivesAndMerges() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .activeSpaceChanged,
            rescanScope: .targeted(
                appPIDs: [],
                nativeSpaceIds: [601],
                nativeSpaceWindowIdsByPID: [601: [6_001]]
            )
        )
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .fullRescan,
                reason: .appLaunched,
                rescanScope: .targeted(appPIDs: [701], nativeSpaceIds: [])
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.pendingRefresh).rescanScope,
            .targeted(
                appPIDs: [701],
                nativeSpaceIds: [601],
                nativeSpaceWindowIdsByPID: [601: [6_001]]
            )
        )
    }

    func testCancelledFullRescanRoutesNewerRelocationToRetainedFollowUp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let token = WindowToken(pid: 709, windowId: 7_009)
        let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 19, y: 29, width: 800, height: 600)
            ),
            allowsTerminalRecovery: true
        )
        let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 39, y: 49, width: 900, height: 700)
            ),
            allowsTerminalRecovery: false
        )
        refreshController.layoutState.pendingRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [newerRelocation],
            reconcilesWorkspaceMonitorState: true
        )
        defer { refreshController.resetState() }
        var cancelledFullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
        )
        cancelledFullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [token: olderRelocation],
            reconcilesWorkspaceMonitorState: true
        )

        refreshController.preserveCancelledRefreshState(cancelledFullRescan)

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertFalse(pending.subsumesRelayout)
        XCTAssertTrue(pending.workspaceMonitorRelocations.isEmpty)
        XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
        let followUp = try XCTUnwrap(pending.followUpRefresh)
        XCTAssertEqual(followUp.kind, .immediateRelayout)
        XCTAssertEqual(
            followUp.workspaceMonitorRelocations[token],
            newerRelocation
        )
        XCTAssertTrue(followUp.reconcilesWorkspaceMonitorState)
    }

    func testCancelledFullRescanAppliesNewerActionBearingRelocationInPrimary() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let token = WindowToken(pid: 710, windowId: 7_010)
        let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 20, y: 30, width: 800, height: 600)
            ),
            allowsTerminalRecovery: true
        )
        let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 40, y: 50, width: 900, height: 700)
            ),
            allowsTerminalRecovery: false
        )
        refreshController.layoutState.pendingRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId],
            postLayout: RefreshPostLayoutAction(action: {}),
            workspaceMonitorRelocations: [newerRelocation],
            reconcilesWorkspaceMonitorState: true
        )
        defer { refreshController.resetState() }
        var cancelledFullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
        )
        cancelledFullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [token: olderRelocation],
            reconcilesWorkspaceMonitorState: true
        )

        refreshController.preserveCancelledRefreshState(cancelledFullRescan)

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.workspaceMonitorRelocations[token], newerRelocation)
        XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        XCTAssertNil(pending.followUpRefresh?.workspaceMonitorRelocations[token])
        XCTAssertTrue(pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true)
        XCTAssertEqual(pending.postLayoutActions.count, 1)
    }

    func testCancelledOlderRelayoutDropsMetadataSupersededByNewerFullFollowUp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let token = WindowToken(pid: 711, windowId: 7_011)
        let olderRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 21, y: 31, width: 800, height: 600)
            ),
            allowsTerminalRecovery: true
        )
        let newerRelocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: token,
                frame: CGRect(x: 41, y: 51, width: 900, height: 700)
            ),
            allowsTerminalRecovery: false
        )
        var pendingFullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
        )
        pendingFullRescan.followUpRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId],
            workspaceMonitorRelocations: [token: newerRelocation],
            reconcilesWorkspaceMonitorState: true
        )
        refreshController.layoutState.pendingRefresh = pendingFullRescan
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [workspaceId],
                workspaceMonitorRelocations: [olderRelocation],
                reconcilesWorkspaceMonitorState: true
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertNil(pending.workspaceMonitorRelocations[token])
        XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        XCTAssertEqual(
            pending.followUpRefresh?.workspaceMonitorRelocations[token],
            newerRelocation
        )
        XCTAssertTrue(
            pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true
        )
    }

    func testCancelledReconciliationSurvivesDisjointNewerFullFollowUp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let primaryWorkspaceId = UUID()
        let followUpWorkspaceId = UUID()
        var pendingFullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [711], nativeSpaceIds: [])
        )
        pendingFullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [followUpWorkspaceId],
            reconcilesWorkspaceMonitorState: true
        )
        refreshController.layoutState.pendingRefresh = pendingFullRescan
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [primaryWorkspaceId],
                reconcilesWorkspaceMonitorState: true
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.reconcilesWorkspaceMonitorState)
        XCTAssertEqual(pending.affectedWorkspaceIds, [primaryWorkspaceId])
        XCTAssertTrue(pending.followUpRefresh?.reconcilesWorkspaceMonitorState == true)
        XCTAssertEqual(
            pending.followUpRefresh?.affectedWorkspaceIds,
            [followUpWorkspaceId]
        )
    }

    func testCancelledTargetedFullRescanSubsumesPendingRelayout() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        refreshController.layoutState.pendingRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            affectedWorkspaceIds: [workspaceId]
        )
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .fullRescan,
                reason: .appLaunched,
                rescanScope: .targeted(appPIDs: [702], nativeSpaceIds: [])
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertEqual(pending.rescanScope, .targeted(appPIDs: [702], nativeSpaceIds: []))
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertEqual(pending.affectedWorkspaceIds, [workspaceId])
        XCTAssertNil(pending.followUpRefresh)
    }

    func testCancelledRelayoutIsSubsumedByPendingTargetedFullRescan() throws {
        try assertCancelledLayoutIsSubsumedByPendingTargetedFullRescan(
            kind: .relayout,
            reason: .workspaceConfigChanged,
            pid: 703
        )
    }

    func testCancelledImmediateRelayoutIsSubsumedByPendingTargetedFullRescan() throws {
        try assertCancelledLayoutIsSubsumedByPendingTargetedFullRescan(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            pid: 704
        )
    }

    func testCancelledRelayoutDefersBehindPendingWindowRemoval() throws {
        try assertCancelledLayoutDefersBehindPendingWindowRemoval(
            kind: .relayout,
            reason: .workspaceConfigChanged
        )
    }

    func testCancelledImmediateRelayoutDefersBehindPendingWindowRemoval() throws {
        try assertCancelledLayoutDefersBehindPendingWindowRemoval(
            kind: .immediateRelayout,
            reason: .layoutCommand
        )
    }

    func testTargetedFullRescanForwardsSubsumedWorkspaceGateInPrimaryCycle() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let monitor = Monitor(
            id: .init(displayId: 70_500),
            displayId: 70_500,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Rescan Gate"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "1",
                layoutType: .niri,
                controller: controller
            )
        )
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        controller.niriLayoutHandler.enableNiriLayout()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        let token = WindowToken(pid: 705, windowId: 7_005)
        _ = WindowAdmissionTestSupport.track(
            token,
            in: workspaceId,
            controller: controller
        )
        controller.workspaceManager.invalidateLayout(for: [workspaceId])
        let plannedSeq = controller.workspaceManager.worldSeq
        var actionRefreshKind: LayoutRefreshController.ScheduledRefreshKind?
        var ranInvalidatedAction = false
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                affectedWorkspaceIds: [workspaceId],
                postLayout: RefreshPostLayoutAction(
                    workspaceSeqs: [workspaceId: plannedSeq],
                    domains: .layoutCommit,
                    action: {
                        actionRefreshKind = refreshController.layoutState.activeRefresh?.kind
                    },
                    invalidatedAction: {
                        ranInvalidatedAction = true
                    }
                )
            )
        )
        refreshController.startNextRefreshIfNeeded()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(actionRefreshKind, .fullRescan)
        XCTAssertFalse(ranInvalidatedAction)
        XCTAssertGreaterThan(controller.workspaceManager.worldSeq, plannedSeq)
    }

    func testCancelledLayoutPrecedesNewerSubsumedFullRescanAction() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        var actionOrder: [String] = []
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [706], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.mergePendingRefresh(
            .init(
                kind: .immediateRelayout,
                reason: .layoutCommand,
                postLayout: RefreshPostLayoutAction(action: {
                    actionOrder.append("newer")
                })
            )
        )
        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .relayout,
                reason: .workspaceConfigChanged,
                postLayout: RefreshPostLayoutAction(action: {
                    actionOrder.append("older")
                })
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertNil(pending.followUpRefresh)
        for action in pending.postLayoutActions {
            action.runIfCurrent(using: controller.workspaceManager)
        }
        XCTAssertEqual(actionOrder, ["older", "newer"])
    }

    func testCompletedFullRescanFollowUpPrecedesWorkQueuedWhileActive() async {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        var actionRefreshReason: RefreshReason?
        var fullRescan = LayoutRefreshController.ScheduledRefresh(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [707], nativeSpaceIds: [])
        )
        fullRescan.followUpRefresh = .init(
            kind: .relayout,
            reason: .workspaceConfigChanged
        )
        refreshController.layoutState.pendingRefresh = fullRescan
        defer { refreshController.resetState() }

        refreshController.startNextRefreshIfNeeded()
        refreshController.enqueueRefresh(
            .init(
                kind: .relayout,
                reason: .layoutConfigChanged,
                postLayout: RefreshPostLayoutAction(action: {
                    actionRefreshReason = refreshController.layoutState.activeRefresh?.reason
                })
            )
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(actionRefreshReason, .layoutConfigChanged)
    }

    private func assertCancelledLayoutDefersBehindPendingWindowRemoval(
        kind: LayoutRefreshController.ScheduledRefreshKind,
        reason: RefreshReason
    ) throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        let postLayoutAction = RefreshPostLayoutAction(action: {})
        let relocationToken = WindowToken(pid: 708, windowId: 7_008)
        let relocation = LayoutRefreshController.ScheduledWorkspaceMonitorRelocation(
            relocation: .init(
                workspaceId: workspaceId,
                token: relocationToken,
                frame: CGRect(x: 8, y: 9, width: 800, height: 600)
            ),
            allowsTerminalRecovery: true
        )
        refreshController.layoutState.pendingRefresh = .init(
            kind: .windowRemoval,
            reason: .windowDestroyed,
            windowRemovalPayload: .init(
                workspaceId: workspaceId,
                layoutType: .niri,
                removedNodeId: nil,
                removedNiriColumn: false,
                niriOldFrames: [:],
                shouldRecoverFocus: false,
                allowsPreferredRecoveryToken: false
            )
        )
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: kind,
                reason: reason,
                affectedWorkspaceIds: [workspaceId],
                postLayout: postLayoutAction,
                workspaceMonitorRelocations: [relocation]
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .windowRemoval)
        XCTAssertEqual(pending.postLayoutActions.count, 1)
        XCTAssertNil(pending.workspaceMonitorRelocations[relocationToken])
        XCTAssertFalse(pending.reconcilesWorkspaceMonitorState)
        XCTAssertEqual(pending.followUpRefresh?.kind, kind)
        XCTAssertEqual(pending.followUpRefresh?.reason, reason)
        XCTAssertEqual(pending.followUpRefresh?.affectedWorkspaceIds, [workspaceId])
        XCTAssertTrue(
            pending.followUpRefresh?
                .workspaceMonitorRelocations[relocationToken]?
                .allowsTerminalRecovery == true
        )
        XCTAssertEqual(
            pending.followUpRefresh?.reconcilesWorkspaceMonitorState,
            reason == .workspaceConfigChanged
        )
    }

    private func assertCancelledLayoutIsSubsumedByPendingTargetedFullRescan(
        kind: LayoutRefreshController.ScheduledRefreshKind,
        reason: RefreshReason,
        pid: pid_t
    ) throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        let workspaceId = UUID()
        var postLayoutActionRan = false
        let postLayoutAction = RefreshPostLayoutAction(action: {
            postLayoutActionRan = true
        })
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .appLaunched,
            rescanScope: .targeted(appPIDs: [pid], nativeSpaceIds: [])
        )
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: kind,
                reason: reason,
                affectedWorkspaceIds: [workspaceId],
                postLayout: postLayoutAction
            )
        )

        let pending = try XCTUnwrap(refreshController.layoutState.pendingRefresh)
        XCTAssertEqual(pending.kind, .fullRescan)
        XCTAssertTrue(pending.subsumesRelayout)
        XCTAssertEqual(pending.affectedWorkspaceIds, [workspaceId])
        XCTAssertNil(pending.followUpRefresh)
        let subsumedAction = try XCTUnwrap(pending.postLayoutActions.first)
        XCTAssertFalse(postLayoutActionRan)
        subsumedAction.runIfCurrent(using: controller.workspaceManager)
        XCTAssertTrue(postLayoutActionRan)
    }

    func testCancelledOlderNativeSpaceCannotReplaceNewerPendingSpace() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let refreshController = controller.layoutRefreshController
        refreshController.layoutState.pendingRefresh = .init(
            kind: .fullRescan,
            reason: .activeSpaceChanged,
            rescanScope: .targeted(
                appPIDs: [],
                nativeSpaceIds: [802],
                nativeSpaceWindowIdsByPID: [802: [8_002]]
            )
        )
        defer { refreshController.resetState() }

        refreshController.preserveCancelledRefreshState(
            .init(
                kind: .fullRescan,
                reason: .activeSpaceChanged,
                rescanScope: .targeted(
                    appPIDs: [],
                    nativeSpaceIds: [801],
                    nativeSpaceWindowIdsByPID: [801: [8_001]]
                )
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(refreshController.layoutState.pendingRefresh).rescanScope,
            .targeted(
                appPIDs: [],
                nativeSpaceIds: [802],
                nativeSpaceWindowIdsByPID: [802: [8_002]]
            )
        )
    }
}
