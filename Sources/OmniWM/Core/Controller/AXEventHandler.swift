// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum ActivationRetryReason: String, Equatable {
    case missingFocusedWindow = "missing_focused_window"
    case pendingFocusMismatch = "pending_focus_mismatch"
    case pendingFocusUnmanagedToken = "pending_focus_unmanaged_token"
    case retryExhausted = "retry_exhausted"
}

private enum ActivationRequestDisposition {
    case matchesActiveRequest(ManagedFocusRequest)
    case conflictsWithPendingRequest(ManagedFocusRequest)
    case unrelatedNoRequest
}

struct ManagedReplacementFocusKey: Hashable, Equatable {
    let pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
}

enum ActivationCallOrigin: String {
    case external
    case probe
    case retry
}

enum ManagedBorderReapplyPhase: String, Equatable {
    case postLayout
    case animationSettled
    case retryExhaustedFallback
}

struct NiriCreateFocusTraceEvent: Equatable {
    enum Kind: Equatable {
        case createSeen(windowId: UInt32)
        case createRetryScheduled(
            windowId: UInt32,
            pid: pid_t?,
            reason: WindowAdmissionPendingReason,
            attempt: Int
        )
        case admissionRejected(windowId: UInt32, pid: pid_t?, reason: WindowAdmissionRejectionReason)
        case createPlacementResolved(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            rung: WorkspacePlacementRung,
            pendingWorkspaceId: WorkspaceDescriptor.ID?,
            pendingMonitorId: Monitor.ID?,
            focusedWorkspaceId: WorkspaceDescriptor.ID?,
            focusedMonitorId: Monitor.ID?,
            nativeSpaceMonitorId: Monitor.ID?,
            frameMonitorId: Monitor.ID?,
            interactionWorkspaceId: WorkspaceDescriptor.ID?,
            interactionMonitorId: Monitor.ID?,
            ruleSkipReason: WorkspaceRuleSkipReason?
        )
        case candidateTracked(token: WindowToken, axPid: pid_t?, workspaceId: WorkspaceDescriptor.ID)
        case relayoutActivatedWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case pendingFocusStarted(requestId: UInt64, token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
        case activationSourceObserved(pid: pid_t, source: ActivationEventSource)
        case activationDeferred(
            requestId: UInt64,
            token: WindowToken,
            source: ActivationEventSource,
            reason: ActivationRetryReason,
            attempt: Int
        )
        case focusConfirmed(token: WindowToken, workspaceId: WorkspaceDescriptor.ID, source: ActivationEventSource)
        case borderReapplied(token: WindowToken, phase: ManagedBorderReapplyPhase)
        case provisionalNonManagedFocusEntered(pid: pid_t, source: ActivationEventSource)
        case nonManagedFallbackEntered(pid: pid_t, source: ActivationEventSource)
    }

    let timestamp: Date
    let kind: Kind

    init(
        timestamp: Date = Date(),
        kind: Kind
    ) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

struct WindowCreatePlacementContext: Equatable {
    let nativeSpaceMonitorId: Monitor.ID?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    let pendingFocusedMonitorId: Monitor.ID?
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let focusedMonitorId: Monitor.ID?
    let interactionWorkspaceId: WorkspaceDescriptor.ID?
    let interactionMonitorId: Monitor.ID?
    let createdAt: Date
}

extension NiriCreateFocusTraceEvent: CustomStringConvertible {
    var description: String {
        switch kind {
        case let .createSeen(windowId):
            "create_seen window=\(windowId)"
        case let .createRetryScheduled(windowId, pid, reason, attempt):
            "create_retry_scheduled window=\(windowId) pid=\(pid.map(String.init) ?? "nil") reason=\(reason.rawValue) attempt=\(attempt)"
        case let .admissionRejected(windowId, pid, reason):
            "admission_rejected window=\(windowId) pid=\(pid.map(String.init) ?? "nil") reason=\(reason.rawValue)"
        case let .createPlacementResolved(
            token,
            workspaceId,
            rung,
            pendingWorkspaceId,
            pendingMonitorId,
            focusedWorkspaceId,
            focusedMonitorId,
            nativeSpaceMonitorId,
            frameMonitorId,
            interactionWorkspaceId,
            interactionMonitorId,
            ruleSkipReason
        ):
            "create_placement_resolved token=\(token) workspace=\(workspaceId.uuidString) rung=\(rung.rawValue) rule_skip=\(ruleSkipReason?.rawValue ?? "none") pending_workspace=\(pendingWorkspaceId?.uuidString ?? "nil") pending_monitor=\(String(describing: pendingMonitorId)) focused_workspace=\(focusedWorkspaceId?.uuidString ?? "nil") focused_monitor=\(String(describing: focusedMonitorId)) native_monitor=\(String(describing: nativeSpaceMonitorId)) frame_monitor=\(String(describing: frameMonitorId)) interaction_workspace=\(interactionWorkspaceId?.uuidString ?? "nil") interaction_monitor=\(String(describing: interactionMonitorId))"
        case let .candidateTracked(token, axPid, workspaceId):
            "candidate_tracked token=\(token) ax_pid=\(axPid.map(String.init) ?? "nil") workspace=\(workspaceId.uuidString)"
        case let .relayoutActivatedWindow(token, workspaceId):
            "relayout_activated_window token=\(token) workspace=\(workspaceId.uuidString)"
        case let .pendingFocusStarted(requestId, token, workspaceId):
            "pending_focus_started request=\(requestId) token=\(token) workspace=\(workspaceId.uuidString)"
        case let .activationSourceObserved(pid, source):
            "activation_source_observed pid=\(pid) source=\(source.rawValue)"
        case let .activationDeferred(requestId, token, source, reason, attempt):
            "activation_deferred request=\(requestId) token=\(token) source=\(source.rawValue) reason=\(reason.rawValue) attempt=\(attempt)"
        case let .focusConfirmed(token, workspaceId, source):
            "focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) source=\(source.rawValue)"
        case let .borderReapplied(token, phase):
            "border_reapplied token=\(token) phase=\(phase.rawValue)"
        case let .provisionalNonManagedFocusEntered(pid, source):
            "provisional_non_managed_focus_entered pid=\(pid) source=\(source.rawValue)"
        case let .nonManagedFallbackEntered(pid, source):
            "non_managed_fallback_entered pid=\(pid) source=\(source.rawValue)"
        }
    }
}

private enum FocusedAdmissionAttempt: Equatable {
    case handled
    case admissionPending(WindowAdmissionPendingReason)
    case admissionRejected(WindowAdmissionRejectionReason)
    case rejected
}

@MainActor
final class AXEventHandler {
    struct ManagedReplacementTraceEvent: Equatable {
        enum Kind: Equatable {
            case enqueued(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                deadlineReset: Bool
            )
            case flushed(
                policy: String,
                createCount: Int,
                destroyCount: Int,
                holdCount: Int,
                elapsedMillis: Int
            )
            case matched(policy: String, elapsedMillis: Int)
        }

        let timestamp: TimeInterval
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
        let kind: Kind
    }

    struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let admissionHints: ManagedWindowAdmissionHints
        let replacementMetadata: ManagedReplacementMetadata
        let structuralReplacementMatch: StructuralReplacementMatch?
        let requiresPostCreateLifecycleVerification: Bool
        let interactionPolicy: WindowInteractionPolicy

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    private enum CreatePreparationOutcome {
        case prepared(PreparedCreate)
        case alreadyTracked(WindowToken)
        case identityRebindPending
        case pending(token: WindowToken?, axRef: AXWindowRef?, reason: WindowAdmissionPendingReason)
        case ignored(token: WindowToken?, reason: WindowAdmissionRejectionReason)
    }

    private enum WindowDestroyEvidence {
        case transientLifecycle, windowClosed
    }

    private struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata
        var evidence: WindowDestroyEvidence

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    private struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    private enum ManagedReplacementCorrelationPolicy {
        case structural
    }

    private enum PendingFocusedManagedActivationRequest {
        case matchesActiveRequest(UInt64)
        case conflictsWithPendingRequest(UInt64)
        case unrelatedNoRequest

        init(_ disposition: ActivationRequestDisposition) {
            switch disposition {
            case let .matchesActiveRequest(request):
                self = .matchesActiveRequest(request.requestId)
            case let .conflictsWithPendingRequest(request):
                self = .conflictsWithPendingRequest(request.requestId)
            case .unrelatedNoRequest:
                self = .unrelatedNoRequest
            }
        }

        var requestId: UInt64? {
            switch self {
            case let .matchesActiveRequest(requestId),
                 let .conflictsWithPendingRequest(requestId):
                requestId
            case .unrelatedNoRequest:
                nil
            }
        }
    }

    private struct PendingFocusedManagedActivation {
        let source: ActivationEventSource
        let origin: ActivationCallOrigin
        let observationGeneration: UInt64
        let appFullscreen: Bool
        let request: PendingFocusedManagedActivationRequest
        let callbackGeneration: UInt64?
    }

    private struct WindowCloseFocusRecoveryContext {
        let workspaceId: WorkspaceDescriptor.ID
        let closedToken: WindowToken
        let expiresAt: Date
    }

    private struct RecentMouseFocusIntent {
        let token: WindowToken
        let expiresAt: Date
    }

    private struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
        let focusedActivation: PendingFocusedManagedActivation?
    }

    private struct PendingManagedDestroy {
        let sequence: UInt64
        var candidate: PreparedDestroy
    }

    private enum PendingManagedReplacementEvent {
        case create(PendingManagedCreate)
        case destroy(PendingManagedDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    private struct PendingManagedReplacementBurst {
        let policy: ManagedReplacementCorrelationPolicy
        let firstEventUptime: TimeInterval
        var creates: [PendingManagedCreate] = []
        var destroys: [PendingManagedDestroy] = []

        mutating func append(create: PendingManagedCreate) {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return }
            creates.append(create)
        }

        mutating func append(destroy: PendingManagedDestroy) {
            guard let index = destroys.firstIndex(where: { $0.candidate.token == destroy.candidate.token }) else {
                destroys.append(destroy)
                return
            }
            guard destroys[index].candidate.evidence == .transientLifecycle,
                  destroy.candidate.evidence == .windowClosed
            else {
                return
            }
            destroys[index].candidate.evidence = .windowClosed
        }

        var orderedEvents: [PendingManagedReplacementEvent] {
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys
                .map(PendingManagedReplacementEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        func orderedEvents(excludingSequences sequences: Set<UInt64>) -> [PendingManagedReplacementEvent] {
            orderedEvents.filter { !sequences.contains($0.sequence) }
        }
    }

    private struct MatchedManagedReplacementPair {
        let destroy: PendingManagedDestroy
        let create: PendingManagedCreate

        var excludedSequences: Set<UInt64> {
            [destroy.sequence, create.sequence]
        }
    }

    enum StructuralReplacementMatchSource {
        case pendingDestroy
        case liveInvisible
    }

    struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let source: StructuralReplacementMatchSource
    }

    private static let managedReplacementGraceDelay: Duration = .milliseconds(150)
    static let stabilizationRetryDelay: Duration = .milliseconds(100)
    static let postCreateLifecycleVerificationDelay: Duration = .milliseconds(75)
    static let createdWindowRetryLimit = 5
    static let createPlacementContextTTL: TimeInterval = 15
    private static let activationRetryLimit = 5
    private static let windowCloseFocusRecoveryDuration: TimeInterval = 0.6
    static let sameAppCloseProbeDelay: Duration = .milliseconds(80)
    private static let mouseFocusIntentDuration: TimeInterval = 0.35
    private static let createFocusTraceLimit = 128
    private static let managedReplacementTraceLimit = 128
    private static let createFocusTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_NIRI_CREATE_FOCUS"] == "1"
    private static let managedReplacementTraceLoggingEnabled =
        ProcessInfo.processInfo.environment["OMNIWM_DEBUG_MANAGED_REPLACEMENT"] == "1"

    weak var controller: WMController?
    var deferredCreatedWindowIds: Set<UInt32> = []
    private var deferredCreatedWindowOrder: [UInt32] = []
    var deferredReplacementProtectionsByWindowId: [UInt32: DeferredReplacementProtection] = [:]
    var createPlacementContextsByWindowId: [UInt32: WindowCreatePlacementContext] = [:]
    private var pendingManagedReplacementBursts: [ManagedReplacementKey: PendingManagedReplacementBurst] = [:]
    private var pendingManagedReplacementTasks: [ManagedReplacementKey: Task<Void, Never>] = [:]
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowRuleReevaluationGeneration: UInt64 = 0
    var pendingPostCreateLifecycleVerificationTasks: [WindowToken: Task<Void, Never>] = [:]
    var pendingPostCreateLifecycleVerificationOwners: [WindowToken: UInt64] = [:]
    var nextPostCreateLifecycleVerificationOwner: UInt64 = 1
    var admissionRetryStateByWindowId: [UInt32: AdmissionRetryState] = [:]
    var nextAdmissionRetryGeneration: UInt64 = 1
    var nextAdmissionRetryExecutionOwner: UInt64 = 1
    private var nextActivationObservationGeneration: UInt64 = 1
    private var latestActivationObservationGeneration: UInt64 = 0
    var terminalFrameFailureStateByWindowId: [Int: TerminalFrameFailureState] = [:]
    var admissionQuarantineByWindowId: [Int: AdmissionQuarantine] = [:]
    var identityAliasesByWindowId: [Int: WindowIdentityAliasHistory] = [:]
    private var windowCloseFocusRecoveryContext: WindowCloseFocusRecoveryContext?
    private var recentMouseFocusIntent: RecentMouseFocusIntent?
    private var createFocusTrace =
        RingBuffer<NiriCreateFocusTraceEvent>(capacity: AXEventHandler.createFocusTraceLimit)
    private var managedReplacementTrace =
        RingBuffer<ManagedReplacementTraceEvent>(capacity: AXEventHandler.managedReplacementTraceLimit)
    private var nextManagedReplacementEventSequence: UInt64 = 0
    var visibleWindowInfoProvider: () -> [WindowServerInfo]
    var windowInfoProvider: (UInt32) -> WindowServerInfo?
    var managedWindowIdentityRebindAcknowledgementProvider:
        ((AXManagedWindowIdentity, AXManagedWindowIdentity) async -> Bool)?
    var managedWindowIdentityRebindFinalizationProvider:
        ((AXManagedWindowIdentity, AXManagedWindowIdentity) async -> Bool)?
    var managedWindowIdentityRebindTargetIsAliveProvider: ((pid_t) -> Bool)?

    init(
        controller: WMController,
        visibleWindowInfoProvider: @escaping () -> [WindowServerInfo] = {
            SkyLight.shared.queryAllVisibleWindows()
        },
        windowInfoProvider: @escaping (UInt32) -> WindowServerInfo? = {
            SkyLight.shared.queryWindowInfo($0)
        }
    ) {
        self.controller = controller
        self.visibleWindowInfoProvider = visibleWindowInfoProvider
        self.windowInfoProvider = windowInfoProvider
    }

    func setup() {
        CGSEventObserver.shared.start()
    }

    func cleanup() {
        resetCreatePlacementContextState()
        resetManagedReplacementState()
        endWindowCloseFocusRecovery(reason: "cleanup")
        cancelSameAppCloseProbe(reason: "cleanup")
        resetPostCreateLifecycleVerificationState()
        resetCreatedWindowRetryState()
        terminalFrameFailureStateByWindowId.removeAll()
        admissionQuarantineByWindowId.removeAll()
        identityAliasesByWindowId.removeAll()
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        pendingWindowRuleReevaluationGeneration &+= 1
        CGSEventObserver.shared.stop()
    }

    func handleCGSEvent(_ event: CGSWindowEvent) {
        guard let controller else { return }

        switch event {
        case let .created(windowId, spaceId):
            WindowAdmissionTrace.record(
                .init(action: .cgsCreated, windowId: Int(windowId))
            )
            handleCGSWindowCreated(windowId: windowId, spaceId: spaceId)
            controller.spaceTracker.noteWindowSpace(windowId: Int(windowId), spaceId: spaceId)

        case let .destroyed(windowId, _):
            WindowAdmissionTrace.record(
                .init(action: .cgsDestroyed, windowId: Int(windowId), reason: "destroyed")
            )
            handleCGSSpaceWindowDestroyed(windowId: windowId)

        case let .closed(windowId):
            WindowAdmissionTrace.record(
                .init(action: .cgsDestroyed, windowId: Int(windowId), reason: "closed")
            )
            handleCGSWindowDestroyed(windowId: windowId, evidence: .windowClosed)

        case let .frameChanged(windowId):
            handleFrameChanged(windowId: windowId)

        case let .frontAppChanged(pid):
            if WindowAdmissionTrace.shared.isActive, !isOwnProcessPid(pid) {
                WindowAdmissionTrace.record(
                    .init(
                        action: .frontmostObserved,
                        pid: pid,
                        bundleId: resolveBundleId(pid)
                    )
                )
            }
            handleAppActivation(pid: pid, source: .cgsFrontAppChanged)

        case let .orderChanged(windowId):
            handleWindowOrderChanged(windowId: windowId)

        case let .titleChanged(windowId):
            AXWindowService.invalidateCachedTitle(windowId: windowId)
            controller.requestWorkspaceBarRefresh()
            if let token = resolveTrackedToken(windowId) ?? resolveWindowToken(windowId) {
                updateManagedReplacementTitle(windowId: windowId, token: token)
                scheduleWindowRuleReevaluationIfNeeded(targets: [.window(token)])
            }
        }
    }

    private func handleWindowOrderChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        controller.surfaceReconciler.noteRestackOccurred()
    }

    func scheduleWindowRuleReevaluationIfNeeded(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationGeneration &+= 1
        let generation = pendingWindowRuleReevaluationGeneration
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pendingWindowRuleReevaluationGeneration == generation,
                  let controller = self.controller
            else { return }
            guard controller.niriLayoutHandler.scrollAnimationByDisplay.isEmpty else {
                self.pendingWindowRuleReevaluationTask = nil
                self.scheduleWindowRuleReevaluationIfNeeded(targets: self.pendingWindowRuleReevaluationTargets)
                return
            }
            let targets = self.pendingWindowRuleReevaluationTargets
            self.pendingWindowRuleReevaluationTargets.removeAll()
            self.pendingWindowRuleReevaluationTask = nil
            let outcome = await controller.reevaluateWindowRules(for: targets)
            if outcome.stale {
                self.scheduleWindowRuleReevaluationIfNeeded(targets: targets)
            }
        }
    }

    private func isWindowDisplayable(token: WindowToken) -> Bool {
        guard let controller else { return false }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return false
        }
        return controller.isManagedWindowDisplayable(entry.token)
    }

    private func handleCGSWindowCreated(windowId: UInt32, spaceId: UInt64) {
        captureCreatePlacementContext(windowId: windowId, spaceId: spaceId)
        recordNiriCreateFocusTrace(.init(kind: .createSeen(windowId: windowId)))
        if shouldDeferCreateForInactiveNativeSpace(spaceId) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    windowId: Int(windowId),
                    reason: "inactive_native_space_\(spaceId)",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        processCreatedWindow(windowId: windowId)
    }

    private func shouldDeferCreateForInactiveNativeSpace(_ spaceId: UInt64) -> Bool {
        guard spaceId != 0, let controller else { return false }
        let topology = controller.workspaceManager.spaceTopology
        return topology.isKnownSpace(spaceId) && !topology.isCurrentSpace(spaceId)
    }

    func processCreatedWindow(
        windowId: UInt32,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        retryTrigger: AdmissionRetryTrigger = .create
    ) {
        guard let controller else { return }
        if controller.isDiscoveryInProgress {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    windowId: Int(windowId),
                    reason: "discovery_in_progress",
                    outcome: "deferred"
                )
            )
            deferCreatedWindow(windowId)
            return
        }
        if controller.isOwnedWindow(windowNumber: Int(windowId)) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    windowId: Int(windowId),
                    reason: WindowAdmissionRejectionReason.ownedWindow.rawValue
                )
            )
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }

        let windowInfo = resolveWindowInfo(windowId)
        if let windowInfo, isOwnProcessPid(pid_t(windowInfo.pid)) {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    windowId: Int(windowId),
                    reason: WindowAdmissionRejectionReason.ownedWindow.rawValue
                )
            )
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            removeDeferredCreatedWindow(windowId)
            rejectDeferredReplacement(windowId: windowId)
            return
        }
        let createPlacementContext = pendingCreatePlacementContext(for: Int(windowId))
        let effectivePlacementOrigin = Self.effectivePlacementOrigin(
            placementOrigin,
            createPlacementContext: createPlacementContext
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: fallbackToken,
            fallbackAXRef: fallbackAXRef,
            allowsTrackedIdentityReplacement: retryTrigger.allowsTrackedIdentityReplacement,
            placementOrigin: effectivePlacementOrigin,
            createPlacementContext: createPlacementContext
        )
        guard let candidate = preparedCreateCandidate(
            from: outcome,
            windowId: windowId,
            trigger: retryTrigger
        ) else {
            return
        }

        if completeLiveStructuralReplacementCreate(candidate) {
            return
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(candidate)
            return
        }

        trackPreparedCreate(candidate)
    }

    func probeFocusedWindowAfterFronting(
        expectedToken: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID
    ) {
        let requestId = controller?.intentLedger.activeManagedRequest(for: expectedToken)?.requestId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let requestId,
               self.controller?.intentLedger.activeManagedRequest(requestId: requestId) == nil
            {
                return
            }
            self.handleAppActivation(
                pid: expectedToken.pid,
                source: .focusedWindowChanged,
                origin: .probe
            )
        }
    }

    @discardableResult
    func rekeyStructuralManagedReplacement(
        match: StructuralReplacementMatch,
        token: WindowToken,
        windowId: UInt32,
        axRef: AXWindowRef,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        admissionHints: ManagedWindowAdmissionHints? = nil,
        sizeConstraints: WindowSizeConstraints? = nil
    ) -> Bool {
        let metadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: match.workspaceId,
            mode: mode,
            facts: facts
        )
        let rebindResult = rekeyManagedWindowIdentity(
            from: match.token,
            to: token,
            windowId: windowId,
            axRef: axRef,
            managedReplacementMetadata: metadata,
            admissionHints: admissionHints,
            sizeConstraints: sizeConstraints
        )
        guard rebindResult.isHandled else {
            return false
        }
        return true
    }

    func recordNiriCreateFocusTrace(_ event: NiriCreateFocusTraceEvent) {
        createFocusTrace.append(event)

        if Self.createFocusTraceLoggingEnabled {
            Log.ax.debug("[NiriCreateFocus] \(event.description)")
        }
    }

    func createFocusTraceDump() -> String {
        let events = createFocusTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map { "\($0.timestamp.ISO8601Format()) \($0.description)" }
            .joined(separator: "\n")
    }

    func managedReplacementTraceDump() -> String {
        let events = managedReplacementTrace.snapshot()
        guard !events.isEmpty else { return "none" }
        return events
            .map {
                "uptime=\(String(format: "%.3f", $0.timestamp)) pid=\($0.pid)"
                    + " workspace=\($0.workspaceId.uuidString) \(String(describing: $0.kind))"
            }
            .joined(separator: "\n")
    }

    private func managedReplacementCurrentUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func managedReplacementPolicyName(_ policy: ManagedReplacementCorrelationPolicy) -> String {
        switch policy {
        case .structural:
            "structural"
        }
    }

    private func recordManagedReplacementTrace(
        key: ManagedReplacementKey,
        kind: ManagedReplacementTraceEvent.Kind
    ) {
        let event = ManagedReplacementTraceEvent(
            timestamp: managedReplacementCurrentUptime(),
            pid: key.pid,
            workspaceId: key.workspaceId,
            kind: kind
        )
        managedReplacementTrace.append(event)

        if Self.managedReplacementTraceLoggingEnabled {
            Log.ax.debug(
                "[ManagedReplacement] pid=\(key.pid) workspace=\(key.workspaceId.uuidString) kind=\(String(describing: kind))"
            )
        }
    }

    private func managedReplacementFocusKey(_ key: ManagedReplacementKey) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: key.pid, workspaceId: key.workspaceId)
    }

    private func managedReplacementFocusKey(
        pid: pid_t,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedReplacementFocusKey {
        ManagedReplacementFocusKey(pid: pid, workspaceId: workspaceId)
    }

    func hasPendingManagedReplacementDestroy(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let key = ManagedReplacementKey(pid: token.pid, workspaceId: workspaceId)
        return pendingManagedReplacementBursts[key]?.destroys.contains {
            $0.candidate.token == token
        } == true
    }

    private func selectedNiriWindowToken(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let controller else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = state.selectedNodeId else { return nil }
        return controller.workspaceManager.layoutTopology(for: workspaceId).token(for: selectedNodeId)
    }

    private func niriManagedFocusAnchor(
        for key: ManagedReplacementFocusKey
    ) -> WindowToken? {
        guard let controller else { return nil }
        let topology = controller.workspaceManager.layoutTopology(for: key.workspaceId)

        func eligible(_ token: WindowToken?) -> Bool {
            guard let token,
                  token.pid == key.pid,
                  let entry = controller.workspaceManager.entry(for: token),
                  entry.workspaceId == key.workspaceId,
                  entry.mode == .tiling,
                  topology.containsNiriWindow(token)
            else {
                return false
            }
            return true
        }

        if let selected = selectedNiriWindowToken(in: key.workspaceId),
           eligible(selected)
        {
            return selected
        }

        if let focusedToken = controller.workspaceManager.focusedToken,
           eligible(focusedToken)
        {
            return focusedToken
        }

        return nil
    }

    private func armManagedReplacementFocusTransaction(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        if let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId) {
            controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
                payload.isBurstOpen = true
                payload.protectedTokens.insert(token)
            }
            return
        }

        let key = managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId)
        guard let anchor = niriManagedFocusAnchor(for: key) else { return }
        _ = controller.intentLedger.registerReplacementFocus(
            ReplacementFocusPayload(
                pid: token.pid,
                workspaceId: workspaceId,
                anchorToken: anchor,
                protectedTokens: [anchor, token],
                isBurstOpen: true
            )
        )
    }

    private func markManagedReplacementFocusBurstClosed(for key: ManagedReplacementKey) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.isBurstOpen = false
        }
    }

    func rekeyManagedReplacementFocusTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: oldToken.pid, workspaceId: workspaceId)
        else {
            return
        }
        controller.intentLedger.updateReplacementFocus(id: open.id) { payload in
            payload.rekey(from: oldToken, to: newToken)
            payload.protectedTokens.insert(newToken)
            payload.pid = newToken.pid
        }
    }

    private func clearManagedReplacementFocusTransaction(
        for key: ManagedReplacementFocusKey,
        reason _: String
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: key.pid, workspaceId: key.workspaceId)
        else {
            return
        }
        _ = controller.intentLedger.cancel(id: open.id)
    }

    private func clearManagedReplacementFocusTransaction(
        containing token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        reason: String
    ) {
        guard let transaction = managedReplacementFocusTransaction(for: token, workspaceId: workspaceId),
              transaction.protects(token)
        else {
            return
        }
        clearManagedReplacementFocusTransaction(
            for: managedReplacementFocusKey(pid: token.pid, workspaceId: workspaceId),
            reason: reason
        )
    }

    private func clearManagedReplacementFocusTransactions(
        pid: pid_t,
        reason _: String
    ) {
        guard let controller else { return }
        for intent in controller.intentLedger.openReplacementFocusIntents(pid: pid) {
            _ = controller.intentLedger.cancel(id: intent.id)
        }
    }

    private func managedReplacementFocusTransaction(
        for token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> ReplacementFocusPayload? {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind
        else {
            return nil
        }
        return payload
    }

    private func isProtectedManagedReplacementFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        managedReplacementFocusTransaction(for: token, workspaceId: workspaceId)?.protects(token) == true
    }

    private func completeManagedReplacementFocusTransactionIfNeeded(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller,
              let open = controller.intentLedger.openReplacementFocusIntent(pid: token.pid, workspaceId: workspaceId),
              case let .replacementFocus(payload) = open.kind,
              payload.protects(token),
              !payload.isBurstOpen
        else {
            return
        }
        _ = controller.intentLedger.confirm(id: open.id)
    }

    private func handleFrameChanged(windowId: UInt32) {
        guard let controller else { return }
        guard !controller.isOwnedWindow(windowNumber: Int(windowId)) else { return }
        let retriedAdmission = retryAdmissionAfterFrameChange(windowId: windowId)
        if controller.workspaceManager.entry(forWindowId: Int(windowId)) == nil,
           retriedAdmission
        {
            return
        }
        if let trackedEntry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           trackedEntry.mode == .tiling,
           controller.niriLayoutHandler.hasScrollAnimation(for: trackedEntry.workspaceId)
        {
            return
        }
        let windowServerToken = resolveWindowToken(windowId)
        let resolvedToken = resolveTrackedToken(
            windowId,
            resolvedWindowToken: windowServerToken
        )
        let focusedObservedFrame = observedFrameForFocusedFrameChange(
            windowId: windowId,
            windowServerToken: windowServerToken,
            resolvedToken: resolvedToken
        )
        guard let token = resolvedToken else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else { return }

        guard isWindowDisplayable(token: token) else { return }

        if entry.mode == .floating {
            if let frame = focusedObservedFrame ?? observedFrame(for: entry),
               !shouldSuppressFrameChangedRelayout(for: entry, observedFrame: frame)
            {
                controller.workspaceManager.updateFloatingGeometry(frame: frame, for: token)
                reassignFloatingWindowToContainingMonitor(entry: entry, frame: frame)
            }
            return
        }

        if controller.isInteractiveGestureActive {
            return
        }

        if controller.niriLayoutHandler.hasScrollAnimation(for: entry.workspaceId) {
            return
        }

        if shouldSuppressFrameChangedRelayout(
            for: entry,
            observedFrame: focusedObservedFrame
        ) {
            return
        }

        let suppressionObservedFrame = focusedObservedFrame
            ?? (controller.axManager.lastAppliedFrame(for: entry.windowId) == nil ? nil : observedFrame(for: entry))
        if suppressionObservedFrame != focusedObservedFrame,
           shouldSuppressFrameChangedRelayout(
               for: entry,
               observedFrame: suppressionObservedFrame
           )
        {
            return
        }

        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func shouldSuppressFrameChangedRelayout(
        for entry: WindowState,
        observedFrame: CGRect?
    ) -> Bool {
        guard let controller else { return false }
        if controller.axManager.shouldSuppressFrameChangeRelayout(
            for: entry.windowId,
            observedFrame: observedFrame
        ) {
            return true
        }
        return false
    }

    private func observedFrameForFocusedFrameChange(
        windowId: UInt32,
        windowServerToken: WindowToken?,
        resolvedToken: WindowToken?
    ) -> CGRect? {
        guard let controller else { return nil }
        guard let target = controller.workspaceManager.renderableFocusToken,
              let entry = controller.workspaceManager.entry(for: target)
        else { return nil }

        if let windowServerToken {
            guard windowServerToken == target else { return nil }
        } else {
            guard resolvedToken == target,
                  entry.mode == .floating
            else { return nil }
            if needsFocusedAXConfirmationForUnresolvedFrameChange(entry),
               focusedWindowToken(for: target.pid) != target
            {
                return nil
            }
        }

        guard controller.axManager.pendingFrameWrite(for: entry.windowId) == nil else { return nil }
        guard let frame = observedFrame(for: entry) else { return nil }
        return frame
    }

    private func needsFocusedAXConfirmationForUnresolvedFrameChange(_ entry: WindowState) -> Bool {
        guard let controller else { return true }
        return entry.layoutReason == .nativeFullscreen
            || controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
    }

    private func observedFrame(for entry: WindowState) -> CGRect? {
        observedFrame(for: entry.axRef)
    }

    private func observedFrame(for axRef: AXWindowRef) -> CGRect? {
        AXWindowService.framePreferFast(axRef)
            ?? (try? AXWindowService.frame(axRef))
    }

    private func handleCGSSpaceWindowDestroyed(windowId: UInt32) {
        if resolveWindowInfo(windowId) != nil { return }
        if let controller, let entry = controller.workspaceManager.entry(forWindowId: Int(windowId)),
           controller.workspaceManager.hiddenState(for: entry.token) != nil { return }
        handleCGSWindowDestroyed(windowId: windowId, evidence: .transientLifecycle)
    }

    func subscribeToManagedWindows() {
        guard let controller else { return }
        let windowIds = controller.workspaceManager.allEntries().compactMap { entry -> UInt32? in
            UInt32(entry.windowId)
        }
        subscribeToWindows(windowIds)
    }

    func drainDeferredCreatedWindows(
        spaceIdsForWindow: (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) async {
        guard !deferredCreatedWindowOrder.isEmpty else { return }

        let deferredWindowIds = deferredCreatedWindowOrder
        deferredCreatedWindowOrder.removeAll()
        deferredCreatedWindowIds.removeAll()

        for windowId in deferredWindowIds {
            guard let controller else { return }
            let retryState = admissionRetryStateByWindowId[windowId]
            let retryTrigger = retryState?.trigger ?? .create
            if case .identityRebind = retryTrigger {
                continue
            }
            if controller.isOwnedWindow(windowNumber: Int(windowId)) {
                cancelCreatedWindowRetry(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                rejectDeferredReplacement(windowId: windowId)
                continue
            }
            let windowInfo = resolveWindowInfo(windowId)
            guard let windowInfo else {
                _ = scheduleAdmissionRetry(
                    windowId: windowId,
                    expectedToken: retryState?.expectedToken,
                    axRef: retryState?.axRef,
                    reason: .windowInfoMissing,
                    trigger: retryTrigger
                )
                continue
            }
            if isOwnProcessPid(pid_t(windowInfo.pid)) {
                cancelCreatedWindowRetry(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                rejectDeferredReplacement(windowId: windowId)
                continue
            }
            if shouldDeferCreateForInactiveNativeSpace(
                liveCreateSpace(for: windowId, spaceIdsForWindow: spaceIdsForWindow)
            ) {
                WindowAdmissionTrace.record(
                    .init(
                        action: .admissionPending,
                        pid: pid_t(windowInfo.pid),
                        windowId: Int(windowId),
                        reason: "inactive_native_space",
                        outcome: "deferred"
                    )
                )
                deferCreatedWindow(windowId)
                continue
            }
            let createPlacementContext = pendingCreatePlacementContext(for: Int(windowId))
            let placementOrigin = Self.effectivePlacementOrigin(
                retryTrigger.placementOrigin,
                createPlacementContext: createPlacementContext
            )
            let outcome = prepareCreateCandidate(
                windowId: windowId,
                windowInfo: windowInfo,
                fallbackToken: retryState?.expectedToken,
                fallbackAXRef: retryState?.axRef,
                allowsTrackedIdentityReplacement: retryTrigger.allowsTrackedIdentityReplacement,
                placementOrigin: placementOrigin,
                createPlacementContext: createPlacementContext
            )
            guard let candidate = preparedCreateCandidate(
                from: outcome,
                windowId: windowId,
                trigger: retryTrigger
            ) else {
                continue
            }
            if completeLiveStructuralReplacementCreate(candidate) {
                continue
            }
            if shouldDelayManagedReplacementCreate(candidate) {
                enqueueManagedReplacementCreate(candidate)
            } else {
                trackPreparedCreate(candidate)
            }
        }
    }

    func handleRemoved(
        pid: pid_t,
        winId: Int,
        axRef: AXWindowRef? = nil,
        callbackGeneration: UInt64? = nil
    ) {
        guard let windowId = UInt32(exactly: winId) else { return }
        if let axRef {
            switch managedWindowDestroyDisposition(windowId: winId, axRef: axRef) {
            case .current:
                break
            case .stale:
                WindowAdmissionTrace.record(
                    .init(
                        action: .admissionIgnored,
                        pid: pid,
                        windowId: winId,
                        reason: "stale_destroy_callback",
                        callbackGeneration: callbackGeneration,
                        axRef: axRef
                    )
                )
                return
            case let .waitingIdentityRebindTarget(
                retryGeneration,
                oldWindow,
                newWindow
            ):
                guard cancelDestroyedWaitingManagedWindowIdentityRebind(
                    windowId: windowId,
                    retryGeneration: retryGeneration,
                    oldWindow: oldWindow,
                    newWindow: newWindow,
                    axRef: axRef
                ) else {
                    requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                    return
                }
                AXWindowService.invalidateCachedTitle(windowId: windowId)
                discardCreatePlacementContext(windowId: windowId)
                WindowAdmissionTrace.record(
                    .init(
                        action: .admissionDisappeared,
                        pid: pid,
                        windowId: winId,
                        reason: "identity_rebind_target_destroyed",
                        callbackGeneration: callbackGeneration,
                        axRef: axRef
                    )
                )
                requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                return
            case let .pendingIdentityRebindTarget(
                retryGeneration,
                executionOwner,
                oldWindow,
                newWindow
            ):
                if deferDestroyedPendingManagedWindowIdentityRebind(
                    windowId: windowId,
                    retryGeneration: retryGeneration,
                    executionOwner: executionOwner,
                    oldWindow: oldWindow,
                    newWindow: newWindow,
                    axRef: axRef
                ) {
                    AXWindowService.invalidateCachedTitle(windowId: windowId)
                    discardCreatePlacementContext(windowId: windowId)
                    WindowAdmissionTrace.record(
                        .init(
                            action: .admissionDisappeared,
                            pid: pid,
                            windowId: winId,
                            reason: "identity_rebind_target_destroyed",
                            callbackGeneration: callbackGeneration,
                            axRef: axRef
                        )
                    )
                    requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                    return
                }
                requestTargetedFullRescan(for: [oldWindow.token.pid, newWindow.token.pid])
                return
            }
        }
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        rejectDeferredReplacement(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        handleWindowDestroyed(
            windowId: windowId,
            pidHint: pid,
            expectedWindow: axRef,
            callbackGeneration: callbackGeneration,
            evidence: .transientLifecycle
        )
    }

    func handleRemoved(token: WindowToken) {
        handleRemoved(token: token, evidence: .transientLifecycle)
    }

    private func discardRemovedWindowRuntimeState(_ token: WindowToken) {
        clearTerminalFrameFailure(windowId: token.windowId)
        if let windowId = UInt32(exactly: token.windowId) {
            cancelCreatedWindowRetry(windowId: windowId)
        }
        cancelPostCreateLifecycleVerification(for: token)
        guard let controller else { return }
        if controller.workspaceManager.entry(forWindowId: token.windowId) == nil {
            controller.axManager.removeWindowLedgerState(pid: token.pid, windowId: token.windowId)
            controller.axManager.bindManagedWindows(
                controller.workspaceManager.entries(forPid: token.pid)
            )
        }
        requestTargetedFullRescan(for: [token.pid])
    }

    func requestTargetedFullRescan(for appPIDs: Set<pid_t>) {
        guard let controller, !appPIDs.isEmpty else { return }
        controller.layoutRefreshController.requestFullRescan(
            reason: .staleFullRescan,
            scope: .targeted(appPIDs: appPIDs, nativeSpaceIds: [])
        )
    }

    private func prepareManagedWindowRemoval(
        _ entry: WindowState
    ) -> (shouldRecoverFocus: Bool, closeRecoveryArmed: Bool) {
        guard let controller else { return (false, false) }
        let shouldRecoverFocus = controller.workspaceManager.focusedToken == entry.token
        let closeRecoveryArmed: Bool
        if shouldRecoverFocus {
            closeRecoveryArmed = beginWindowCloseFocusRecovery(
                in: entry.workspaceId,
                closedToken: entry.token
            )
        } else {
            _ = activeWindowCloseFocusRecoveryWorkspaceId()
            closeRecoveryArmed = false
        }
        let layoutType = controller.workspaceManager.descriptor(for: entry.workspaceId)
            .map { controller.settings.layoutType(for: $0.name) } ?? .defaultLayout
        guard layoutType != .dwindle,
              let monitor = controller.workspaceManager.monitor(for: entry.workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        else {
            return (shouldRecoverFocus, closeRecoveryArmed)
        }
        let shouldAnimate = controller.niriEngine?
            .findNode(for: entry.token, in: entry.workspaceId)?.isHiddenInTabbedMode != true
        if shouldAnimate {
            controller.layoutRefreshController.startWindowCloseAnimation(entry: entry, monitor: monitor)
        }
        return (shouldRecoverFocus, closeRecoveryArmed)
    }

    private func beginWindowCloseFocusRecovery(
        in workspaceId: WorkspaceDescriptor.ID,
        closedToken: WindowToken
    ) -> Bool {
        guard let controller else { return false }
        guard isWorkspaceActive(workspaceId) else {
            endWindowCloseFocusRecovery(reason: "inactive_workspace")
            return false
        }

        windowCloseFocusRecoveryContext = WindowCloseFocusRecoveryContext(
            workspaceId: workspaceId,
            closedToken: closedToken,
            expiresAt: Date().addingTimeInterval(Self.windowCloseFocusRecoveryDuration)
        )
        controller.focusPolicyEngine.beginLease(
            owner: .windowCloseFocusRecovery,
            reason: "window_close_focus_recovery",
            suppressesFocusFollowsMouse: true,
            duration: Self.windowCloseFocusRecoveryDuration,
            notify: false
        )
        return true
    }

    private func activeWindowCloseFocusRecoveryWorkspaceId() -> WorkspaceDescriptor.ID? {
        guard let context = windowCloseFocusRecoveryContext else { return nil }
        guard context.expiresAt > Date(), isWorkspaceActive(context.workspaceId) else {
            endWindowCloseFocusRecovery(reason: "expired_or_inactive")
            return nil
        }
        return context.workspaceId
    }

    private func endWindowCloseFocusRecovery(
        matching workspaceId: WorkspaceDescriptor.ID? = nil,
        reason: String = "end"
    ) {
        if let workspaceId, windowCloseFocusRecoveryContext?.workspaceId != workspaceId {
            return
        }
        guard windowCloseFocusRecoveryContext != nil else { return }
        windowCloseFocusRecoveryContext = nil
        controller?.focusPolicyEngine.endLease(owner: .windowCloseFocusRecovery, notify: false)
    }

    private func shouldSuppressObservedActivationDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              let context = windowCloseFocusRecoveryContext,
              context.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    private func shouldDeferSameAppActivationForCloseProbe(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64
    ) -> Bool {
        guard source == .focusedWindowChanged, origin == .external else { return false }
        guard case .unrelatedNoRequest = requestDisposition else { return false }
        guard let controller else { return false }
        guard !hasRecentMouseFocusIntent(for: observedEntry.token) else { return false }
        guard observedEntry.mode == .tiling,
              controller.workspaceManager.activeLayoutKind(for: observedEntry.workspaceId) == .niri,
              controller.niriEngine?.findNode(for: observedEntry.token, in: observedEntry.workspaceId) != nil
        else {
            return false
        }

        guard let focusedToken = controller.workspaceManager.focusedToken,
              focusedToken != observedEntry.token,
              focusedToken.pid == observedEntry.pid,
              let focusedEntry = controller.workspaceManager.entry(for: focusedToken),
              focusedEntry.mode == .tiling,
              controller.niriEngine?.findNode(for: focusedToken, in: focusedEntry.workspaceId) != nil,
              let focusedWorkspace = controller.workspaceManager.descriptor(for: focusedEntry.workspaceId)
        else {
            return false
        }
        switch controller.settings.layoutType(for: focusedWorkspace.name) {
        case .niri,
             .defaultLayout:
            break
        case .dwindle:
            return false
        }

        deferSameAppCloseProbe(
            focusedToken: focusedToken,
            focusedWorkspaceId: focusedEntry.workspaceId,
            observedToken: observedEntry.token,
            source: source,
            observationGeneration: observationGeneration
        )
        return true
    }

    private func shouldSuppressObservedManagedActivation(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64
    ) -> Bool {
        if hasRecentMouseFocusIntent(for: observedEntry.token) {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(
                    pid: observedEntry.pid,
                    workspaceId: observedEntry.workspaceId
                ),
                reason: "mouse_focus_intent"
            )
            return false
        }

        if shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            return true
        }

        if shouldDeferSameAppActivationForCloseProbe(
            entry: observedEntry,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration
        ) {
            return true
        }

        if shouldSuppressObservedActivationDuringWindowCloseRecovery(
            observedToken: observedEntry.token,
            requestDisposition: requestDisposition
        ) {
            return true
        }
        return false
    }

    private func shouldSuppressObservedActivationDuringManagedReplacementFocusTransaction(
        entry observedEntry: WindowState,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        let key = managedReplacementFocusKey(pid: observedEntry.pid, workspaceId: observedEntry.workspaceId)
        guard let transaction = managedReplacementFocusTransaction(
            for: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else { return false }

        guard case .unrelatedNoRequest = requestDisposition else {
            if !transaction.protects(observedEntry.token) {
                clearManagedReplacementFocusTransaction(for: key, reason: "managed_focus_request")
            }
            return false
        }

        guard source == .focusedWindowChanged else {
            clearManagedReplacementFocusTransaction(for: key, reason: "app_activation")
            return false
        }

        guard transaction.suppressesUnrelatedActivation(
            token: observedEntry.token,
            workspaceId: observedEntry.workspaceId
        ) else {
            return false
        }

        cancelSameAppCloseProbe(
            matchingFocusedToken: transaction.anchorToken,
            reason: "managed_replacement_focus_transaction"
        )
        return true
    }

    private func shouldSuppressNonManagedFallbackDuringWindowCloseRecovery(
        observedToken: WindowToken,
        requestDisposition: ActivationRequestDisposition,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard activeWindowCloseFocusRecoveryWorkspaceId() != nil,
              windowCloseFocusRecoveryContext?.closedToken.pid == observedToken.pid
        else {
            return false
        }

        if case .matchesActiveRequest = requestDisposition {
            return false
        }
        return true
    }

    func noteMouseFocusIntent(token: WindowToken) {
        recentMouseFocusIntent = RecentMouseFocusIntent(
            token: token,
            expiresAt: Date().addingTimeInterval(Self.mouseFocusIntentDuration)
        )
        if let controller,
           let entry = controller.workspaceManager.entry(for: token)
        {
            clearManagedReplacementFocusTransaction(
                for: managedReplacementFocusKey(pid: token.pid, workspaceId: entry.workspaceId),
                reason: "mouse_focus_intent"
            )
        }
        if let open = controller?.intentLedger.openSameAppCloseProbe(),
           open.payload.observedToken == token
        {
            cancelSameAppCloseProbe(reason: "mouse_focus_intent")
        }
    }

    func hasRecentMouseFocusIntent(for token: WindowToken) -> Bool {
        guard let intent = recentMouseFocusIntent else { return false }
        guard intent.expiresAt > Date() else {
            recentMouseFocusIntent = nil
            return false
        }
        return intent.token == token
    }

    private func isWorkspaceActive(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId)
        else {
            return false
        }
        return controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId
    }

    @discardableResult
    func handleAppActivation(
        pid: pid_t,
        source: ActivationEventSource = .workspaceDidActivateApplication,
        origin: ActivationCallOrigin = .external,
        causalObservationGeneration: UInt64? = nil,
        callbackGeneration: UInt64? = nil,
        focusedAdmissionRetryExecution: FocusedAdmissionRetryExecution? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard controller.hasStartedServices else { return false }
        if let causalObservationGeneration,
           causalObservationGeneration != latestActivationObservationGeneration
        {
            retireStaleFocusedAdmissionRetry(
                pid: pid,
                observationGeneration: causalObservationGeneration
            )
            return false
        }
        guard controller.focusPolicyEngine.evaluate(
            .managedAppActivation(source: source)
        ).allowsFocusChange else {
            return false
        }
        recordNiriCreateFocusTrace(
            .init(
                kind: .activationSourceObserved(
                    pid: pid,
                    source: source
                )
            )
        )
        let observationGeneration: UInt64
        if let causalObservationGeneration {
            observationGeneration = causalObservationGeneration
        } else {
            observationGeneration = nextActivationObservationGeneration
            nextActivationObservationGeneration &+= 1
            latestActivationObservationGeneration = observationGeneration
        }

        if source != .focusedWindowChanged {
            controller.focusPolicyEngine.beginLease(
                owner: .nativeAppSwitch,
                reason: source.rawValue,
                suppressesFocusFollowsMouse: true,
                duration: 0.4
            )
        }

        if pid == getpid(), (controller.hasFrontmostOwnedWindow || controller.hasVisibleOwnedWindow) {
            if let activeRequest = controller.intentLedger.activeManagedRequest, activeRequest.token.pid == pid {
                _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
                _ = controller.workspaceManager.cancelManagedFocusRequest(
                    matching: activeRequest.token,
                    workspaceId: activeRequest.workspaceId,
                    requestId: activeRequest.requestId
                )
            }
            _ = controller.workspaceManager.enterNonManagedFocus(
                preserveFocusedToken: true
            )
            return false
        }

        let activeRequest = controller.intentLedger.activeManagedRequest
        let conflictsWithActiveRequest = activeRequest.map {
            !managedWindowToken($0.token, matchesObservedPid: pid)
        } ?? true
        let focusedToken = controller.workspaceManager.focusedToken
        if origin == .external,
           conflictsWithActiveRequest,
           activeRequest != nil || focusedToken.map({ !managedWindowToken($0, matchesObservedPid: pid) }) ?? true
        {
            if let activeRequest {
                clearManagedFocusState(
                    matching: activeRequest.token,
                    workspaceId: activeRequest.workspaceId
                )
            }
            _ = controller.workspaceManager.enterNonManagedFocus()
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(kind: .provisionalNonManagedFocusEntered(pid: pid, source: source))
            )
        }

        let focusCausality = sameAppFocusCausality(
            pid: pid,
            source: source,
            origin: origin,
            focusedToken: focusedToken
        )
        return controller.factResolver.resolveActivationFacts(
            pid: pid,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration,
            sameAppFocusCausality: focusCausality,
            callbackGeneration: callbackGeneration,
            focusedAdmissionRetryExecution: focusedAdmissionRetryExecution
        )
    }

    func handleActivationFactsResolved(_ facts: ActivationFacts) {
        if let execution = facts.focusedAdmissionRetryExecution,
           !ownsFocusedAdmissionRetryExecution(execution, matching: facts)
        {
            return
        }
        defer {
            if let execution = facts.focusedAdmissionRetryExecution {
                finishFocusedAdmissionRetryExecution(execution)
            }
        }
        guard let controller, controller.hasStartedServices else { return }
        guard facts.observationGeneration == latestActivationObservationGeneration else { return }
        if let callbackGeneration = facts.callbackGeneration {
            guard AppAXContext.contexts[facts.pid]?.callbackGeneration == callbackGeneration else { return }
        }
        if let issuedAtSeq = controller.intentLedger.newestFocusIntentIssuedAtSeq(),
           issuedAtSeq > facts.requestedAtSeq
        {
            return
        }

        let pid = facts.pid
        let source = facts.source
        let origin = facts.origin
        let axRef = facts.focusedWindow?.axRef
        let observedToken = axRef.map { canonicalObservedWindowToken(pid: pid, axRef: $0) }
        let activeRequest = controller.intentLedger.activeManagedRequest
        let requestDisposition = activationRequestDisposition(
            for: pid,
            token: observedToken,
            activeRequest: activeRequest
        )

        guard let axRef, let focusedWindow = facts.focusedWindow else {
            controller.workspaceManager.setSystemModalFocus(nil)
            handleMissingFocusedWindow(
                pid: pid,
                source: source,
                origin: origin,
                requestDisposition: requestDisposition
            )
            return
        }
        let token = canonicalObservedWindowToken(pid: pid, axRef: axRef)
        if let causality = facts.sameAppFocusCausality,
           controller.workspaceManager.entry(for: token) != nil,
           !hasRecentMouseFocusIntent(for: token),
           !preservesSameAppFocusCausality(causality)
        {
            return
        }
        controller.workspaceManager.setSystemModalFocus(focusedWindow.isSystemModalSurface ? token : nil)

        let appFullscreen = focusedWindow.isFullscreen

        if let entry = controller.workspaceManager.entry(for: token),
           entry.interactionPolicy.mayFocus
        {
            discardCreatePlacementContext(for: token.windowId)
            if appFullscreen {
                suspendManagedWindowForNativeFullscreen(entry)
                return
            }
            _ = restoreManagedWindowFromNativeFullscreen(entry)
            let entry = controller.workspaceManager.entry(for: token) ?? entry
            let wsId = entry.workspaceId

            let targetMonitor = controller.workspaceManager.monitor(for: wsId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == wsId
            } ?? false

            if shouldSuppressObservedManagedActivation(
                entry: entry,
                requestDisposition: requestDisposition,
                source: source,
                origin: origin,
                observationGeneration: facts.observationGeneration
            ) {
                if case let .conflictsWithPendingRequest(request) = requestDisposition {
                    continueManagedFocusRequest(
                        request,
                        source: source,
                        origin: origin,
                        reason: .pendingFocusMismatch
                    )
                }
                return
            }

            switch requestDisposition {
            case .matchesActiveRequest:
                break
            case let .conflictsWithPendingRequest(request):
                if shouldHonorObservedFocusOverPendingRequest(
                    observedToken: token,
                    source: source,
                    origin: origin
                ) {
                    clearManagedFocusState(
                        matching: request.token,
                        workspaceId: request.workspaceId
                    )
                    break
                }
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusMismatch
                )
                return
            case .unrelatedNoRequest:
                guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                    source: source,
                    origin: origin,
                    isWorkspaceActive: isWorkspaceActive
                ) else { return }
            }

            endWindowCloseFocusRecovery(matching: wsId, reason: "accepted_managed_activation")
            handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                appFullscreen: appFullscreen,
                source: source,
                confirmRequest: true,
                origin: origin,
                callbackGeneration: facts.callbackGeneration
            )
            return
        }

        let admissionAttempt = admitFocusedWindowBeforeNonManagedFallback(
            token: token,
            axRef: axRef,
            source: source,
            origin: origin,
            observationGeneration: facts.observationGeneration,
            requestDisposition: requestDisposition,
            appFullscreen: appFullscreen,
            callbackGeneration: facts.callbackGeneration
        )
        if admissionAttempt == .handled {
            return
        }

        if shouldSuppressNonManagedFallbackDuringWindowCloseRecovery(
            observedToken: token,
            requestDisposition: requestDisposition,
            source: source,
            origin: origin
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: source,
                    origin: origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return
        }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: token,
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .pendingFocusUnmanagedToken
            )
            return
        case .unrelatedNoRequest:
            break
        }

        if case let .admissionPending(reason) = admissionAttempt {
            let ownsProvisionalFocus = origin == .external
                || controller.workspaceManager.nonManagedFocusToken == token
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == token.pid
            if ownsProvisionalFocus {
                let provisionalTarget: WindowToken? = reason.suppressesNonManagedFocusTarget ? nil : token
                _ = controller.workspaceManager.enterNonManagedFocus(target: provisionalTarget)
                controller.surfaceReconciler.noteRestackOccurred()
                recordNiriCreateFocusTrace(
                    .init(kind: .provisionalNonManagedFocusEntered(pid: pid, source: source))
                )
            }
            _ = scheduleFocusedAdmissionReadmit(
                token: token,
                axRef: axRef,
                reason: reason,
                source: source,
                observationGeneration: facts.observationGeneration,
                callbackGeneration: facts.callbackGeneration
            )
            return
        }

        let nonManagedTarget: WindowToken? = admissionAttempt
            == .admissionRejected(.nonRenderableTransientSurface) ? nil : token
        _ = controller.workspaceManager.enterNonManagedFocus(target: nonManagedTarget)
        controller.surfaceReconciler.noteRestackOccurred()

        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private func admitFocusedWindowBeforeNonManagedFallback(
        token: WindowToken,
        axRef: AXWindowRef,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64,
        requestDisposition: ActivationRequestDisposition,
        appFullscreen: Bool,
        callbackGeneration: UInt64?
    ) -> FocusedAdmissionAttempt {
        guard let controller,
              let windowId = UInt32(exactly: token.windowId)
        else {
            return .rejected
        }

        let windowInfo = resolveWindowInfo(windowId)
        let createPlacementContext = retainedCreatePlacementContext(
            windowId: windowId,
            controller: controller
        )
        let outcome = prepareCreateCandidate(
            windowId: windowId,
            windowInfo: windowInfo,
            fallbackToken: token,
            fallbackAXRef: axRef,
            createPlacementContext: createPlacementContext
        )
        let candidate: PreparedCreate
        switch outcome {
        case let .prepared(prepared):
            candidate = prepared
        case let .alreadyTracked(trackedToken):
            discardCreatePlacementContext(windowId: windowId)
            let policy = controller.workspaceManager.entry(for: trackedToken)?.interactionPolicy ?? .full
            return policy.mayFocus ? .handled : .rejected
        case .identityRebindPending:
            return .handled
        case let .pending(pendingToken, pendingAXRef, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: pendingToken?.pid,
                    windowId: Int(windowId),
                    bundleId: pendingToken.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    callbackGeneration: callbackGeneration,
                    axRef: pendingAXRef
                )
            )
            return .admissionPending(reason)
        case let .ignored(ignoredToken, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    pid: ignoredToken?.pid,
                    windowId: Int(windowId),
                    bundleId: ignoredToken.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    callbackGeneration: callbackGeneration
                )
            )
            discardCreatePlacementContext(windowId: windowId)
            return .admissionRejected(reason)
        }
        guard candidate.token == token else {
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    pid: candidate.token.pid,
                    windowId: candidate.token.windowId,
                    bundleId: candidate.bundleId,
                    competingPid: token.pid,
                    reason: WindowAdmissionRejectionReason.invalidIdentity.rawValue,
                    callbackGeneration: callbackGeneration,
                    axRef: candidate.axRef
                )
            )
            discardCreatePlacementContext(windowId: windowId)
            return .rejected
        }

        cancelCreatedWindowRetry(windowId: windowId)
        if completeLiveStructuralReplacementCreate(candidate) {
            guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
                return .handled
            }
            let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
            let isWorkspaceActive = targetMonitor.map { monitor in
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
            } ?? false
            return completeFocusedManagedAdmission(
                entry: entry,
                isWorkspaceActive: isWorkspaceActive,
                activation: .init(
                    source: source,
                    origin: origin,
                    observationGeneration: observationGeneration,
                    appFullscreen: appFullscreen,
                    request: .init(requestDisposition),
                    callbackGeneration: callbackGeneration
                ),
                requestDisposition: requestDisposition
            ) ? .handled : .rejected
        }
        if shouldDelayManagedReplacementCreate(candidate) {
            enqueueManagedReplacementCreate(
                candidate,
                focusedActivation: .init(
                    source: source,
                    origin: origin,
                    observationGeneration: observationGeneration,
                    appFullscreen: appFullscreen,
                    request: .init(requestDisposition),
                    callbackGeneration: callbackGeneration
                )
            )
            return .handled
        }

        trackPreparedCreate(candidate)
        guard let entry = controller.workspaceManager.entry(for: candidate.token) else {
            return .handled
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false

        return completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: .init(
                source: source,
                origin: origin,
                observationGeneration: observationGeneration,
                appFullscreen: appFullscreen,
                request: .init(requestDisposition),
                callbackGeneration: callbackGeneration
            ),
            requestDisposition: requestDisposition
        ) ? .handled : .rejected
    }

    private func scheduleFocusedAdmissionReadmit(
        token: WindowToken,
        axRef: AXWindowRef,
        reason: WindowAdmissionPendingReason,
        source: ActivationEventSource,
        observationGeneration: UInt64,
        callbackGeneration: UInt64?
    ) -> Bool {
        guard let windowId = UInt32(exactly: token.windowId) else { return false }
        return scheduleAdmissionRetry(
            windowId: windowId,
            expectedToken: token,
            axRef: axRef,
            reason: reason,
            trigger: .focused(
                token: token,
                source: source,
                observationGeneration: observationGeneration,
                callbackGeneration: callbackGeneration
            )
        )
    }

    @discardableResult
    private func completeFocusedManagedAdmission(
        entry: WindowState,
        isWorkspaceActive: Bool,
        activation: PendingFocusedManagedActivation,
        requestDisposition: ActivationRequestDisposition,
        bindCurrentPidRequest: Bool = true
    ) -> Bool {
        guard let controller else { return false }
        guard entry.interactionPolicy.mayFocus else { return false }
        if shouldSuppressObservedManagedActivation(
            entry: entry,
            requestDisposition: requestDisposition,
            source: activation.source,
            origin: activation.origin,
            observationGeneration: activation.observationGeneration
        ) {
            if case let .conflictsWithPendingRequest(request) = requestDisposition {
                continueManagedFocusRequest(
                    request,
                    source: activation.source,
                    origin: activation.origin,
                    reason: .pendingFocusUnmanagedToken
                )
            }
            return true
        }

        switch requestDisposition {
        case .matchesActiveRequest:
            break
        case let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: entry.token,
                source: activation.source,
                origin: activation.origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                handleManagedAppActivation(
                    entry: entry,
                    isWorkspaceActive: isWorkspaceActive,
                    appFullscreen: activation.appFullscreen,
                    source: activation.source,
                    confirmRequest: true,
                    origin: activation.origin,
                    activeRequestId: nil,
                    bindCurrentPidRequest: false,
                    callbackGeneration: activation.callbackGeneration
                )
                return true
            }
            continueManagedFocusRequest(
                request,
                source: activation.source,
                origin: activation.origin,
                reason: .pendingFocusUnmanagedToken
            )
            return true
        case .unrelatedNoRequest:
            if activation.origin == .retry,
               controller.workspaceManager.nonManagedFocusToken != entry.token,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid
            {
                return true
            }
            guard shouldHandleObservedManagedActivationWithoutPendingRequest(
                source: activation.source,
                origin: activation.origin,
                isWorkspaceActive: isWorkspaceActive
            ) else { return true }
        }

        handleManagedAppActivation(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            appFullscreen: activation.appFullscreen,
            source: activation.source,
            confirmRequest: true,
            origin: activation.origin,
            activeRequestId: activation.request.requestId,
            bindCurrentPidRequest: bindCurrentPidRequest,
            callbackGeneration: activation.callbackGeneration
        )
        return true
    }

    func handleManagedAppActivation(
        entry: WindowState,
        isWorkspaceActive: Bool,
        appFullscreen: Bool,
        source: ActivationEventSource = .focusedWindowChanged,
        confirmRequest: Bool? = nil,
        origin: ActivationCallOrigin = .external,
        activeRequestId: UInt64? = nil,
        bindCurrentPidRequest: Bool = true,
        callbackGeneration: UInt64? = nil
    ) {
        guard let controller else { return }
        WindowAdmissionTrace.record(
            .init(
                action: .managedFocusObserved,
                pid: entry.pid,
                windowId: entry.windowId,
                bundleId: entry.managedReplacementMetadata?.bundleId,
                reason: String(describing: source),
                callbackGeneration: callbackGeneration,
                axRef: entry.axRef
            )
        )
        if appFullscreen {
            suspendManagedWindowForNativeFullscreen(entry)
            return
        }

        _ = restoreManagedWindowFromNativeFullscreen(entry)
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        let wsId = entry.workspaceId
        let monitorId = controller.workspaceManager.monitorId(for: wsId)
        let shouldActivateWorkspace = !isWorkspaceActive && !controller.isTransferringWindow
        var activeRequest: ManagedFocusRequest?
        if let activeRequestId {
            activeRequest = controller.intentLedger.activeManagedRequest(requestId: activeRequestId)
        } else if bindCurrentPidRequest {
            activeRequest = controller.intentLedger.activeManagedRequest(for: entry.pid)
        } else {
            activeRequest = nil
        }
        let shouldConfirmRequest = confirmRequest ?? true
        let focusObservation = controller.intentLedger.classifyFocusObservation(token: entry.token)

        if shouldConfirmRequest {
            if let request = activeRequest,
               !controller.workspaceManager.pendingManagedFocusMatches(
                   token: entry.token,
                   workspaceId: wsId,
                   requestId: request.requestId
               )
            {
                _ = controller.intentLedger.cancelManagedRequest(requestId: request.requestId)
                _ = controller.workspaceManager.cancelManagedFocusRequest(
                    matching: request.token,
                    workspaceId: request.workspaceId,
                    requestId: request.requestId
                )
                return
            }

            let confirmationRequestId = activeRequest?.requestId
            guard controller.workspaceManager.canConfirmManagedFocus(
                entry.token,
                in: wsId,
                requestId: confirmationRequestId
            ) else {
                return
            }

            _ = controller.workspaceManager.confirmManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId,
                activateWorkspaceOnMonitor: shouldActivateWorkspace,
                requestId: confirmationRequestId
            )

            if let activeRequest {
                if activeRequest.token == entry.token {
                    _ = controller.intentLedger.confirmManagedRequest(
                        token: entry.token,
                        source: source
                    )
                } else {
                    _ = controller.intentLedger.cancelManagedRequest(requestId: activeRequest.requestId)
                    _ = controller.workspaceManager.cancelManagedFocusRequest(
                        matching: activeRequest.token,
                        workspaceId: activeRequest.workspaceId,
                        requestId: activeRequest.requestId
                    )
                }
            }

            recordNiriCreateFocusTrace(
                .init(
                    kind: .focusConfirmed(
                        token: entry.token,
                        workspaceId: wsId,
                        source: source
                    )
                )
            )
        } else {
            _ = controller.workspaceManager.setManagedFocus(
                entry.token,
                in: wsId,
                onMonitor: monitorId
            )
        }

        var preferredMouseFrame: CGRect?
        switch controller.workspaceManager.activeLayoutKind(for: wsId) {
        case .dwindle:
            if let engine = controller.dwindleEngine {
                _ = controller.dwindleLayoutHandler.activateWindow(
                    entry.token,
                    in: wsId,
                    layoutRefresh: isWorkspaceActive,
                    focusAfterLayout: false
                )
                preferredMouseFrame = engine.contentFrame(for: entry.token, in: wsId)
                    ?? engine.findNode(for: entry.token, in: wsId)?.cachedFrame
            }
        case .niri:
            if let engine = controller.niriEngine,
               let node = engine.findNode(for: entry.token, in: wsId),
               let _ = controller.workspaceManager.monitor(for: wsId)
            {
                let preferredFrame = node.renderedFrame ?? node.frame
                preferredMouseFrame = preferredFrame
                var state = controller.workspaceManager.niriViewportState(for: wsId)
                let preservesPointerViewport = switch focusObservation {
                case let .echoOf(intent),
                     let .lateEcho(intent):
                    !intent.origin.allowsMouseToFocusedWarp
                case .external: false
                }
                let preserveViewport = controller.workspaceManager.animationDriver.hasMotion(in: wsId)
                    || preservesPointerViewport
                let preserveReplacementViewport = isProtectedManagedReplacementFocus(
                    token: entry.token,
                    workspaceId: wsId
                )
                controller.niriLayoutHandler.activateNode(
                    node, in: wsId, state: &state,
                    options: preserveReplacementViewport
                        ? .init(
                            ensureVisible: false,
                            preserveViewportAnchor: true,
                            layoutRefresh: isWorkspaceActive,
                            axFocus: false,
                            startAnimation: false
                        )
                        : preserveViewport
                        ? .init(
                            ensureVisible: false,
                            preserveViewportAnchor: true,
                            layoutRefresh: false,
                            axFocus: false,
                            startAnimation: false
                        )
                        : .init(layoutRefresh: isWorkspaceActive, axFocus: false)
                )
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: state,
                        rememberedFocusToken: nil,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
                if preserveReplacementViewport {
                    completeManagedReplacementFocusTransactionIfNeeded(
                        token: entry.token,
                        workspaceId: wsId
                    )
                }
            }
        }

        controller.surfaceReconciler.noteRestackOccurred()
        if shouldActivateWorkspace, shouldConfirmRequest {
            controller.syncMonitorsToNiriEngine()
            controller.layoutRefreshController.commitWorkspaceTransition(
                reason: .appActivationTransition
            )
        }
        if shouldConfirmRequest,
           controller.moveMouseToFocusedWindowEnabled,
           !hasRecentMouseFocusIntent(for: entry.token),
           controller.intentLedger.allowsMouseToFocusedWarp(for: entry.token),
           controller.workspaceManager.focusedToken == entry.token,
           !controller.workspaceManager.isNonManagedFocusActive
        {
            controller.moveMouseToWindow(entry.token, preferredFrame: preferredMouseFrame)
        }
    }

    func handleWindowMiniaturized(pid: pid_t, windowId: Int) {
        controller?.workspaceManager.clearNonManagedFocusTarget(
            matching: WindowToken(pid: pid, windowId: windowId)
        )
    }

    @discardableResult
    private func suspendManagedWindowForNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        if changed {
            requestNativeFullscreenRelayout(for: entry.token, fallback: entry.workspaceId)
        }
        return changed
    }

    private func requestNativeFullscreenRelayout(
        for token: WindowToken,
        fallback workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .appActivationTransition,
            affectedWorkspaceIds: [
                controller.workspaceManager.workspace(for: token) ?? workspaceId
            ]
        )
    }

    private func handleNativeFullscreenDestroy(
        _ token: WindowToken,
        evidence: WindowDestroyEvidence
    ) -> Bool {
        guard evidence == .transientLifecycle else { return false }
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }

        if let record = controller.workspaceManager.nativeFullscreenRecord(for: token) {
            guard record.currentToken == token else { return false }
        } else if !shouldPreserveNativeFullscreenDestroy(entry) {
            return false
        }

        _ = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        clearManagedFocusState(matching: token, workspaceId: entry.workspaceId)
        requestNativeFullscreenRelayout(for: token, fallback: entry.workspaceId)
        return true
    }

    private func shouldPreserveNativeFullscreenDestroy(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        guard entry.mode == .tiling else { return false }
        guard controller.workspaceManager.focusedToken == entry.token else { return false }
        guard controller.workspaceManager.scratchpadToken() != entry.token else { return false }
        guard let descriptor = controller.workspaceManager.descriptor(for: entry.workspaceId) else { return false }
        guard controller.settings.layoutType(for: descriptor.name) != .dwindle else { return false }
        if entry.observedState.isNativeFullscreen {
            return true
        }
        if controller.workspaceManager.isWindowOnObservedNativeFullscreenSpace(entry.windowId) {
            return true
        }
        return AXWindowService.isFullscreenAttributeSet(entry.axRef)
    }

    @discardableResult
    private func restoreManagedWindowFromNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) || hadRecord
        if restored {
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(entry.token)
        }
        return restored
    }

    func handleAppDeactivated(pid: pid_t) {
        guard let controller else { return }
        let workspaceManager = controller.workspaceManager
        workspaceManager.clearNonManagedFocusTarget(pid: pid)

        guard !workspaceManager.isNonManagedFocusActive,
              let focusedToken = workspaceManager.focusedToken,
              focusedToken.pid == pid,
              let entry = workspaceManager.entry(for: focusedToken),
              entry.mode == .floating
        else { return }

        workspaceManager.suppressFocusBorder(for: focusedToken)
    }

    func awaitPendingManagedReplacementBursts(for appPIDs: Set<pid_t>? = nil) async {
        let tasks = pendingManagedReplacementTasks
            .filter { appPIDs?.contains($0.key.pid) ?? true }
            .sorted {
                ($0.key.pid, $0.key.workspaceId.uuidString)
                    < ($1.key.pid, $1.key.workspaceId.uuidString)
            }
            .map(\.value)
        for task in tasks {
            guard !Task.isCancelled else { return }
            await task.value
        }
    }

    func resetManagedReplacementState() {
        if let open = controller?.intentLedger.openSameAppCloseProbe(),
           hasPendingManagedReplacementDestroy(open.payload.focusedToken)
        {
            cancelSameAppCloseProbe(
                matchingFocusedToken: open.payload.focusedToken,
                reason: "managed_replacement_reset"
            )
        }
        for (_, task) in pendingManagedReplacementTasks {
            task.cancel()
        }
        pendingManagedReplacementTasks.removeAll()
        pendingManagedReplacementBursts.removeAll()
        if let controller {
            for intent in controller.intentLedger.openReplacementFocusIntents() {
                _ = controller.intentLedger.cancel(id: intent.id)
            }
        }
        nextManagedReplacementEventSequence = 0
    }

    private func prepareCreateCandidate(
        windowId: UInt32,
        windowInfo: WindowServerInfo?,
        fallbackToken: WindowToken? = nil,
        fallbackAXRef: AXWindowRef? = nil,
        allowsTrackedIdentityReplacement: Bool = false,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate,
        createPlacementContext: WindowCreatePlacementContext? = nil
    ) -> CreatePreparationOutcome {
        guard let controller else {
            return .ignored(token: fallbackToken, reason: .invalidIdentity)
        }
        let ownedWindow = controller.isOwnedWindow(windowNumber: Int(windowId))
        let windowInfoToken = windowInfo?.token(matching: windowId)
        let token = fallbackToken ?? windowInfoToken
        guard let token,
              token.windowId == Int(windowId)
        else {
            return windowInfo == nil
                ? .pending(token: fallbackToken, axRef: fallbackAXRef, reason: .windowInfoMissing)
                : .ignored(token: fallbackToken, reason: .invalidIdentity)
        }
        if ownedWindow {
            discardCreatePlacementContext(windowId: windowId)
            return .ignored(token: token, reason: .ownedWindow)
        }
        guard let axRef = fallbackAXRef?.windowId == Int(windowId)
            ? fallbackAXRef
            : resolveAXWindowRef(windowId: windowId, pid: token.pid)
        else {
            return .pending(token: token, axRef: nil, reason: .axWindowMissing)
        }
        if let existingEntry = controller.workspaceManager.entry(forWindowId: Int(windowId)) {
            if CFEqual(existingEntry.axRef.element, axRef.element), existingEntry.token == token {
                WindowAdmissionTrace.record(
                    .init(
                        action: .admissionAlreadyTracked,
                        pid: existingEntry.pid,
                        windowId: existingEntry.windowId,
                        bundleId: resolveBundleId(existingEntry.pid),
                        axRef: axRef
                    )
                )
                return .alreadyTracked(existingEntry.token)
            }
            guard allowsTrackedIdentityReplacement,
                  windowInfoToken == token
            else {
                return .ignored(token: token, reason: .invalidIdentity)
            }
            let rebindResult = rekeyManagedWindowIdentity(
                from: existingEntry.token,
                to: token,
                windowId: windowId,
                axRef: axRef
            )
            switch rebindResult {
            case let .committed(rekeyedEntry):
                return .alreadyTracked(rekeyedEntry.token)
            case .pending:
                return .identityRebindPending
            case .rejected:
                return .ignored(token: token, reason: .invalidIdentity)
            }
        }
        let axPid = AXWindowService.processIdentifier(axRef)
        if let axPid, axPid != token.pid {
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "admissionAX.pidMismatch.expected=\(token.pid)",
                pid: axPid,
                windowId: windowId
            )
        }
        if isAdmissionQuarantined(windowId: Int(windowId), axRef: axRef) {
            return .ignored(token: token, reason: .quarantined)
        }

        let app = NSRunningApplication(processIdentifier: token.pid)
        let bundleId = resolveBundleId(token.pid) ?? app?.bundleIdentifier
        let appFullscreen = AXWindowService.isFullscreen(axRef)
        let matchingWindowInfo = WMController.exactWindowServerInfo(windowInfo, for: token)
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            appFullscreen: appFullscreen,
            windowInfo: matchingWindowInfo,
            windowServerLookupAttempted: true
        )
        let interactionPolicy = WindowInteractionPolicy.resolve(for: evaluation)
        WindowAdmissionTrace.record(
            .init(
                action: .classificationObserved,
                pid: token.pid,
                windowId: token.windowId,
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                axPid: axPid,
                observation: WindowClassificationObservation(
                    token: token,
                    bundleId: bundleId,
                    rulesRevision: controller.settings.appRulesRevision,
                    evaluation: evaluation,
                    policy: interactionPolicy
                ),
                classificationRulesSnapshot: controller.settings.appRulesDiagnosticSnapshot,
                axRef: axRef
            )
        )

        let trackedMode = controller.trackedModeForLifecycle(
            decision: evaluation.decision,
            existingEntry: nil
        )

        guard let trackedMode else {
            if evaluation.decision.disposition == .undecided {
                return .pending(
                    token: token,
                    axRef: axRef,
                    reason: evaluation.decision.admissionPendingReason
                )
            }
            return .ignored(token: token, reason: evaluation.decision.admissionRejectionReason)
        }
        if controller.shouldDeferAdmission(
            evaluation: evaluation,
            axRef: axRef,
            mode: trackedMode,
            windowInfo: matchingWindowInfo
        ) {
            return .pending(token: token, axRef: axRef, reason: .degenerateGeometry)
        }
        subscribeToWindows([windowId])

        let resolvedBundleId = bundleId ?? evaluation.facts.ax.bundleId
        let replacementMatch = structuralReplacementMatch(
            token: token,
            bundleId: resolvedBundleId,
            mode: trackedMode,
            facts: evaluation.facts
        )
        let inheritTrackedParentWorkspace = controller.shouldInheritTrackedParentWorkspace(for: evaluation)
        let placementFrame = evaluation.facts.windowServer?.frame ?? matchingWindowInfo?.frame
        let placement = controller.resolveWorkspaceForNewWindow(
            workspaceName: evaluation.decision.workspaceName,
            axRef: axRef,
            pid: token.pid,
            parentWindowId: evaluation.facts.windowServer?.parentId,
            inheritTrackedParentWorkspace: inheritTrackedParentWorkspace,
            structuralReplacementWorkspaceId: replacementMatch?.workspaceId,
            placementMode: trackedMode,
            allowsFloatingSpawnPlacement: controller.allowsFloatingSpawnPlacement(
                for: evaluation,
                mode: trackedMode
            ),
            placementOrigin: placementOrigin,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            fallbackWorkspaceId: controller.activeWorkspace()?.id
        )
        let workspaceId = placement.workspaceId
        recordCreatePlacementTrace(
            token: token,
            placement: placement,
            createPlacementContext: createPlacementContext,
            windowFrame: placementFrame,
            controller: controller
        )

        let prepared = PreparedCreate(
            windowId: windowId,
            token: token,
            axRef: axRef,
            ruleEffects: evaluation.decision.ruleEffects,
            admissionHints: evaluation.decision.admissionHints,
            replacementMetadata: makeManagedReplacementMetadata(
                bundleId: resolvedBundleId,
                workspaceId: workspaceId,
                mode: trackedMode,
                facts: evaluation.facts
            ),
            structuralReplacementMatch: replacementMatch,
            requiresPostCreateLifecycleVerification: requiresPostCreateLifecycleVerification(
                trackedMode: trackedMode,
                facts: evaluation.facts
            ),
            interactionPolicy: interactionPolicy
        )
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPrepared,
                pid: token.pid,
                windowId: token.windowId,
                bundleId: resolvedBundleId,
                axPid: axPid,
                outcome: String(describing: trackedMode),
                axRef: axRef
            )
        )
        return .prepared(prepared)
    }

    private func preparedCreateCandidate(
        from outcome: CreatePreparationOutcome,
        windowId: UInt32,
        trigger: AdmissionRetryTrigger
    ) -> PreparedCreate? {
        switch outcome {
        case let .prepared(candidate):
            return candidate
        case .alreadyTracked:
            discardCreatePlacementContext(windowId: windowId)
            finishAdmissionRetryAfterTracking(windowId: windowId)
        case .identityRebindPending:
            break
        case let .pending(token, axRef, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionPending,
                    pid: token?.pid,
                    windowId: Int(windowId),
                    bundleId: token.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue,
                    axRef: axRef
                )
            )
            _ = scheduleAdmissionRetry(
                windowId: windowId,
                expectedToken: token,
                axRef: axRef,
                reason: reason,
                trigger: trigger
            )
        case let .ignored(token, reason):
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionIgnored,
                    pid: token?.pid,
                    windowId: Int(windowId),
                    bundleId: token.flatMap { resolveBundleId($0.pid) },
                    reason: reason.rawValue
                )
            )
            cancelCreatedWindowRetry(windowId: windowId)
            discardCreatePlacementContext(windowId: windowId)
            rejectDeferredReplacement(windowId: windowId)
            recordNiriCreateFocusTrace(
                .init(
                    kind: .admissionRejected(
                        windowId: windowId,
                        pid: token?.pid,
                        reason: reason
                    )
                )
            )
        }
        return nil
    }

    private func requiresPostCreateLifecycleVerification(
        trackedMode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> Bool {
        guard trackedMode == .floating else { return false }
        return !facts.ax.attributeFetchSucceeded
            || facts.ax.subrole == (kAXSystemDialogSubrole as String)
            || facts.windowServer?.hasTransientSurfaceEvidence == true
    }

    private func prepareDestroyCandidate(
        windowId: UInt32,
        pidHint: pid_t?,
        evidence: WindowDestroyEvidence
    ) -> PreparedDestroy? {
        guard let controller else { return nil }

        let hintedToken = pidHint.flatMap { hintedPid -> WindowToken? in
            let token = WindowToken(pid: hintedPid, windowId: Int(windowId))
            return controller.workspaceManager.entry(for: token) != nil ? token : nil
        }
        let resolvedToken = hintedToken
            ?? resolveTrackedToken(windowId)
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }

        guard let token = resolvedToken,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return nil
        }

        let bundleId = resolveBundleId(token.pid) ?? entry.managedReplacementMetadata?.bundleId
        let windowInfo = resolveWindowInfo(windowId)
        let cachedMetadata = overlayWindowServerInfo(
            windowInfo,
            onto: cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
        )
        let replacementMetadata: ManagedReplacementMetadata
        if managedReplacementNeedsLiveAXFacts(cachedMetadata) {
            let facts = managedReplacementFacts(
                for: entry.axRef,
                pid: token.pid,
                bundleId: cachedMetadata.bundleId,
                windowInfo: windowInfo,
                includeTitle: false
            )
            let liveMetadata = makeManagedReplacementMetadata(
                bundleId: cachedMetadata.bundleId,
                workspaceId: entry.workspaceId,
                mode: entry.mode,
                facts: facts
            )
            replacementMetadata = cachedMetadata.mergingNonNilValues(from: liveMetadata)
        } else {
            replacementMetadata = cachedMetadata
        }

        return PreparedDestroy(
            token: token,
            replacementMetadata: replacementMetadata,
            evidence: evidence
        )
    }

    private func handleWindowDestroyed(
        windowId: UInt32,
        pidHint: pid_t?,
        expectedWindow: AXWindowRef? = nil,
        callbackGeneration: UInt64? = nil,
        evidence: WindowDestroyEvidence
    ) {
        let observedToken = resolveWindowToken(windowId)
        let resolvedToken = resolveTrackedToken(windowId, resolvedWindowToken: observedToken)
            ?? observedToken
            ?? pidHint.map { WindowToken(pid: $0, windowId: Int(windowId)) }
        WindowAdmissionTrace.record(
            .init(
                action: .admissionDestroyed,
                pid: resolvedToken?.pid ?? pidHint,
                windowId: Int(windowId),
                bundleId: resolvedToken.flatMap { resolveBundleId($0.pid) },
                reason: resolvedToken == nil ? "unresolved_identity" : "resolved_identity",
                callbackGeneration: callbackGeneration,
                axRef: resolvedToken.flatMap {
                    controller?.workspaceManager.entry(for: $0)?.axRef
                }
            )
        )

        guard let candidate = prepareDestroyCandidate(
            windowId: windowId,
            pidHint: pidHint,
            evidence: evidence
        ) else {
            discardUnmanagedDestroyedWindowState(windowId: windowId, resolvedToken: resolvedToken)
            WindowAdmissionTrace.record(
                .init(
                    action: .admissionDisappeared,
                    pid: resolvedToken?.pid ?? pidHint,
                    windowId: Int(windowId),
                    reason: "destroy_without_managed_candidate",
                    callbackGeneration: callbackGeneration
                )
            )
            clearFocusedTargetForDestroyedWindow(
                windowId: windowId,
                resolvedToken: resolvedToken,
                pidHint: pidHint
            )
            if let controller,
               controller.workspaceManager.entry(forWindowId: Int(windowId)) == nil
            {
                if let expectedWindow,
                   let pid = pidHint ?? resolvedToken?.pid
                {
                    controller.axManager.removeWindowState(pid: pid, expectedWindow: expectedWindow)
                } else if let resolvedToken {
                    controller.axManager.removeWindowLedgerState(
                        pid: resolvedToken.pid,
                        windowId: resolvedToken.windowId
                    )
                    controller.axManager.bindManagedWindows(
                        controller.workspaceManager.entries(forPid: resolvedToken.pid)
                    )
                }
            }
            if let resolvedToken {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(resolvedToken.pid)])
            } else if let pid = pidHint ?? resolveWindowInfo(windowId)?.pid {
                scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(pid_t(pid))])
            }
            return
        }

        let shouldDelayDestroy = shouldDelayManagedReplacementDestroy(candidate)
        if shouldDelayDestroy,
           handleNativeFullscreenDestroy(candidate.token, evidence: candidate.evidence)
        {
            return
        }
        if shouldDelayDestroy {
            enqueueManagedReplacementDestroy(candidate)
            return
        }

        processPreparedDestroy(candidate)
    }

    private func discardUnmanagedDestroyedWindowState(
        windowId: UInt32,
        resolvedToken: WindowToken?
    ) {
        identityAliasesByWindowId.removeValue(forKey: Int(windowId))
        admissionQuarantineByWindowId.removeValue(forKey: Int(windowId))
        clearTerminalFrameFailure(windowId: Int(windowId))
        guard let resolvedToken else { return }
        cancelCreatedWindowRetry(windowId: windowId)
        cancelPostCreateLifecycleVerification(for: resolvedToken)
        controller?.clearManualWindowOverride(for: resolvedToken)
        cancelSameAppCloseProbe(matchingFocusedToken: resolvedToken, reason: "destroy_resolved")
    }

    private func clearFocusedTargetForDestroyedWindow(
        windowId: UInt32,
        resolvedToken: WindowToken?,
        pidHint: pid_t?
    ) {
        guard let controller,
              let target = controller.workspaceManager.nonManagedFocusToken
        else { return }

        let matchesResolvedToken = resolvedToken.map { $0 == target } ?? false
        let matchesPidHint = pidHint.map { $0 == target.pid && target.windowId == Int(windowId) } ?? false
        let matchesWindowId = target.windowId == Int(windowId)
        guard matchesResolvedToken || matchesPidHint || matchesWindowId else { return }

        controller.workspaceManager.clearNonManagedFocusTarget(matching: target)
    }

    private func processPreparedDestroy(_ candidate: PreparedDestroy) {
        handleRemoved(token: candidate.token, evidence: candidate.evidence)
        clearManagedReplacementFocusTransaction(
            containing: candidate.token,
            workspaceId: candidate.workspaceId,
            reason: "destroy_processed"
        )
    }

    private func shouldDelayManagedReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let _ = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else {
            return false
        }

        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        if pendingManagedReplacementBursts[key] != nil {
            return true
        }

        return candidate.structuralReplacementMatch?.source == .pendingDestroy
    }

    private func completeLiveStructuralReplacementCreate(_ candidate: PreparedCreate) -> Bool {
        guard let match = candidate.structuralReplacementMatch,
              match.source == .liveInvisible
        else {
            return false
        }

        return rekeyManagedReplacement(from: match.token, to: candidate).isHandled
    }

    private func shouldDelayManagedReplacementDestroy(_ candidate: PreparedDestroy) -> Bool {
        managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) != nil
    }

    func enqueueManagedReplacementCreate(_ candidate: PreparedCreate) {
        enqueueManagedReplacementCreate(candidate, focusedActivation: nil)
    }

    private func enqueueManagedReplacementCreate(
        _ candidate: PreparedCreate,
        focusedActivation: PendingFocusedManagedActivation?
    ) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        WindowAdmissionTrace.record(
            .init(
                action: .admissionPending,
                pid: candidate.token.pid,
                windowId: candidate.token.windowId,
                bundleId: candidate.bundleId,
                reason: "managed_replacement_correlation",
                outcome: "deferred",
                axRef: candidate.axRef
            )
        )
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingCreate = PendingManagedCreate(
            sequence: nextManagedReplacementSequence(),
            candidate: candidate,
            focusedActivation: focusedActivation
        )
        burst.append(create: pendingCreate)
        pendingManagedReplacementBursts[key] = burst
        let resetExistingDeadline = isNewBurst
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: managedReplacementPolicyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        if flushManagedReplacementBurstIfUnambiguouslyMatched(for: key) {
            return
        }
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func enqueueManagedReplacementDestroy(_ candidate: PreparedDestroy) {
        guard let policy = managedReplacementCorrelationPolicy(for: candidate.replacementMetadata) else { return }
        let key = ManagedReplacementKey(pid: candidate.token.pid, workspaceId: candidate.workspaceId)
        armManagedReplacementFocusTransaction(
            token: candidate.token,
            workspaceId: candidate.workspaceId
        )
        let isNewBurst = pendingManagedReplacementBursts[key] == nil
        var burst = pendingManagedReplacementBursts[key] ?? PendingManagedReplacementBurst(
            policy: policy,
            firstEventUptime: managedReplacementCurrentUptime()
        )
        let pendingDestroy = PendingManagedDestroy(sequence: nextManagedReplacementSequence(), candidate: candidate)
        burst.append(destroy: pendingDestroy)
        pendingManagedReplacementBursts[key] = burst
        holdSameAppCloseProbe(matchingFocusedToken: candidate.token)
        let resetExistingDeadline = isNewBurst
        recordManagedReplacementTrace(
            key: key,
            kind: .enqueued(
                policy: managedReplacementPolicyName(policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                deadlineReset: resetExistingDeadline
            )
        )
        if flushManagedReplacementBurstIfUnambiguouslyMatched(for: key) {
            return
        }
        scheduleManagedReplacementFlush(
            for: key,
            policy: policy,
            resetExistingDeadline: resetExistingDeadline
        )
    }

    private func flushManagedReplacementBurstIfUnambiguouslyMatched(for key: ManagedReplacementKey) -> Bool {
        guard let burst = pendingManagedReplacementBursts[key],
              burst.destroys.count == 1,
              burst.creates.count == 1,
              matchedManagedReplacementPair(in: burst) != nil
        else {
            return false
        }
        flushManagedReplacementBurst(for: key)
        return true
    }

    private func matchedManagedReplacementPair(
        in burst: PendingManagedReplacementBurst
    ) -> MatchedManagedReplacementPair? {
        var matchedPair: MatchedManagedReplacementPair?

        for destroy in burst.destroys {
            for create in burst.creates {
                guard destroy.candidate.token != create.candidate.token,
                      managedReplacementMetadataMatches(
                          oldToken: destroy.candidate.token,
                          old: destroy.candidate.replacementMetadata,
                          new: create.candidate.replacementMetadata,
                          newFacts: nil
                      )
                else {
                    continue
                }

                if matchedPair != nil {
                    return nil
                }
                matchedPair = MatchedManagedReplacementPair(destroy: destroy, create: create)
            }
        }

        return matchedPair
    }

    private func completeManagedReplacement(
        destroy: PendingManagedDestroy,
        create: PendingManagedCreate
    ) -> ManagedWindowIdentityRebindResult {
        let result = rekeyManagedReplacement(from: destroy.candidate.token, to: create.candidate)
        guard result.isHandled else {
            return result
        }
        completeDelayedFocusedManagedAdmission(create)
        return result
    }

    private func completeDelayedFocusedManagedAdmission(_ create: PendingManagedCreate) {
        guard let activation = create.focusedActivation,
              let controller,
              let entry = controller.workspaceManager.entry(for: create.candidate.token)
        else {
            return
        }

        let targetMonitor = controller.workspaceManager.monitor(for: entry.workspaceId)
        let isWorkspaceActive = targetMonitor.map { monitor in
            controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == entry.workspaceId
        } ?? false
        let requestDisposition: ActivationRequestDisposition
        let shouldBindCurrentPidRequest: Bool
        switch activation.request {
        case let .matchesActiveRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .matchesActiveRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case let .conflictsWithPendingRequest(requestId):
            if let request = controller.intentLedger.activeManagedRequest(requestId: requestId) {
                requestDisposition = .conflictsWithPendingRequest(request)
                shouldBindCurrentPidRequest = true
            } else {
                requestDisposition = .unrelatedNoRequest
                shouldBindCurrentPidRequest = false
            }
        case .unrelatedNoRequest:
            requestDisposition = .unrelatedNoRequest
            shouldBindCurrentPidRequest = false
        }
        completeFocusedManagedAdmission(
            entry: entry,
            isWorkspaceActive: isWorkspaceActive,
            activation: activation,
            requestDisposition: requestDisposition,
            bindCurrentPidRequest: shouldBindCurrentPidRequest
        )
    }

    private func replayManagedReplacementEvents(_ events: [PendingManagedReplacementEvent]) {
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event {
            case let .create(create):
                trackPreparedCreate(create.candidate)
                completeDelayedFocusedManagedAdmission(create)
            case let .destroy(destroy):
                processPreparedDestroy(destroy.candidate)
            }
        }
    }

    private func rekeyManagedReplacement(
        from oldToken: WindowToken,
        to create: PreparedCreate
    ) -> ManagedWindowIdentityRebindResult {
        rekeyManagedWindowIdentity(
            from: oldToken,
            to: create.token,
            windowId: create.windowId,
            axRef: create.axRef,
            managedReplacementMetadata: create.replacementMetadata,
            admissionHints: create.admissionHints
        )
    }

    private func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence
        )
    }

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
    }

    private func cachedManagedReplacementMetadata(
        for entry: WindowState,
        fallbackBundleId: String?
    ) -> ManagedReplacementMetadata {
        var metadata = entry.managedReplacementMetadata ?? ManagedReplacementMetadata(
            bundleId: fallbackBundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        metadata.bundleId = metadata.bundleId ?? fallbackBundleId
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        if entry.mode == .floating,
           let floatingFrame = controller?.workspaceManager.floatingState(for: entry.token)?.lastFrame
        {
            metadata.frame = floatingFrame
        } else if let appliedFrame = controller?.axManager.lastAppliedFrame(for: entry.windowId) {
            metadata.frame = appliedFrame
        }
        return metadata
    }

    private func overlayWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        onto metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementMetadata {
        guard let windowInfo else { return metadata }
        var metadata = metadata
        metadata.title = windowInfo.title ?? metadata.title
        metadata.windowLevel = windowInfo.level
        metadata.parentWindowId = normalizedParentWindowId(windowInfo.parentId) ?? metadata.parentWindowId
        if !windowInfo.frame.isNull, !windowInfo.frame.isEmpty {
            metadata.frame = windowInfo.frame
        }
        return metadata
    }

    private func managedReplacementFacts(
        for axRef: AXWindowRef,
        pid: pid_t,
        bundleId: String?,
        windowInfo: WindowServerInfo?,
        includeTitle: Bool
    ) -> WindowRuleFacts {
        let app = NSRunningApplication(processIdentifier: pid)
        return WindowRuleFacts(
            appName: app?.localizedName,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: app?.activationPolicy,
                bundleId: bundleId,
                includeTitle: includeTitle
            ),
            sizeConstraints: nil,
            windowServer: windowInfo
        )
    }

    private func managedReplacementNeedsLiveAXFacts(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        guard metadata.role != nil, metadata.subrole != nil else {
            return true
        }
        return !managedReplacementHasStructuralAnchor(metadata)
    }

    func structuralReplacementMatch(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        capturedWindowServerInfoByWindowId: [Int: WindowServerInfo]? = nil,
        capturedWindowServerAuthoritativeWindowIds: Set<Int>? = nil,
        capturedWindowServerAuthoritativePIDs: Set<pid_t>? = nil
    ) -> StructuralReplacementMatch? {
        guard let controller,
              let fallbackWorkspaceId = controller.activeWorkspace()?.id
              ?? controller.workspaceManager.primaryWorkspace()?.id
              ?? controller.workspaceManager.workspaces.first?.id
        else {
            return nil
        }

        let baseMetadata = makeManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: fallbackWorkspaceId,
            mode: mode,
            facts: facts
        )
        guard managedReplacementCorrelationPolicy(for: baseMetadata) != nil else { return nil }

        var match: StructuralReplacementMatch?
        var visibleWindowIds: Set<Int>?

        func oldLiveTokenIsInvisible(_ token: WindowToken) -> Bool {
            if let capturedWindowServerInfoByWindowId {
                if let capturedWindowServerAuthoritativeWindowIds {
                    return capturedWindowServerAuthoritativeWindowIds.contains(token.windowId)
                        && (
                            capturedWindowServerAuthoritativePIDs?.contains(token.pid)
                                ?? true
                        )
                        && capturedWindowServerInfoByWindowId[token.windowId] == nil
                }
                return !capturedWindowServerInfoByWindowId.isEmpty
                    && capturedWindowServerInfoByWindowId[token.windowId] == nil
            }
            if visibleWindowIds == nil {
                visibleWindowIds = Set(visibleWindowInfoProvider().map { Int($0.id) })
            }
            guard let visibleWindowIds, !visibleWindowIds.isEmpty else { return false }
            return !visibleWindowIds.contains(token.windowId)
        }

        func windowServerInfo(for windowId: Int) -> WindowServerInfo? {
            if let capturedWindowServerInfoByWindowId {
                return capturedWindowServerInfoByWindowId[windowId]
            }
            return UInt32(exactly: windowId).flatMap(resolveWindowInfo)
        }

        func recordMatch(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            source: StructuralReplacementMatchSource
        ) -> Bool {
            if let match {
                return match.token == token
            }
            match = StructuralReplacementMatch(token: token, workspaceId: workspaceId, source: source)
            return true
        }

        func matches(_ oldMetadata: ManagedReplacementMetadata, oldToken: WindowToken) -> Bool {
            var newMetadata = baseMetadata
            newMetadata.workspaceId = oldMetadata.workspaceId
            return managedReplacementMetadataMatches(
                oldToken: oldToken,
                old: oldMetadata,
                new: newMetadata,
                newFacts: facts
            )
        }

        for burst in pendingManagedReplacementBursts.values {
            for destroy in burst.destroys where destroy.candidate.token.pid == token.pid {
                let metadata = destroy.candidate.replacementMetadata
                if matches(metadata, oldToken: destroy.candidate.token),
                   !recordMatch(
                       token: destroy.candidate.token,
                       workspaceId: metadata.workspaceId,
                       source: .pendingDestroy
                   )
                {
                    return nil
                }
            }
        }

        for entry in controller.workspaceManager.entries(forPid: token.pid) where entry.token != token {
            guard oldLiveTokenIsInvisible(entry.token) else { continue }

            let cachedMetadata = cachedManagedReplacementMetadata(
                for: entry,
                fallbackBundleId: bundleId
            )
            if matches(cachedMetadata, oldToken: entry.token),
               !recordMatch(
                   token: entry.token,
                   workspaceId: cachedMetadata.workspaceId,
                   source: .liveInvisible
               )
            {
                return nil
            }
            if match?.token == entry.token {
                continue
            }
            let liveMetadata = overlayWindowServerInfo(
                windowServerInfo(for: entry.windowId),
                onto: cachedMetadata
            )
            if liveMetadata != cachedMetadata,
               matches(liveMetadata, oldToken: entry.token),
               !recordMatch(
                   token: entry.token,
                   workspaceId: liveMetadata.workspaceId,
                   source: .liveInvisible
               )
            {
                return nil
            }
        }

        return match
    }

    private func managedReplacementCorrelationPolicy(
        for metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementCorrelationPolicy? {
        guard metadata.role != nil,
              metadata.subrole != nil,
              managedReplacementHasStructuralAnchor(metadata)
        else { return nil }
        return .structural
    }

    private func managedReplacementMetadataMatches(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        if managedReplacementIsDirectFloatingChild(oldToken: oldToken, new: new, newFacts: newFacts) {
            return false
        }

        guard managedReplacementCorrelationPolicy(for: old) != nil,
              managedReplacementCorrelationPolicy(for: new) != nil,
              managedReplacementBundleIdsMatch(old.bundleId, new.bundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole,
              managedReplacementWindowLevelsMatch(old.windowLevel, new.windowLevel)
        else {
            return false
        }

        return managedReplacementStructuralAnchorsMatch(oldToken: oldToken, old: old, new: new)
    }

    private func managedReplacementIsDirectFloatingChild(
        oldToken: WindowToken,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        guard new.mode == .floating,
              let oldWindowId = UInt32(exactly: oldToken.windowId),
              new.parentWindowId == oldWindowId
        else {
            return false
        }

        if managedReplacementHasAXChildEvidence(new) {
            return true
        }

        if new.degradedWindowServerChildEvidence {
            return true
        }

        return newFacts?.degradedWindowServerChildEvidence == true
    }

    private func managedReplacementHasAXChildEvidence(_ metadata: ManagedReplacementMetadata) -> Bool {
        if metadata.role == kAXSheetRole as String {
            return true
        }

        guard let subrole = metadata.subrole else {
            return false
        }

        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole != kAXStandardWindowSubrole as String
    }

    private func managedReplacementHasStructuralAnchor(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        metadata.parentWindowId != nil || metadata.frame != nil
    }

    private func managedReplacementBundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func managedReplacementWindowLevelsMatch(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func managedReplacementStructuralAnchorsMatch(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        let framesClose = framesAreCloseForManagedReplacement(old.frame, new.frame)
        let hasFrameEvidence = old.frame != nil && new.frame != nil

        switch (old.parentWindowId, new.parentWindowId) {
        case let (oldParentWindowId?, newParentWindowId?) where oldParentWindowId == newParentWindowId:
            return hasFrameEvidence ? framesClose : true
        case let (_, newParentWindowId?) where UInt32(exactly: oldToken.windowId) == newParentWindowId:
            return framesClose
        case (_?, _?):
            return false
        default:
            return framesClose
        }
    }

    private func framesAreCloseForManagedReplacement(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= 96
            && abs(lhs.midY - rhs.midY) <= 96
            && abs(lhs.width - rhs.width) <= 64
            && abs(lhs.height - rhs.height) <= 64
    }

    private func managedReplacementGraceDelay(for policy: ManagedReplacementCorrelationPolicy) -> Duration {
        switch policy {
        case .structural:
            Self.managedReplacementGraceDelay
        }
    }

    private func scheduleManagedReplacementFlush(
        for key: ManagedReplacementKey,
        policy: ManagedReplacementCorrelationPolicy,
        resetExistingDeadline: Bool
    ) {
        if resetExistingDeadline {
            pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        } else if pendingManagedReplacementTasks[key] != nil {
            return
        }

        let delay = managedReplacementGraceDelay(for: policy)
        pendingManagedReplacementTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushManagedReplacementBurst(for: key)
        }
    }

    private func flushManagedReplacementBurst(for key: ManagedReplacementKey) {
        pendingManagedReplacementTasks.removeValue(forKey: key)?.cancel()
        guard let burst = pendingManagedReplacementBursts.removeValue(forKey: key) else { return }
        markManagedReplacementFocusBurstClosed(for: key)
        let elapsedMillis = max(
            0,
            Int(((managedReplacementCurrentUptime() - burst.firstEventUptime) * 1000).rounded())
        )
        recordManagedReplacementTrace(
            key: key,
            kind: .flushed(
                policy: managedReplacementPolicyName(burst.policy),
                createCount: burst.creates.count,
                destroyCount: burst.destroys.count,
                holdCount: 0,
                elapsedMillis: elapsedMillis
            )
        )

        if let pair = matchedManagedReplacementPair(in: burst) {
            let closeProbe = sameAppCloseProbePayload(
                matchingFocusedToken: pair.destroy.candidate.token
            )
            let result = completeManagedReplacement(destroy: pair.destroy, create: pair.create)
            switch result {
            case .committed:
                cancelSameAppCloseProbe(matchingDestroyIn: burst)
            case .pending:
                cancelSameAppCloseProbe(
                    matchingDestroyIn: burst,
                    excludingFocusedToken: pair.destroy.candidate.token
                )
            case .rejected:
                cancelSameAppCloseProbe(matchingDestroyIn: burst)
                replayManagedReplacementEvents(burst.orderedEvents)
                return
            }
            recordManagedReplacementTrace(
                key: key,
                kind: .matched(
                    policy: managedReplacementPolicyName(burst.policy),
                    elapsedMillis: elapsedMillis
                )
            )
            replayManagedReplacementEvents(
                burst.orderedEvents(excludingSequences: pair.excludedSequences)
            )
            if case .committed = result,
               let closeProbe
            {
                let focusedToken = controller?.workspaceManager.entry(for: pair.create.candidate.token) != nil
                    ? pair.create.candidate.token
                    : pair.destroy.candidate.token
                handleSameAppCloseProbeDeadline(closeProbe, focusedToken: focusedToken)
            }
            return
        }

        cancelSameAppCloseProbe(matchingDestroyIn: burst)
        replayManagedReplacementEvents(burst.orderedEvents)
    }

    private func cancelSameAppCloseProbe(
        matchingDestroyIn burst: PendingManagedReplacementBurst,
        excludingFocusedToken excludedToken: WindowToken? = nil
    ) {
        guard let open = controller?.intentLedger.openSameAppCloseProbe(),
              open.payload.focusedToken != excludedToken,
              burst.destroys.contains(where: {
                  $0.candidate.token == open.payload.focusedToken
              })
        else {
            return
        }
        cancelSameAppCloseProbe(
            matchingFocusedToken: open.payload.focusedToken,
            reason: "managed_replacement_destroy_replayed"
        )
    }

    private func nextManagedReplacementSequence() -> UInt64 {
        defer { nextManagedReplacementEventSequence += 1 }
        return nextManagedReplacementEventSequence
    }

    private func updateManagedReplacementTitle(windowId: UInt32, token: WindowToken) {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              let title = resolveWindowInfo(windowId)?.title ?? AXWindowService.titlePreferFast(windowId: windowId)
        else {
            return
        }
        _ = controller.workspaceManager.updateManagedReplacementTitle(title, for: entry.token)
    }

    private func handleMissingFocusedWindow(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        requestDisposition: ActivationRequestDisposition
    ) {
        guard let controller else { return }
        if let activeRequest = controller.intentLedger.activeManagedRequest,
           managedWindowToken(activeRequest.token, matchesObservedPid: pid)
        {
            guard origin == .retry else { return }
            continueManagedFocusRequest(
                activeRequest,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return
        }
        if let focusedToken = controller.workspaceManager.focusedToken,
           managedWindowToken(focusedToken, matchesObservedPid: pid)
        {
            return
        }

        switch requestDisposition {
        case let .matchesActiveRequest(request),
             let .conflictsWithPendingRequest(request):
            if shouldHonorObservedFocusOverPendingRequest(
                observedToken: nil,
                source: source,
                origin: origin
            ) {
                clearManagedFocusState(
                    matching: request.token,
                    workspaceId: request.workspaceId
                )
                break
            }
            guard origin == .retry else { return }
            continueManagedFocusRequest(
                request,
                source: source,
                origin: origin,
                reason: .missingFocusedWindow
            )
            return
        case .unrelatedNoRequest:
            break
        }

        _ = controller.workspaceManager.enterNonManagedFocus()
        recordNiriCreateFocusTrace(
            .init(
                kind: .nonManagedFallbackEntered(
                    pid: pid,
                    source: source
                )
            )
        )
    }

    private func activationRequestDisposition(
        for pid: pid_t,
        token: WindowToken?,
        activeRequest: ManagedFocusRequest?
    ) -> ActivationRequestDisposition {
        guard let activeRequest else { return .unrelatedNoRequest }
        if let token {
            return activeRequest.token == token
                ? .matchesActiveRequest(activeRequest)
                : .conflictsWithPendingRequest(activeRequest)
        }
        return managedWindowToken(activeRequest.token, matchesObservedPid: pid)
            ? .matchesActiveRequest(activeRequest)
            : .conflictsWithPendingRequest(activeRequest)
    }

    private func shouldHandleObservedManagedActivationWithoutPendingRequest(
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        isWorkspaceActive: Bool
    ) -> Bool {
        guard !isWorkspaceActive else { return true }

        switch source {
        case .focusedWindowChanged:
            return true
        case .workspaceDidActivateApplication,
             .cgsFrontAppChanged:
            return origin == .external
        }
    }

    private func shouldHonorObservedFocusOverPendingRequest(
        observedToken: WindowToken?,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) -> Bool {
        guard source.isAuthoritative, origin == .external else { return false }
        guard let controller, let observedToken else { return true }
        switch controller.intentLedger.classifyFocusObservation(token: observedToken) {
        case .echoOf,
             .lateEcho:
            return false
        case .external:
            return true
        }
    }

    func cleanupFocusStateForTerminatedApp(pid: pid_t) {
        guard let controller else { return }

        cleanupAdmissionStateForTerminatedApp(pid: pid)
        admissionQuarantineByWindowId = admissionQuarantineByWindowId.filter { $0.value.token.pid != pid }
        terminalFrameFailureStateByWindowId = terminalFrameFailureStateByWindowId.filter { windowId, _ in
            controller.workspaceManager.entry(forWindowId: windowId)?.pid != pid
        }
        clearManagedReplacementFocusTransactions(pid: pid, reason: "app_terminated")
        let entries = controller.workspaceManager.entries(forPid: pid)
        for entry in entries {
            clearManagedFocusState(
                matching: entry.token,
                workspaceId: controller.workspaceManager.workspace(for: entry.token) ?? entry.workspaceId
            )
        }

        if let activeRequest = controller.intentLedger.activeManagedRequest,
           activeRequest.token.pid == pid
        {
            clearManagedFocusState(
                matching: activeRequest.token,
                workspaceId: activeRequest.workspaceId
            )
        }

        controller.workspaceManager.clearNonManagedFocusTarget(pid: pid)
    }

    func clearManagedFocusState(
        matching token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) {
        guard let controller else { return }

        controller.intentLedger.discardPendingFocus(token)
        let canceledRequest = controller.intentLedger.cancelManagedRequest(
            matching: token,
            workspaceId: workspaceId
        )
        if let canceledRequest {
            _ = controller.workspaceManager.cancelManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId,
                requestId: canceledRequest.requestId
            )
        } else {
            _ = controller.workspaceManager.cancelCurrentManagedFocusRequest(
                matching: token,
                workspaceId: workspaceId
            )
        }
        controller.workspaceManager.clearNonManagedFocusTarget(matching: token)
    }

    private func continueManagedFocusRequest(
        _ request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        reason: ActivationRetryReason
    ) {
        guard let controller else { return }
        if let updatedRequest = controller.intentLedger.recordRetry(
            requestId: request.requestId,
            source: source,
            retryLimit: Self.activationRetryLimit
        ) {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .activationDeferred(
                        requestId: updatedRequest.requestId,
                        token: updatedRequest.token,
                        source: source,
                        reason: reason,
                        attempt: updatedRequest.retryCount
                    )
                )
            )
            return
        }
        guard origin != .probe else {
            return
        }
        handleActivationRetryExhausted(
            request: request,
            source: source,
            origin: origin
        )
    }

    private func handleActivationRetryExhausted(
        request: ManagedFocusRequest,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        guard let controller else { return }

        _ = controller.intentLedger.cancelManagedRequest(requestId: request.requestId)
        _ = controller.workspaceManager.cancelManagedFocusRequest(
            matching: request.token,
            workspaceId: request.workspaceId,
            requestId: request.requestId
        )

        if let token = controller.workspaceManager.renderableFocusToken {
            controller.surfaceReconciler.noteRestackOccurred()
            recordNiriCreateFocusTrace(
                .init(
                    kind: .borderReapplied(
                        token: token,
                        phase: .retryExhaustedFallback
                    )
                )
            )
        } else {
            recordNiriCreateFocusTrace(
                .init(
                    kind: .nonManagedFallbackEntered(
                        pid: request.token.pid,
                        source: source
                    )
                )
            )
        }
    }

    private func deferCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.insert(windowId).inserted else { return }
        deferredCreatedWindowOrder.append(windowId)
    }

    func removeDeferredCreatedWindow(_ windowId: UInt32) {
        guard deferredCreatedWindowIds.remove(windowId) != nil else { return }
        deferredCreatedWindowOrder.removeAll { $0 == windowId }
    }
}

extension AXEventHandler {
    private func liveCreateSpace(
        for windowId: UInt32,
        spaceIdsForWindow: (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) -> UInt64 {
        guard let controller else { return 0 }
        return controller.workspaceManager.spaceTopology
            .selectWindowSpace(from: spaceIdsForWindow(windowId)) ?? 0
    }

    private func handleCGSWindowDestroyed(
        windowId: UInt32,
        evidence: WindowDestroyEvidence
    ) {
        AXWindowService.invalidateCachedTitle(windowId: windowId)
        cancelCreatedWindowRetry(windowId: windowId)
        discardCreatePlacementContext(windowId: windowId)
        removeDeferredCreatedWindow(windowId)
        rejectDeferredReplacement(windowId: windowId)
        handleWindowDestroyed(windowId: windowId, pidHint: nil, evidence: evidence)
    }

    private func handleRemoved(token: WindowToken, evidence: WindowDestroyEvidence) {
        guard let controller else { return }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            discardRemovedWindowRuntimeState(token)
            scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
            return
        }

        if handleNativeFullscreenDestroy(token, evidence: evidence) {
            discardRemovedWindowRuntimeState(token)
            return
        }

        let recovery = prepareManagedWindowRemoval(entry)
        retireManagedWindow(
            entry,
            reason: .destroyed(
                shouldRecoverFocus: recovery.shouldRecoverFocus,
                allowsPreferredRecoveryToken: recovery.closeRecoveryArmed
            )
        )
        scheduleWindowRuleReevaluationIfNeeded(targets: [.pid(token.pid)])
    }
}
