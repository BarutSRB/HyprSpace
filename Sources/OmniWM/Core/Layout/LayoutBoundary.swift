// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct LayoutWindowSnapshot {
    let token: WindowToken
    let constraints: WindowSizeConstraints
    let hiddenState: HiddenState?
    let layoutReason: LayoutReason
    let nativeFullscreenOriginalToken: WindowToken?

    init(
        token: WindowToken,
        constraints: WindowSizeConstraints,
        hiddenState: HiddenState?,
        layoutReason: LayoutReason,
        nativeFullscreenOriginalToken: WindowToken? = nil
    ) {
        self.token = token
        self.constraints = constraints
        self.hiddenState = hiddenState
        self.layoutReason = layoutReason
        self.nativeFullscreenOriginalToken = nativeFullscreenOriginalToken
    }

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
    let excludedTokens: Set<WindowToken>
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
    let excludedTokens: Set<WindowToken>
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
    let excludedTokens: Set<WindowToken>
    let plannedSeq: UInt64
    let preferredFocusToken: WindowToken?
    let preferredHideSide: HideSide
    let settings: ResolvedDwindleSettings
    let isActiveWorkspace: Bool
}

struct DwindleAnimationGeometryContext: Equatable {
    let monitorId: Monitor.ID
    let displayId: CGDirectDisplayID
    let workingFrame: CGRect
    let fullscreenLayoutFrame: CGRect
    let scale: CGFloat
    let settings: ResolvedDwindleSettings
    let tabRailWidth: CGFloat
}

struct DwindleAnimationTargetCandidate {
    let workspaceId: WorkspaceDescriptor.ID
    let engineIdentifier: ObjectIdentifier
    let geometry: DwindleAnimationGeometryContext
    let targetFrames: [WindowToken: CGRect]
}

enum DwindleAnimationTargetDisposition {
    case replace(DwindleAnimationTargetCandidate)
    case clear(engineIdentifier: ObjectIdentifier, geometry: DwindleAnimationGeometryContext)
}

struct FrameMutationComponents: OptionSet, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let position = Self(rawValue: 1 << 0)
    static let size = Self(rawValue: 1 << 1)
    static let all: Self = [.position, .size]
}

struct LayoutFrameChange {
    let token: WindowToken
    let frame: CGRect
    let components: FrameMutationComponents
    let forceApply: Bool
    let allowsTerminalRecovery: Bool

    init(
        token: WindowToken,
        frame: CGRect,
        components: FrameMutationComponents = .all,
        forceApply: Bool,
        allowsTerminalRecovery: Bool = false
    ) {
        self.token = token
        self.frame = frame
        self.components = components
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

struct NativeFullscreenSlotProjection: Equatable {
    let currentToken: WindowToken
    let frame: CGRect
    let visible: Bool
}

struct TabRailGeometryCommand: Equatable {
    let key: TabRailKey
    let tileFrame: CGRect
    let visibleTileFrame: CGRect
}

// `frameChanges` imply active, restore-eligible windows for this pass.
// `visibilityChanges` are reserved for explicit hide/show transitions.
struct WorkspaceLayoutDiff {
    var frameChanges: [LayoutFrameChange] = []
    var visibilityChanges: [LayoutVisibilityChange] = []
    var restoreChanges: [LayoutRestoreChange] = []
    var deferredHides: [LayoutDeferredHide] = []
    var nativeFullscreenSlots: [WindowToken: NativeFullscreenSlotProjection] = [:]
    var tabRailGeometryCommands: [TabRailGeometryCommand] = []
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
    var dwindleAnimationTargetDisposition: DwindleAnimationTargetDisposition?
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
