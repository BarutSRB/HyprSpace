// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

typealias IntentID = UInt64

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

struct AppRevealFocusPayload: Equatable, Sendable {
    var token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let handleIdentity: ObjectIdentifier
    let appVisibilityGeneration: UInt64
    let focusIntentWatermark: IntentID?
    var focusFingerprint: AppRevealFocusFingerprint
    let destination: AppRevealFocusDestination
}

enum AppRevealFocusDestination: Equatable, Sendable {
    case window
    case scratchpad(monitorId: Monitor.ID?)
}

struct AppRevealFocusFingerprint: Equatable, Sendable {
    var focusedToken: WindowToken?
    var pendingFocusedToken: WindowToken?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    let isNonManagedFocusActive: Bool
    var nonManagedFocusToken: WindowToken?
    let interactionMonitorId: Monitor.ID?
    let activeWorkspaceIdsByMonitor: [Monitor.ID: WorkspaceDescriptor.ID]

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if focusedToken == oldToken {
            focusedToken = newToken
        }
        if pendingFocusedToken == oldToken {
            pendingFocusedToken = newToken
        }
        if nonManagedFocusToken == oldToken {
            nonManagedFocusToken = newToken
        }
    }
}

enum IntentKind: Equatable, Sendable {
    case activateApp(pid: pid_t)
    case appRevealFocus(AppRevealFocusPayload)
    case focusPolicyLease(owner: FocusPolicyLeaseOwner)
    case focusWindow(token: WindowToken, workspaceId: WorkspaceDescriptor.ID)
    case replacementFocus(ReplacementFocusPayload)
    case sameAppCloseProbe(SameAppCloseProbePayload)

    var focusTargetToken: WindowToken? {
        switch self {
        case .activateApp,
             .appRevealFocus,
             .focusPolicyLease,
             .replacementFocus,
             .sameAppCloseProbe:
            nil
        case let .focusWindow(token, _):
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
        case let .appRevealFocus(payload):
            payload.token.pid
        case .focusPolicyLease:
            nil
        case let .focusWindow(token, _):
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
        guard case let .focusWindow(token, workspaceId) = kind else { return nil }
        return ManagedFocusRequest(
            requestId: id,
            token: token,
            workspaceId: workspaceId,
            origin: origin,
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
    static let appRevealDeadline: Duration = .seconds(2)
    private static let lateEchoWindow: Duration = .seconds(1)

    var seqProvider: () -> UInt64 = { 0 }
    var clock: () -> ContinuousClock.Instant = { ContinuousClock().now }
    weak var deadlineWheel: DeadlineWheel?

    private(set) var entries: [Intent] = []
    private(set) var lastConfirmedManagedFocus: (token: WindowToken, origin: ManagedFocusOrigin)?
    private var nextIntentId: IntentID = 1

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

    func beginManagedRequest(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        origin: ManagedFocusOrigin = .keyboardOrProgrammatic
    ) -> ManagedFocusRequest {
        if let index = openIndex(where: { $0.kind == .focusWindow(token: token, workspaceId: workspaceId) }) {
            entries[index].origin = entries[index].origin.merged(with: origin)
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
              case let .focusWindow(currentToken, _) = entries[index].kind,
              currentToken == token
        else {
            return nil
        }
        entries[index].kind = .focusWindow(token: token, workspaceId: workspaceId)
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
        let retryCount = entries[index].lastActivationSource == source
            ? entries[index].retryCount
            : 0
        let nextAttempt = retryCount + 1
        guard nextAttempt <= retryLimit else { return nil }

        entries[index].retryCount = nextAttempt
        entries[index].lastActivationSource = source
        deadlineWheel?.schedule(intentId: requestId, after: Self.activationSettleDeadline)
        return entries[index].asManagedFocusRequest
    }

    @discardableResult
    func confirmManagedRequest(
        token: WindowToken,
        source: ActivationEventSource
    ) -> ManagedFocusRequest? {
        guard let request = activeManagedRequest, request.token == token else { return nil }
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
            return entries[index]
        }
        return append(kind: .activateApp(pid: pid), origin: .keyboardOrProgrammatic)
    }

    @discardableResult
    func beginAppRevealFocus(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        handleIdentity: ObjectIdentifier,
        appVisibilityGeneration: UInt64,
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
                    appVisibilityGeneration: appVisibilityGeneration,
                    focusIntentWatermark: newestFocusIntentId(),
                    focusFingerprint: focusFingerprint,
                    destination: destination
                )
            ),
            origin: .keyboardOrProgrammatic
        )
        deadlineWheel?.schedule(intentId: intent.id, after: Self.appRevealDeadline)
        return intent
    }

    func openAppRevealFocusIntent(pid: pid_t) -> (intent: Intent, payload: AppRevealFocusPayload)? {
        guard let intent = entries.last(where: { entry in
            guard entry.phase == .pending,
                  case let .appRevealFocus(payload) = entry.kind
            else {
                return false
            }
            return payload.token.pid == pid
        }),
            case let .appRevealFocus(payload) = intent.kind
        else {
            return nil
        }
        return (intent, payload)
    }

    @discardableResult
    func confirmAppRevealFocus(intentId: IntentID) -> AppRevealFocusPayload? {
        guard let intent = confirm(id: intentId),
              case let .appRevealFocus(payload) = intent.kind
        else {
            return nil
        }
        deadlineWheel?.cancel(intentId: intentId)
        return payload
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

    func openIntents(pid: pid_t) -> [Intent] {
        entries.filter { $0.phase == .pending && $0.kind.targetPid == pid }
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
        for index in entries.indices {
            if case let .focusWindow(token, workspaceId) = entries[index].kind, token == oldToken {
                entries[index].kind = .focusWindow(token: newToken, workspaceId: workspaceId)
            } else if case var .appRevealFocus(payload) = entries[index].kind,
                      payload.token == oldToken
            {
                if oldToken.pid == newToken.pid {
                    payload.token = newToken
                    payload.focusFingerprint.rekey(from: oldToken, to: newToken)
                    entries[index].kind = .appRevealFocus(payload)
                } else if entries[index].phase == .pending {
                    entries[index].phase = .cancelled
                    entries[index].retiredAt = clock()
                    deadlineWheel?.cancel(intentId: entries[index].id)
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
        entries.append(intent)
        trim()
        return intent
    }

    private func retire(id: IntentID, phase: IntentPhase, source: ActivationEventSource?) -> Intent? {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.phase == .pending }) else { return nil }
        entries[index].phase = phase
        entries[index].retiredAt = clock()
        if let source {
            entries[index].lastActivationSource = source
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
