// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum FocusPolicyLeaseOwner: String, Equatable {
    case foreignTransientUI = "foreign_transient_ui"
    case nativeMenu = "native_menu"
    case statusPanel = "status_panel"
    case windowCloseFocusRecovery = "window_close_focus_recovery"
    case nativeAppSwitch = "native_app_switch"
}

struct FocusPolicyLease: Equatable {
    let owner: FocusPolicyLeaseOwner
    let reason: String
    let suppressesFocusFollowsMouse: Bool
    let expiresAt: Date?
}

enum FocusPolicyRequest: Equatable {
    case focusFollowsMouse
    case managedAppActivation(source: ActivationEventSource)
    case managedFocusRecovery
    case windowFronting
}

struct FocusPolicyDecision: Equatable {
    let allowsFocusChange: Bool
    let reason: String?

    static let allow = FocusPolicyDecision(allowsFocusChange: true, reason: nil)

    static func deny(reason: String) -> FocusPolicyDecision {
        FocusPolicyDecision(allowsFocusChange: false, reason: reason)
    }
}

@MainActor
final class FocusPolicyEngine {
    private static let effectiveLeasePriority: [FocusPolicyLeaseOwner] = [
        .foreignTransientUI,
        .nativeMenu,
        .statusPanel,
        .windowCloseFocusRecovery,
        .nativeAppSwitch
    ]

    private let nowProvider: () -> Date
    private var leasesByOwner: [FocusPolicyLeaseOwner: FocusPolicyLease] = [:]
    private var leaseIntentIds: [FocusPolicyLeaseOwner: IntentID] = [:]
    private var activeLeaseStorage: FocusPolicyLease?
    var activeLease: FocusPolicyLease? {
        activeLeaseStorage
    }

    var onLeaseChanged: ((FocusPolicyLease?) -> Void)?
    weak var intentLedger: IntentLedger?
    weak var deadlineWheel: DeadlineWheel?

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    func beginLease(
        owner: FocusPolicyLeaseOwner,
        reason: String,
        suppressesFocusFollowsMouse: Bool = true,
        duration: TimeInterval? = 0.35,
        notify: Bool = true
    ) {
        let expiresAt = duration.map { nowProvider().addingTimeInterval($0) }
        let lease = FocusPolicyLease(
            owner: owner,
            reason: reason,
            suppressesFocusFollowsMouse: suppressesFocusFollowsMouse,
            expiresAt: expiresAt
        )
        leasesByOwner[owner] = lease
        retireLeaseIntent(owner: owner) { intentLedger?.supersede(id: $0) }
        if let duration, let intentLedger, let deadlineWheel {
            let intent = intentLedger.registerFocusPolicyLease(owner: owner)
            leaseIntentIds[owner] = intent.id
            deadlineWheel.schedule(intentId: intent.id, after: .seconds(duration))
        }
        reconcileActiveLease(notify: notify)
    }

    func endLease(owner: FocusPolicyLeaseOwner, notify: Bool = true) {
        retireLeaseIntent(owner: owner) { intentLedger?.cancel(id: $0) }
        guard leasesByOwner.removeValue(forKey: owner) != nil else { return }
        reconcileActiveLease(notify: notify)
    }

    func handleLeaseDeadlineExpired(owner: FocusPolicyLeaseOwner, intentId: IntentID) {
        guard leaseIntentIds[owner] == intentId else { return }
        leaseIntentIds.removeValue(forKey: owner)
        guard leasesByOwner.removeValue(forKey: owner) != nil else { return }
        reconcileActiveLease(notify: shouldNotifyExpiredLeaseChange(owner: owner))
    }

    func evaluate(_ request: FocusPolicyRequest) -> FocusPolicyDecision {
        switch request {
        case .focusFollowsMouse:
            guard let lease = suppressingFocusFollowsMouseLease() else { return .allow }
            return .deny(reason: lease.reason)
        case let .managedAppActivation(source):
            if let menuLease = leasesByOwner[.nativeMenu], !source.isAuthoritative {
                return .deny(reason: menuLease.reason)
            }
            return .allow
        case .managedFocusRecovery:
            guard let lease = leasesByOwner[.statusPanel] else { return .allow }
            return .deny(reason: lease.reason)
        case .windowFronting:
            guard let lease = leasesByOwner[.foreignTransientUI] else { return .allow }
            return .deny(reason: lease.reason)
        }
    }

    private func retireLeaseIntent(
        owner: FocusPolicyLeaseOwner,
        _ retire: (IntentID) -> Intent?
    ) {
        guard let intentId = leaseIntentIds.removeValue(forKey: owner) else { return }
        _ = retire(intentId)
        deadlineWheel?.cancel(intentId: intentId)
    }

    private func shouldNotifyExpiredLeaseChange(owner: FocusPolicyLeaseOwner) -> Bool {
        owner != .windowCloseFocusRecovery
    }

    private func reconcileActiveLease(notify: Bool) {
        let nextLease = effectiveLease()
        guard nextLease != activeLeaseStorage else { return }
        activeLeaseStorage = nextLease
        if notify {
            onLeaseChanged?(nextLease)
        }
    }

    private func effectiveLease() -> FocusPolicyLease? {
        for owner in Self.effectiveLeasePriority {
            if let lease = leasesByOwner[owner] {
                return lease
            }
        }
        return nil
    }

    private func suppressingFocusFollowsMouseLease() -> FocusPolicyLease? {
        for owner in Self.effectiveLeasePriority {
            if let lease = leasesByOwner[owner], lease.suppressesFocusFollowsMouse {
                return lease
            }
        }
        return nil
    }
}
