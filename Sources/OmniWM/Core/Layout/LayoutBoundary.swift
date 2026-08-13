// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct LayoutWindowSnapshot {
    let token: WindowToken
    let constraints: WindowSizeConstraints
    let hiddenState: HiddenState?
    let layoutReason: LayoutReason

    var isNativeFullscreenSuspended: Bool {
        layoutReason == .nativeFullscreen
    }
}

struct LayoutMonitorSnapshot {
    let monitorId: Monitor.ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let workingFrame: CGRect
    let fullscreenLayoutFrame: CGRect
    let scale: CGFloat
    let orientation: Monitor.Orientation
}

struct WorkspaceRefreshInput {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let plannedSeq: UInt64
    let isActiveWorkspace: Bool
}

struct NiriWindowRemovalSeed {
    let removedNodeIds: [NodeId]
    let oldFrames: [WindowToken: CGRect]
    let removedColumn: Bool
}

struct NiriWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let plannedSeq: UInt64
    let viewportState: ViewportState
    let preferredFocusToken: WindowToken?
    let hasCompletedInitialRefresh: Bool
    let useScrollAnimationPath: Bool
    let removalSeed: NiriWindowRemovalSeed?
    let gap: CGFloat
    let outerGaps: LayoutGaps.OuterGaps
    let displayRefreshRate: Double
    let isActiveWorkspace: Bool
}

struct DwindleWorkspaceSnapshot {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    let windows: [LayoutWindowSnapshot]
    let plannedSeq: UInt64
    let preferredFocusToken: WindowToken?
    let preferredHideSide: HideSide
    let settings: ResolvedDwindleSettings
    let isActiveWorkspace: Bool
}

struct LayoutFrameChange {
    let token: WindowToken
    let frame: CGRect
    let forceApply: Bool
    let allowsTerminalRecovery: Bool

    init(
        token: WindowToken,
        frame: CGRect,
        forceApply: Bool,
        allowsTerminalRecovery: Bool = false
    ) {
        self.token = token
        self.frame = frame
        self.forceApply = forceApply
        self.allowsTerminalRecovery = allowsTerminalRecovery
    }
}

struct LayoutRestoreChange {
    let token: WindowToken
    let hiddenState: HiddenState
}

enum LayoutVisibilityChange {
    case show(WindowToken)
    case hide(WindowToken, side: HideSide)
}

struct LayoutDeferredHide {
    let token: WindowToken
    let side: HideSide
    let revealToken: WindowToken
}

// `frameChanges` imply active, restore-eligible windows for this pass.
// `visibilityChanges` are reserved for explicit hide/show transitions.
struct WorkspaceLayoutDiff {
    var frameChanges: [LayoutFrameChange] = []
    var visibilityChanges: [LayoutVisibilityChange] = []
    var restoreChanges: [LayoutRestoreChange] = []
    var deferredHides: [LayoutDeferredHide] = []
}

struct WorkspaceSessionPatch {
    let workspaceId: WorkspaceDescriptor.ID
    var viewportState: ViewportState?
    var rememberedFocusToken: WindowToken?
    var plannedSeq: UInt64 = 0
}

enum AnimationDirective {
    case none
    case startNiriScroll(workspaceId: WorkspaceDescriptor.ID)
    case startDwindleAnimation(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID)
    case activateWindow(token: WindowToken)
}

struct RefreshVisibilityEffect: Equatable {}

struct EffectPlanEffects {
    var visibility: RefreshVisibilityEffect?
    var focusValidationWorkspaceIds: [WorkspaceDescriptor.ID] = []
    var focusValidationPreferredTokens: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var suppressWindowActivation: Bool = false
    var markInitialRefreshComplete: Bool = false
    var drainDeferredCreatedWindows: Bool = false
    var subscribeManagedWindows: Bool = false
}

struct WorkspaceLayoutPlan {
    let workspaceId: WorkspaceDescriptor.ID
    let monitor: LayoutMonitorSnapshot
    var sessionPatch: WorkspaceSessionPatch
    var diff: WorkspaceLayoutDiff
    var niriRestorePlacements: [WindowToken: PersistedNiriPlacement] = [:]
    var animationDirectives: [AnimationDirective] = []
    var isAnimationTick = false
    var isActiveWorkspace = true
}

struct RefreshPostLayoutAction {
    let workspaceSeqs: [WorkspaceDescriptor.ID: UInt64]
    let domains: InvalidationDomain
    private let action: @MainActor () -> Void
    private let invalidatedAction: (@MainActor () -> Void)?

    init(
        workspaceSeqs: [WorkspaceDescriptor.ID: UInt64] = [:],
        domains: InvalidationDomain = [.workspace, .layout, .focus, .fullscreen],
        action: @escaping @MainActor () -> Void,
        invalidatedAction: (@MainActor () -> Void)? = nil
    ) {
        self.workspaceSeqs = workspaceSeqs
        self.domains = domains
        self.action = action
        self.invalidatedAction = invalidatedAction
    }

    @MainActor
    func isCurrent(using workspaceManager: WorkspaceManager) -> Bool {
        for (workspaceId, plannedSeq) in workspaceSeqs {
            guard workspaceManager.isSeqCurrent(
                plannedSeq,
                for: workspaceId,
                domains: domains
            ) else {
                return false
            }
        }
        return true
    }

    @MainActor
    func currentWorkspaces(using workspaceManager: WorkspaceManager) -> Set<WorkspaceDescriptor.ID> {
        var current: Set<WorkspaceDescriptor.ID> = []
        for (workspaceId, plannedSeq) in workspaceSeqs
            where workspaceManager.isSeqCurrent(plannedSeq, for: workspaceId, domains: domains)
        {
            current.insert(workspaceId)
        }
        return current
    }

    func hasWorkspace(in workspaceIds: Set<WorkspaceDescriptor.ID>) -> Bool {
        guard !workspaceSeqs.isEmpty else { return false }
        for workspaceId in workspaceSeqs.keys where workspaceIds.contains(workspaceId) {
            return true
        }
        return false
    }

    func forwarded(
        by acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq],
        currentAtEntry: Set<WorkspaceDescriptor.ID>
    ) -> RefreshPostLayoutAction {
        var seqs = workspaceSeqs
        var changed = false
        for workspaceId in workspaceSeqs.keys {
            guard let accepted = acceptedSeqs[workspaceId],
                  currentAtEntry.contains(workspaceId),
                  accepted.domains.intersection(domains) == domains
            else {
                continue
            }
            seqs[workspaceId] = accepted.after
            changed = true
        }
        guard changed else { return self }
        return RefreshPostLayoutAction(
            workspaceSeqs: seqs,
            domains: domains,
            action: action,
            invalidatedAction: invalidatedAction
        )
    }

    @MainActor
    func runIfCurrent(using workspaceManager: WorkspaceManager) {
        guard isCurrent(using: workspaceManager) else {
            invalidatedAction?()
            return
        }
        action()
    }
}

struct AcceptedSeq {
    let after: UInt64
    let domains: InvalidationDomain
}

struct EffectPlan {
    var workspacePlans: [WorkspaceLayoutPlan] = []
    var effects: EffectPlanEffects = .init()
    var postLayoutActions: [RefreshPostLayoutAction] = []
}
