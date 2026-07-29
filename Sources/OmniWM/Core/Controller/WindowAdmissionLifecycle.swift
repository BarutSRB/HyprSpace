// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

enum WindowAdmissionPendingReason: String, Equatable {
    case windowInfoMissing = "window_info_missing"
    case axWindowMissing = "ax_window_missing"
    case factsDeferred = "facts_deferred"
    case degenerateGeometry = "degenerate_geometry"
}

enum WindowAdmissionRejectionReason: String, Equatable {
    case invalidIdentity = "invalid_identity"
    case ownedWindow = "owned_window"
    case policyIgnored = "policy_ignored"
    case quarantined = "quarantined"
    case retryExhausted = "retry_exhausted"
    case terminalFrameRefusal = "terminal_frame_refusal"
}

enum AdmissionRetryTrigger {
    case create
    case candidate(
        token: WindowToken,
        axRef: AXWindowRef,
        placementOrigin: WorkspacePlacementOrigin = .liveCreate
    )
    case focused(
        token: WindowToken,
        source: ActivationEventSource,
        observationGeneration: UInt64,
        callbackGeneration: UInt64?
    )
    case identityRebind(
        oldWindow: AXManagedWindowIdentity,
        newWindow: AXManagedWindowIdentity,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        admissionHints: ManagedWindowAdmissionHints?,
        sizeConstraints: WindowSizeConstraints?
    )
    case ruleReevaluation(token: WindowToken, axRef: AXWindowRef)

    var allowsTrackedIdentityReplacement: Bool {
        if case .create = self { return true }
        return false
    }

    var placementOrigin: WorkspacePlacementOrigin {
        guard case let .candidate(_, _, placementOrigin) = self else {
            return .liveCreate
        }
        return placementOrigin
    }

    var priority: Int {
        switch self {
        case .create:
            0
        case .ruleReevaluation:
            1
        case .candidate:
            2
        case .focused:
            3
        case .identityRebind:
            4
        }
    }

    var protectionPIDs: Set<pid_t> {
        switch self {
        case .create:
            []
        case let .candidate(token, _, _),
             let .focused(token, _, _, _),
             let .ruleReevaluation(token, _):
            [token.pid]
        case let .identityRebind(oldWindow, newWindow, _, _, _):
            [oldWindow.token.pid, newWindow.token.pid]
        }
    }

    var protectsMissingEntriesDuringAdmission: Bool {
        if case .ruleReevaluation = self { return false }
        return true
    }
}

enum ManagedWindowIdentityRebindResult {
    case committed(WindowState)
    case pending
    case rejected

    var committedEntry: WindowState? {
        guard case let .committed(entry) = self else { return nil }
        return entry
    }

    var isHandled: Bool {
        switch self {
        case .committed,
             .pending:
            true
        case .rejected:
            false
        }
    }
}

struct FocusedAdmissionRetryExecution: Equatable, Sendable {
    let windowId: UInt32
    let generation: UInt64
    let executionOwner: UInt64
}

struct AdmissionRetryState {
    var expectedToken: WindowToken?
    var axRef: AXWindowRef?
    var reason: WindowAdmissionPendingReason
    var attempt: Int
    var generation: UInt64
    var trigger: AdmissionRetryTrigger
    var exhausted: Bool
    var executionPhase: AdmissionRetryExecutionPhase = .waiting
    var identityRebindTargetDestroyed = false
    var task: Task<Void, Never>?
}

enum AdmissionRetryExecutionPhase: Equatable {
    case waiting
    case running(UInt64)
}

struct AdmissionRetrySchedule {
    let expectedToken: WindowToken?
    let axRef: AXWindowRef?
    let reason: WindowAdmissionPendingReason
    let trigger: AdmissionRetryTrigger
}

struct DeferredReplacementProtection {
    var protectedTokens: Set<WindowToken>
    var scope: RescanScope
    var fallbackProtectedTokens: Set<WindowToken> = []
    var permitsPIDFallback = true
}

enum AdmissionIncarnationRelation: Equatable {
    case same
    case bindsIdentity
    case replacement
}

struct TerminalFrameFailureState {
    let axRef: AXWindowRef
    var count: Int
}

struct AdmissionQuarantine {
    let token: WindowToken
    let axRef: AXWindowRef
}

enum FullRescanIdentityResolution {
    case process(WindowState?)
    case preserve(WindowToken)
}

enum ManagedWindowRetirementReason {
    case destroyed(shouldRecoverFocus: Bool, allowsPreferredRecoveryToken: Bool)
    case staleIncarnation
    case terminalFrameRefusal
}

struct ManagedWindowRetirementPolicy {
    let shouldRecoverFocus: Bool
    let allowsPreferredRecoveryToken: Bool
    let traceReason: String
    let removesIdentityAliases: Bool
}

struct WindowIdentityAliasGeneration {
    var pids: Set<pid_t>
    var axRefs: [AXWindowRef]

    init(_ aliases: FullRescanWindowIdentityAliases) {
        pids = aliases.pids
        axRefs = []
        axRefs.reserveCapacity(aliases.axRefs.count)
        for axRef in aliases.axRefs where !contains(axRef) {
            axRefs.append(axRef)
        }
    }

    var isEmpty: Bool {
        pids.isEmpty && axRefs.isEmpty
    }

    func contains(_ axRef: AXWindowRef) -> Bool {
        axRefs.contains { CFEqual($0.element, axRef.element) }
    }

    mutating func remove(pid: pid_t) {
        pids.remove(pid)
        axRefs.removeAll { AXWindowService.processIdentifier($0) == pid }
    }
}

struct WindowIdentityAliasHistory {
    private(set) var current: WindowIdentityAliasGeneration?
    private(set) var previous: WindowIdentityAliasGeneration?

    var pids: Set<pid_t> {
        (current?.pids ?? []).union(previous?.pids ?? [])
    }

    mutating func commit(_ aliases: FullRescanWindowIdentityAliases) {
        previous = current
        current = WindowIdentityAliasGeneration(aliases)
    }

    func contains(pid: pid_t) -> Bool {
        current?.pids.contains(pid) == true || previous?.pids.contains(pid) == true
    }

    func contains(_ axRef: AXWindowRef) -> Bool {
        current?.contains(axRef) == true || previous?.contains(axRef) == true
    }

    func contains(_ lhs: AXWindowRef, and rhs: AXWindowRef) -> Bool {
        current?.contains(lhs) == true && current?.contains(rhs) == true
            || previous?.contains(lhs) == true && previous?.contains(rhs) == true
    }

    mutating func remove(pid: pid_t) {
        current?.remove(pid: pid)
        previous?.remove(pid: pid)
        if current?.isEmpty == true {
            current = nil
        }
        if previous?.isEmpty == true {
            previous = nil
        }
    }

    var isEmpty: Bool {
        current == nil && previous == nil
    }
}
