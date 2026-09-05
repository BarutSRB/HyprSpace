// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

typealias IntentID = UInt64

struct ManagedFocusRetryRuntimeSnapshot: Equatable, Sendable {
    var attempts: UInt64 = 0
    var sourceChanges: UInt64 = 0
    var deadlineRearms: UInt64 = 0
    var exhaustions: UInt64 = 0
}

struct ReplacementFocusPayload: Equatable, Sendable {
    var pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
    var anchorToken: WindowToken
    var protectedTokens: Set<WindowToken>
    var isBurstOpen: Bool

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if anchorToken == oldToken {
            anchorToken = newToken
        }
        if protectedTokens.remove(oldToken) != nil {
            protectedTokens.insert(newToken)
        }
    }

    func protects(_ token: WindowToken) -> Bool {
        protectedTokens.contains(token)
    }

    func suppressesUnrelatedActivation(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        token.pid == pid
            && workspaceId == self.workspaceId
            && !protects(token)
    }
}

struct SameAppCloseProbePayload: Equatable, Sendable {
    let focusedToken: WindowToken
    let observedToken: WindowToken
    let source: ActivationEventSource
    var observationGeneration: UInt64
}

enum AppTerminationFocusRecoveryPhase: Equatable, Sendable {
    case verifying(
        candidatePID: pid_t,
        source: ActivationEventSource,
        callbackGeneration: UInt64?
    )
    case recovering(fallbackPID: pid_t?)
    case retiring(fallbackPID: pid_t?)
}

struct AppTerminationFocusRecoveryPayload: Equatable, Sendable {
    var departingToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var preferredTiledToken: WindowToken
    var phase: AppTerminationFocusRecoveryPhase
    var terminationHandled = false

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if departingToken == oldToken {
            departingToken = newToken
        }
        if preferredTiledToken == oldToken {
            preferredTiledToken = newToken
        }
    }
}

struct AppRevealFocusPayload: Equatable, Sendable {
    var token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let handleIdentity: ObjectIdentifier
    let coordinatedAppGenerations: [pid_t: UInt64]
    var pendingAppPIDs: Set<pid_t>
    let focusIntentWatermark: IntentID?
    var focusFingerprint: AppRevealFocusFingerprint
    let destination: AppRevealFocusDestination
}

enum AppRevealFocusDestination: Equatable, Sendable {
    case window
    case scratchpad(index: ScratchpadIndex, monitorId: Monitor.ID?)
    case scratchpadWindow(index: ScratchpadIndex, monitorId: Monitor.ID?)

    var traceDestination: AppVisibilityTrace.Destination {
        switch self {
        case .window:
            .window
        case .scratchpad,
             .scratchpadWindow:
            .scratchpad
        }
    }
}

enum AppRevealFocusDrainResult: Equatable, Sendable {
    case awaitingApps
    case ready
}

struct AppRevealFocusFingerprint: Equatable, Sendable {
    var selectedManagedToken: WindowToken?
    var pendingFocusedToken: WindowToken?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    var nativeFocusOwner: NativeFocusOwner
    let interactionMonitorId: Monitor.ID?
    let activeWorkspaceIdsByMonitor: [Monitor.ID: WorkspaceDescriptor.ID]

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if selectedManagedToken == oldToken {
            selectedManagedToken = newToken
        }
        if pendingFocusedToken == oldToken {
            pendingFocusedToken = newToken
        }
        switch nativeFocusOwner {
        case let .managed(token) where token == oldToken:
            nativeFocusOwner = .managed(newToken)
        case let .external(identity):
            nativeFocusOwner = .external(identity.rekeying(from: oldToken, to: newToken))
        case .managed,
             .ownedSurface,
             .none:
            break
        }
    }
}

enum IntentKind: Equatable, Sendable {
    case activateApp(pid: pid_t)
    case appTerminationFocusRecovery(AppTerminationFocusRecoveryPayload)
    case appRevealFocus(AppRevealFocusPayload)
    case focusPolicyLease(owner: FocusPolicyLeaseOwner)
    case focusWindow(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        phase: ManagedFocusRequest.Phase = .awaitingConfirmation
    )
    case replacementFocus(ReplacementFocusPayload)
    case sameAppCloseProbe(SameAppCloseProbePayload)

    var focusTargetToken: WindowToken? {
        switch self {
        case .activateApp,
             .appTerminationFocusRecovery,
             .appRevealFocus,
             .focusPolicyLease,
             .replacementFocus,
             .sameAppCloseProbe:
            nil
        case let .focusWindow(token, _, _):
            token
        }
    }

    var isFocusWindow: Bool {
        if case .focusWindow = self {
            return true
        }
        return false
    }

    var targetPid: pid_t? {
        switch self {
        case let .activateApp(pid):
            pid
        case let .appTerminationFocusRecovery(payload):
            switch payload.phase {
            case let .verifying(candidatePID, _, _):
                candidatePID
            case let .recovering(fallbackPID),
                 let .retiring(fallbackPID):
                fallbackPID
            }
        case let .appRevealFocus(payload):
            payload.token.pid
        case .focusPolicyLease:
            nil
        case let .focusWindow(token, _, _):
            token.pid
        case let .replacementFocus(payload):
            payload.pid
        case let .sameAppCloseProbe(payload):
            payload.observedToken.pid
        }
    }
}

enum IntentPhase: Equatable, Sendable {
    case pending
    case confirmed
    case superseded
    case expired
    case cancelled

    var isRetired: Bool {
        self != .pending
    }
}

struct Intent: Equatable, Sendable {
    let id: IntentID
    var kind: IntentKind
    var origin: ManagedFocusOrigin
    let issuedAtSeq: UInt64
    var phase: IntentPhase = .pending
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var retiredAt: ContinuousClock.Instant?

    var asManagedFocusRequest: ManagedFocusRequest? {
        guard case let .focusWindow(token, workspaceId, requestPhase) = kind else { return nil }
        return ManagedFocusRequest(
            requestId: id,
            token: token,
            workspaceId: workspaceId,
            origin: origin,
            phase: requestPhase,
            retryCount: retryCount,
            lastActivationSource: lastActivationSource,
            status: phase == .confirmed ? .confirmed : .pending
        )
    }
}

enum EchoClassification: Equatable {
    case echoOf(Intent)
    case lateEcho(Intent)
    case external
}

@MainActor
final class IntentLedger {
    static let capacity = 256
    static let activationSettleDeadline: Duration = .milliseconds(100)
    static let sameAppActivationHandoffDeadline: Duration = .milliseconds(40)
    static let appRevealDeadline: Duration = .seconds(2)
    private static let lateEchoWindow: Duration = .seconds(1)
    private var managedFocusRetryMetricsActive = false
    private var managedFocusRetryMetrics = ManagedFocusRetryRuntimeSnapshot()

    var seqProvider: () -> UInt64 = { 0 }
    var clock: () -> ContinuousClock.Instant = { ContinuousClock().now }
    weak var deadlineWheel: DeadlineWheel?

    private(set) var entries: [Intent] = []
    private(set) var lastConfirmedManagedFocus: (token: WindowToken, origin: ManagedFocusOrigin)?
    private var nextIntentId: IntentID = 1
    private var intentIssuanceGeneration: UInt64 = 0
    private var deferredRetryRaise: (request: ManagedFocusRequest, job: RunLoopJob?)?

    var activeManagedRequest: ManagedFocusRequest? {
        entries.last { $0.phase == .pending && $0.kind.isFocusWindow }?.asManagedFocusRequest
    }

    func activeManagedRequest(for pid: pid_t) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token.pid == pid else { return nil }
        return request
    }

    func activeManagedRequest(for token: WindowToken) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token == token else { return nil }
        return request
    }

    func activeManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.requestId == requestId else { return nil }
        return request
    }

    func enableDeferredRetryRaise(for request: ManagedFocusRequest) {
        cancelDeferredRetryRaise()
        guard activeManagedRequest(requestId: request.requestId) == request else { return }
        deferredRetryRaise = (request, nil)
    }

    func defersRetryRaise(for request: ManagedFocusRequest) -> Bool {
        guard let pending = deferredRetryRaise else { return false }
        return pending.request.requestId == request.requestId
            && pending.request.token == request.token
            && pending.request.workspaceId == request.workspaceId
    }

    func beginDeferredRetryRaise(for request: ManagedFocusRequest) -> RunLoopJob? {
        guard defersRetryRaise(for: request), deferredRetryRaise?.job == nil,
              activeManagedRequest(requestId: request.requestId)?.phase == .awaitingConfirmation
        else { return nil }
        let job = RunLoopJob()
        deferredRetryRaise?.job = job
        return job
    }

    func completeDeferredRetryRaise(job: RunLoopJob) -> ManagedFocusRequest? {
        guard let pending = deferredRetryRaise, pending.job === job,
              let request = activeManagedRequest(requestId: pending.request.requestId),
              defersRetryRaise(for: request), request.phase == .awaitingConfirmation
        else { return nil }
        deferredRetryRaise?.job = nil
        return request
    }

    private func cancelDeferredRetryRaise(rearmingRequest: Bool = false) {
        if rearmingRequest, let pending = deferredRetryRaise, pending.job != nil {
            deadlineWheel?.schedule(intentId: pending.request.requestId, after: Self.activationSettleDeadline)
        }
        deferredRetryRaise?.job?.cancel()
        deferredRetryRaise = nil
    }

    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ManagedFocusRequest {
        if let index = openIndex(where: {
            guard case let .focusWindow(currentToken, currentWorkspaceId, _) = $0.kind else {
                return false
            }
            return currentToken == token && currentWorkspaceId == workspaceId
        }) {
            cancelDeferredRetryRaise(rearmingRequest: true)
            intentIssuanceGeneration &+= 1
            entries[index].origin = entries[index].origin.merged(with: origin)
            if entries[index].origin != .focusFollowsMouse,
               case .focusWindow(token, workspaceId, .awaitingSameAppActivation) = entries[index].kind
            {
                entries[index].kind = .focusWindow(
                    token: token,
                    workspaceId: workspaceId,
                    phase: .awaitingConfirmation
                )
                deadlineWheel?.schedule(intentId: entries[index].id, after: Self.activationSettleDeadline)
            }
            return entries[index].asManagedFocusRequest!
        }

        for entry in entries where entry.phase == .pending && entry.kind.isFocusWindow {
            _ = supersede(id: entry.id)
            deadlineWheel?.cancel(intentId: entry.id)
        }

        let intent = append(
            kind: .focusWindow(token: token, workspaceId: workspaceId),
            origin: origin
        )
        deadlineWheel?.schedule(intentId: intent.id, after: Self.activationSettleDeadline)
        return intent.asManagedFocusRequest!
    }

    @discardableResult
    func retargetManagedRequest(
        requestId: IntentID,
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(currentToken, _, requestPhase) = entries[index].kind,
              currentToken == token
        else {
            return nil
        }
        if deferredRetryRaise?.request.requestId == requestId {
            cancelDeferredRetryRaise(rearmingRequest: true)
        }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: requestPhase
        )
        return entries[index].asManagedFocusRequest
    }

    func beginSameAppActivationHandoff(
        requestId: IntentID,
        sourceToken: WindowToken,
        isRetry: Bool = false
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(token, workspaceId, requestPhase) = entries[index].kind,
              token.pid == sourceToken.pid,
              token != sourceToken,
              entries[index].origin == .focusFollowsMouse
        else {
            return nil
        }
        let phase = ManagedFocusRequest.Phase.awaitingSameAppActivation(
            sourceToken: sourceToken,
            isRetry: isRetry
        )
        guard requestPhase != phase else { return entries[index].asManagedFocusRequest }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: phase
        )
        deadlineWheel?.schedule(intentId: requestId, after: Self.sameAppActivationHandoffDeadline)
        return entries[index].asManagedFocusRequest
    }

    func completeSameAppActivationHandoff(requestId: IntentID) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }),
              case let .focusWindow(token, workspaceId, .awaitingSameAppActivation) = entries[index].kind
        else {
            return nil
        }
        entries[index].kind = .focusWindow(
            token: token,
            workspaceId: workspaceId,
            phase: .awaitingConfirmation
        )
        deadlineWheel?.schedule(intentId: requestId, after: Self.activationSettleDeadline)
        return entries[index].asManagedFocusRequest
    }

    func recordRetry(
        requestId: UInt64,
        source: ActivationEventSource,
        retryLimit: Int
    ) -> ManagedFocusRequest? {
        guard let index = entries.firstIndex(where: { $0.id == requestId && $0.phase == .pending }) else {
            return nil
        }
        guard case .focusWindow(_, _, .awaitingConfirmation) = entries[index].kind else {
            return nil
        }
        if managedFocusRetryMetricsActive {
            managedFocusRetryMetrics.attempts += 1
            if let lastSource = entries[index].lastActivationSource, lastSource != source {
                managedFocusRetryMetrics.sourceChanges += 1
            }
        }
        let nextAttempt = entries[index].retryCount + 1
        guard nextAttempt <= retryLimit else {
            if managedFocusRetryMetricsActive {
                managedFocusRetryMetrics.exhaustions += 1
            }
            return nil
        }

        entries[index].retryCount = nextAttempt
        entries[index].lastActivationSource = source
        deadlineWheel?.schedule(intentId: requestId, after: Self.activationSettleDeadline)
        if managedFocusRetryMetricsActive {
            managedFocusRetryMetrics.deadlineRearms += 1
        }
        return entries[index].asManagedFocusRequest
    }

    func beginManagedFocusRetryRuntimeCapture() {
        managedFocusRetryMetrics = ManagedFocusRetryRuntimeSnapshot()
        managedFocusRetryMetricsActive = true
    }

    func endManagedFocusRetryRuntimeCapture() {
        managedFocusRetryMetricsActive = false
    }

    func managedFocusRetryRuntimeSnapshot() -> ManagedFocusRetryRuntimeSnapshot {
        managedFocusRetryMetrics
    }

    @discardableResult
    func confirmManagedRequest(
        token: WindowToken,
        source: ActivationEventSource
    ) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token == token else { return nil }
        if request.phase != .awaitingConfirmation,
           let index = entries.firstIndex(where: { $0.id == request.requestId }),
           case let .focusWindow(token, workspaceId, _) = entries[index].kind
        {
            entries[index].kind = .focusWindow(
                token: token,
                workspaceId: workspaceId,
                phase: .awaitingConfirmation
            )
        }
        guard let confirmed = confirm(id: request.requestId, source: source) else { return nil }
        deadlineWheel?.cancel(intentId: confirmed.id)
        lastConfirmedManagedFocus = (token: token, origin: confirmed.origin)
        return confirmed.asManagedFocusRequest
    }

    @discardableResult
    func cancelManagedRequest(
        matching token: WindowToken? = nil,
        workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest else { return nil }

        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        guard matchesToken, matchesWorkspace else { return nil }

        _ = cancel(id: request.requestId)
        deadlineWheel?.cancel(intentId: request.requestId)
        return request
    }

    @discardableResult
    func cancelManagedRequest(requestId: UInt64) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.requestId == requestId else {
            return nil
        }
        _ = cancel(id: requestId)
        deadlineWheel?.cancel(intentId: requestId)
        return request
    }

    func rekeyManagedRequest(from oldToken: WindowToken, to newToken: WindowToken) {
        rekey(from: oldToken, to: newToken)
        if let lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == oldToken {
            self.lastConfirmedManagedFocus = (token: newToken, origin: lastConfirmedManagedFocus.origin)
        }
    }

    func discardPendingFocus(_ token: WindowToken) {
        if deferredRetryRaise?.request.token == token {
            cancelDeferredRetryRaise()
        }
        if lastConfirmedManagedFocus?.token == token {
            lastConfirmedManagedFocus = nil
        }
    }

    func allowsMouseToFocusedWarp(for token: WindowToken) -> Bool {
        if let request = activeManagedRequest, request.token == token {
            return request.origin.allowsMouseToFocusedWarp
        }
        if let lastConfirmedManagedFocus, lastConfirmedManagedFocus.token == token {
            return lastConfirmedManagedFocus.origin.allowsMouseToFocusedWarp
        }
        return true
    }

    @discardableResult
    func registerActivateApp(pid: pid_t) -> Intent {
        if let index = openIndex(where: { $0.kind == .activateApp(pid: pid) }) {
            intentIssuanceGeneration &+= 1
            return entries[index]
        }
        return append(kind: .activateApp(pid: pid), origin: .keyboardOrProgrammatic)
    }

    @discardableResult
    func beginAppRevealFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        handleIdentity: ObjectIdentifier,
        pendingApps: [pid_t: UInt64],
        focusFingerprint: AppRevealFocusFingerprint,
        destination: AppRevealFocusDestination = .window
    ) -> Intent {
        for entry in entries where entry.phase == .pending {
            guard case .appRevealFocus = entry.kind else { continue }
            _ = supersede(id: entry.id)
            deadlineWheel?.cancel(intentId: entry.id)
        }

        let intent = append(
            kind: .appRevealFocus(
                AppRevealFocusPayload(
                    token: token,
                    workspaceId: workspaceId,
                    handleIdentity: handleIdentity,
                    coordinatedAppGenerations: pendingApps,
                    pendingAppPIDs: Set(pendingApps.keys),
                    focusIntentWatermark: newestFocusIntentId(),
                    focusFingerprint: focusFingerprint,
                    destination: destination
                )
            ),
            origin: .keyboardOrProgrammatic
        )
        deadlineWheel?.schedule(intentId: intent.id, after: Self.appRevealDeadline)
        AppVisibilityTrace.record(
            .reveal,
            pid: token.pid,
            outcome: .issued,
            intentId: intent.id,
            windowId: token.windowId,
            workspaceId: workspaceId,
            intentGeneration: pendingApps[token.pid],
            destination: destination.traceDestination
        )
        return intent
    }

    func openAppRevealFocusIntent(pid: pid_t) -> (intent: Intent, payload: AppRevealFocusPayload)? {
        guard let intent = entries.last(where: { entry in
            guard entry.phase == .pending,
                  case let .appRevealFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.pendingAppPIDs.contains(pid)
        }),
            case let .appRevealFocus(payload) = intent.kind
        else {
            return nil
        }
        return (intent, payload)
    }

    func drainAppRevealFocus(
        intentId: IntentID,
        pid: pid_t,
        appVisibilityGeneration: UInt64
    ) -> AppRevealFocusDrainResult? {
        guard let index = entries.firstIndex(where: { $0.id == intentId && $0.phase == .pending }),
              case var .appRevealFocus(payload) = entries[index].kind,
              payload.pendingAppPIDs.contains(pid),
              let expectedGeneration = payload.coordinatedAppGenerations[pid]
        else {
            return nil
        }
        guard appVisibilityGeneration == expectedGeneration &+ 1 else {
            _ = retire(
                id: intentId,
                phase: .cancelled,
                source: nil,
                reason: .visibilityGenerationChanged
            )
            deadlineWheel?.cancel(intentId: intentId)
            return nil
        }
        payload.pendingAppPIDs.remove(pid)
        entries[index].kind = .appRevealFocus(payload)
        return payload.pendingAppPIDs.isEmpty ? .ready : .awaitingApps
    }

    @discardableResult
    func confirmAppRevealFocus(intentId: IntentID) -> AppRevealFocusPayload? {
        guard let open = openIntent(id: intentId),
              case let .appRevealFocus(payload) = open.kind,
              payload.pendingAppPIDs.isEmpty,
              let intent = confirm(id: intentId),
              case let .appRevealFocus(confirmedPayload) = intent.kind
        else {
            return nil
        }
        deadlineWheel?.cancel(intentId: intentId)
        return confirmedPayload
    }

    func cancelAppRevealFocus(intentId: IntentID) {
        guard cancel(id: intentId) != nil else { return }
        deadlineWheel?.cancel(intentId: intentId)
    }

    func cancelAppRevealFocus(pid: pid_t) {
        guard let open = openAppRevealFocusIntent(pid: pid) else { return }
        cancelAppRevealFocus(intentId: open.intent.id)
    }

    @discardableResult
    func registerReplacementFocus(_ payload: ReplacementFocusPayload) -> Intent {
        append(kind: .replacementFocus(payload), origin: .keyboardOrProgrammatic)
    }

    func openReplacementFocusIntent(pid: pid_t, workspaceId: WorkspaceDescriptor.ID) -> Intent? {
        entries.last { entry in
            guard entry.phase == .pending,
                  case let .replacementFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.pid == pid && payload.workspaceId == workspaceId
        }
    }

    func openReplacementFocusIntents(pid: pid_t) -> [Intent] {
        entries.filter { entry in
            guard entry.phase == .pending,
                  case let .replacementFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.pid == pid
        }
    }

    func openReplacementFocusIntents() -> [Intent] {
        entries.filter { entry in
            guard entry.phase == .pending, case .replacementFocus = entry.kind else { return false }
            return true
        }
    }

    func updateReplacementFocus(id: IntentID, _ mutate: (inout ReplacementFocusPayload) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .replacementFocus(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .replacementFocus(payload)
    }

    @discardableResult
    func registerSameAppCloseProbe(_ payload: SameAppCloseProbePayload) -> Intent {
        append(kind: .sameAppCloseProbe(payload), origin: .keyboardOrProgrammatic)
    }

    @discardableResult
    func registerFocusPolicyLease(owner: FocusPolicyLeaseOwner) -> Intent {
        append(kind: .focusPolicyLease(owner: owner), origin: .keyboardOrProgrammatic)
    }

    func openSameAppCloseProbe() -> (intent: Intent, payload: SameAppCloseProbePayload)? {
        let open = entries.last { entry in
            guard entry.phase == .pending, case .sameAppCloseProbe = entry.kind else { return false }
            return true
        }
        guard let open, case let .sameAppCloseProbe(payload) = open.kind else { return nil }
        return (open, payload)
    }

    func updateSameAppCloseProbe(id: IntentID, _ mutate: (inout SameAppCloseProbePayload) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .sameAppCloseProbe(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .sameAppCloseProbe(payload)
    }

    @discardableResult
    func registerAppTerminationFocusRecovery(_ payload: AppTerminationFocusRecoveryPayload) -> Intent {
        if let open = openAppTerminationFocusRecovery() {
            _ = cancel(id: open.intent.id)
            deadlineWheel?.cancel(intentId: open.intent.id)
        }
        return append(kind: .appTerminationFocusRecovery(payload), origin: .keyboardOrProgrammatic)
    }

    func openAppTerminationFocusRecovery() -> (
        intent: Intent,
        payload: AppTerminationFocusRecoveryPayload
    )? {
        let open = entries.last { entry in
            guard entry.phase == .pending,
                  case .appTerminationFocusRecovery = entry.kind
            else {
                return false
            }
            return true
        }
        guard let open,
              case let .appTerminationFocusRecovery(payload) = open.kind
        else {
            return nil
        }
        return (open, payload)
    }

    func updateAppTerminationFocusRecovery(
        id: IntentID,
        _ mutate: (inout AppTerminationFocusRecoveryPayload) -> Void
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }),
              case var .appTerminationFocusRecovery(payload) = entries[index].kind
        else {
            return
        }
        mutate(&payload)
        entries[index].kind = .appTerminationFocusRecovery(payload)
    }

    func intent(id: IntentID) -> Intent? {
        entries.first { $0.id == id }
    }

    func openIntent(id: IntentID) -> Intent? {
        entries.first { $0.id == id && $0.phase == .pending }
    }

    func openFocusIntent(token: WindowToken) -> Intent? {
        entries.last { $0.phase == .pending && $0.kind.focusTargetToken == token }
    }

    func newestFocusIntentIssuedAtSeq() -> UInt64? {
        entries.last { $0.kind.isFocusWindow }?.issuedAtSeq
    }

    func newestFocusIntentId() -> IntentID? {
        entries.last { $0.kind.isFocusWindow }?.id
    }

    func issuanceWatermark() -> UInt64 {
        intentIssuanceGeneration
    }

    @discardableResult
    func confirm(id: IntentID, source: ActivationEventSource? = nil) -> Intent? {
        retire(id: id, phase: .confirmed, source: source)
    }

    @discardableResult
    func cancel(id: IntentID) -> Intent? {
        retire(id: id, phase: .cancelled, source: nil)
    }

    @discardableResult
    func supersede(id: IntentID) -> Intent? {
        retire(id: id, phase: .superseded, source: nil)
    }

    @discardableResult
    func markExpired(id: IntentID) -> Intent? {
        retire(id: id, phase: .expired, source: nil)
    }

    func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if deferredRetryRaise?.request.token == oldToken {
            cancelDeferredRetryRaise(rearmingRequest: true)
        }
        for index in entries.indices {
            if case let .focusWindow(token, workspaceId, requestPhase) = entries[index].kind {
                if oldToken.pid != newToken.pid,
                   case let .awaitingSameAppActivation(sourceToken, _) = requestPhase,
                   token == oldToken || sourceToken == oldToken
                {
                    let intentId = entries[index].id
                    _ = cancel(id: intentId)
                    deadlineWheel?.cancel(intentId: intentId)
                    continue
                }
                let rekeysTarget = token == oldToken
                let rekeyedPhase: ManagedFocusRequest.Phase
                let rekeysSource: Bool
                if case let .awaitingSameAppActivation(sourceToken, isRetry) = requestPhase,
                   sourceToken == oldToken
                {
                    rekeyedPhase = .awaitingSameAppActivation(
                        sourceToken: newToken,
                        isRetry: isRetry
                    )
                    rekeysSource = true
                } else {
                    rekeyedPhase = requestPhase
                    rekeysSource = false
                }
                guard rekeysTarget || rekeysSource else { continue }
                entries[index].kind = .focusWindow(
                    token: rekeysTarget ? newToken : token,
                    workspaceId: workspaceId,
                    phase: rekeyedPhase
                )
            } else if case var .appTerminationFocusRecovery(payload) = entries[index].kind,
                      payload.departingToken == oldToken || payload.preferredTiledToken == oldToken
            {
                if oldToken.pid == newToken.pid {
                    payload.rekey(from: oldToken, to: newToken)
                    entries[index].kind = .appTerminationFocusRecovery(payload)
                } else if entries[index].phase == .pending {
                    let intentId = entries[index].id
                    _ = retire(id: intentId, phase: .cancelled, source: nil)
                    deadlineWheel?.cancel(intentId: intentId)
                }
            } else if case var .appRevealFocus(payload) = entries[index].kind,
                      payload.token == oldToken
            {
                if oldToken.pid == newToken.pid {
                    if entries[index].phase == .pending {
                        AppVisibilityTrace.record(
                            .reveal,
                            pid: oldToken.pid,
                            outcome: .rekeyed,
                            intentId: entries[index].id,
                            windowId: newToken.windowId,
                            workspaceId: payload.workspaceId,
                            intentGeneration: payload.coordinatedAppGenerations[oldToken.pid],
                            destination: payload.destination.traceDestination
                        )
                    }
                    payload.token = newToken
                    payload.focusFingerprint.rekey(from: oldToken, to: newToken)
                    entries[index].kind = .appRevealFocus(payload)
                } else if entries[index].phase == .pending {
                    let intentId = entries[index].id
                    _ = retire(id: intentId, phase: .cancelled, source: nil, reason: .pidChanged)
                    deadlineWheel?.cancel(intentId: intentId)
                }
            }
        }
    }

    func classifyFocusObservation(token: WindowToken) -> EchoClassification {
        if let intent = openFocusIntent(token: token) {
            return .echoOf(intent)
        }
        let now = clock()
        let lateEcho = entries.last { entry in
            guard entry.phase.isRetired,
                  entry.kind.focusTargetToken == token,
                  let retiredAt = entry.retiredAt
            else {
                return false
            }
            return retiredAt.duration(to: now) <= Self.lateEchoWindow
        }
        if let lateEcho {
            return .lateEcho(lateEcho)
        }
        return .external
    }

    func reset() {
        cancelDeferredRetryRaise()
        intentIssuanceGeneration &+= 1
        entries.removeAll(keepingCapacity: false)
        lastConfirmedManagedFocus = nil
    }

    private func append(
        kind: IntentKind,
        origin: ManagedFocusOrigin
    ) -> Intent {
        let intent = Intent(
            id: nextIntentId,
            kind: kind,
            origin: origin,
            issuedAtSeq: seqProvider()
        )
        nextIntentId += 1
        intentIssuanceGeneration &+= 1
        entries.append(intent)
        trim()
        return intent
    }

    private func retire(
        id: IntentID,
        phase: IntentPhase,
        source: ActivationEventSource?,
        reason: AppVisibilityTrace.Reason? = nil
    ) -> Intent? {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }) else { return nil }
        if deferredRetryRaise?.request.requestId == id {
            cancelDeferredRetryRaise()
        }
        entries[index].phase = phase
        entries[index].retiredAt = clock()
        if let source {
            entries[index].lastActivationSource = source
        }
        if case let .appRevealFocus(payload) = entries[index].kind {
            let outcome: AppVisibilityTrace.Outcome
            let resolvedReason: AppVisibilityTrace.Reason?
            switch phase {
            case .pending:
                return entries[index]
            case .confirmed:
                outcome = .confirmed
                resolvedReason = reason
            case .superseded:
                outcome = .cancelled
                resolvedReason = .superseded
            case .expired:
                outcome = .expired
                resolvedReason = reason
            case .cancelled:
                outcome = .cancelled
                resolvedReason = reason
            }
            AppVisibilityTrace.record(
                .reveal,
                pid: payload.token.pid,
                outcome: outcome,
                intentId: id,
                windowId: payload.token.windowId,
                workspaceId: payload.workspaceId,
                intentGeneration: payload.coordinatedAppGenerations[payload.token.pid],
                destination: payload.destination.traceDestination,
                reason: resolvedReason
            )
        }
        return entries[index]
    }

    private func openIndex(where predicate: (Intent) -> Bool) -> Int? {
        entries.lastIndex { $0.phase == .pending && predicate($0) }
    }

    private func trim() {
        guard entries.count > Self.capacity else { return }
        var overflow = entries.count - Self.capacity
        entries.removeAll { entry in
            guard overflow > 0, entry.phase.isRetired else { return false }
            overflow -= 1
            return true
        }
    }
}
