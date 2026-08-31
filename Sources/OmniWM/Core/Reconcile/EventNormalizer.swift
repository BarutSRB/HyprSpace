// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum EventNormalizer {
    static func normalize(
        event: WMEvent,
        existingEntry: WindowState?,
        monitors _: [Monitor]
    ) -> WMEvent {
        switch event {
        case let .windowAdmitted(
            token,
            workspaceId,
            monitorId,
            mode,
            axRef,
            ruleEffects,
            admissionHints,
            lifetimeAuthority,
            metadata,
            source
        ):
            return .windowAdmitted(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                mode: mode,
                axRef: axRef,
                ruleEffects: ruleEffects,
                admissionHints: admissionHints,
                lifetimeAuthority: lifetimeAuthority,
                managedReplacementMetadata: metadata,
                source: source
            )

        case let .windowRekeyed(from, to, workspaceId, monitorId, reason, newAXRef, metadata, source):
            return .windowRekeyed(
                from: from,
                to: to,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                reason: reason,
                newAXRef: newAXRef,
                managedReplacementMetadata: metadata,
                source: source
            )

        case let .windowRemoved(token, workspaceId, source):
            return .windowRemoved(
                token: token,
                workspaceId: workspaceId ?? existingEntry?.workspaceId,
                source: source
            )

        case let .workspaceAssigned(token, from, to, monitorId, source):
            return .workspaceAssigned(
                token: token,
                from: from ?? existingEntry?.workspaceId,
                to: to,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                source: source
            )

        case let .windowModeChanged(token, workspaceId, monitorId, mode, source):
            return .windowModeChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                mode: mode,
                source: source
            )

        case let .floatingGeometryUpdated(
            token,
            workspaceId,
            referenceMonitorId,
            frame,
            normalizedOrigin,
            restoreToFloating,
            source
        ):
            return .floatingGeometryUpdated(
                token: token,
                workspaceId: workspaceId,
                referenceMonitorId: referenceMonitorId
                    ?? existingEntry?.floatingState?.referenceMonitorId
                    ?? existingEntry?.desiredState.monitorId
                    ?? existingEntry?.observedState.monitorId,
                frame: frame,
                normalizedOrigin: normalizedOrigin,
                restoreToFloating: restoreToFloating,
                source: source
            )

        case let .hiddenStateChanged(token, workspaceId, monitorId, hiddenState, source):
            return .hiddenStateChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                hiddenState: hiddenState,
                source: source
            )

        case let .nativeFullscreenTransition(token, workspaceId, monitorId, change, source):
            return .nativeFullscreenTransition(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                change: change,
                source: source
            )

        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, metadata, source):
            return .managedReplacementMetadataChanged(
                token: token,
                workspaceId: workspaceId,
                monitorId: monitorId ?? existingEntry?.observedState.monitorId ?? existingEntry?.desiredState.monitorId,
                metadata: metadata,
                source: source
            )

        case let .topologyChanged(displays, source):
            return .topologyChanged(
                displays: normalizeDisplays(displays),
                source: source
            )

        case let .focusLeaseChanged(lease, source):
            return .focusLeaseChanged(
                lease: normalizeLease(lease),
                source: source
            )

        case .activeSpaceChanged,
             .appVisibilityInvalidated,
             .floatingStateChanged,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusRemembered,
             .hiddenApplicationsChanged,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .nativeFocusOwnerChanged,
             .manualLayoutOverrideChanged,
             .windowAdmissionHintsChanged,
             .nativeFullscreenPlaceholderSelected,
             .niriPlacementsResolved,
             .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .systemSleep,
             .systemWake,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .workspaceFocusCleared:
            return event
        }
    }

    private static func normalizeReason(_ reason: String?) -> String? {
        guard let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func normalizeDisplays(_ displays: [DisplayFingerprint]) -> [DisplayFingerprint] {
        Array(Set(displays)).sorted { lhs, rhs in
            if lhs.anchorPoint.y != rhs.anchorPoint.y {
                return lhs.anchorPoint.y < rhs.anchorPoint.y
            }
            if lhs.anchorPoint.x != rhs.anchorPoint.x {
                return lhs.anchorPoint.x < rhs.anchorPoint.x
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.displayId < rhs.displayId
        }
    }

    private static func normalizeLease(_ lease: FocusPolicyLease?) -> FocusPolicyLease? {
        guard let lease else { return nil }
        return FocusPolicyLease(
            owner: lease.owner,
            reason: normalizeReason(lease.reason) ?? lease.reason,
            suppressesFocusFollowsMouse: lease.suppressesFocusFollowsMouse,
            expiresAt: lease.expiresAt
        )
    }
}
