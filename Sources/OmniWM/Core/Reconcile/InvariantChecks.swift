// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum InvariantChecks {
    static func validate(snapshot: ReconcileSnapshot) -> [ReconcileInvariantViolation] {
        var violations: [ReconcileInvariantViolation] = []
        var windowByToken: [WindowToken: ReconcileWindowSnapshot] = [:]
        var duplicateTokens: Set<WindowToken> = []
        for window in snapshot.windows {
            if windowByToken.updateValue(window, forKey: window.token) != nil {
                duplicateTokens.insert(window.token)
            }
        }

        for token in duplicateTokens {
            violations.append(
                .init(
                    code: "duplicate_window_token",
                    message: "Window token \(token) appears more than once in the runtime snapshot."
                )
            )
        }

        if let focusedToken = snapshot.selectedManagedToken,
           windowByToken[focusedToken] == nil
        {
            violations.append(
                .init(
                    code: "selected_managed_token_missing",
                    message: "Selected managed token \(focusedToken) is missing from the runtime snapshot."
                )
            )
        }

        if let focusedToken = snapshot.selectedManagedToken,
           let focusedWindow = windowByToken[focusedToken],
           focusedWindow.lifecyclePhase == .destroyed
        {
            violations.append(
                .init(
                    code: "selected_managed_token_destroyed",
                    message: "Selected managed token \(focusedToken) points to a destroyed window."
                )
            )
        }

        if case let .managed(nativeToken) = snapshot.focusSession.nativeFocusOwner {
            if windowByToken[nativeToken] == nil {
                violations.append(
                    .init(
                        code: "native_focus_token_missing",
                        message: "Native managed focus token \(nativeToken) is missing from the runtime snapshot."
                    )
                )
            }
            if snapshot.focusSession.selectedManagedToken != nativeToken {
                violations.append(
                    .init(
                        code: "native_focus_selection_mismatch",
                        message: "Native managed focus token \(nativeToken) does not match managed selection."
                    )
                )
            }
        }

        if let pendingToken = snapshot.focusSession.pendingManagedFocus.token,
           windowByToken[pendingToken] == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_token_missing",
                    message: "Pending focus token \(pendingToken) is missing from the runtime snapshot."
                )
            )
        }

        if let pendingToken = snapshot.focusSession.pendingManagedFocus.token,
           let pendingWorkspaceId = snapshot.focusSession.pendingManagedFocus.workspaceId,
           let pendingWindow = windowByToken[pendingToken],
           pendingWindow.workspaceId != pendingWorkspaceId
        {
            violations.append(
                .init(
                    code: "pending_focus_workspace_mismatch",
                    message: "Pending focus token \(pendingToken) is in workspace \(pendingWindow.workspaceId.uuidString), not pending workspace \(pendingWorkspaceId.uuidString)."
                )
            )
        }

        if snapshot.focusSession.pendingManagedFocus.requestId != nil,
           snapshot.focusSession.pendingManagedFocus.token == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_request_without_token",
                    message: "Pending managed focus request has a request id but no token."
                )
            )
        }

        if snapshot.focusSession.pendingManagedFocus.requestId != nil,
           snapshot.focusSession.pendingManagedFocus.workspaceId == nil
        {
            violations.append(
                .init(
                    code: "pending_focus_request_without_workspace",
                    message: "Pending managed focus request has a request id but no workspace."
                )
            )
        }

        if snapshot.focusSession.pendingManagedFocus.requestId == nil,
           snapshot.focusSession.pendingManagedFocus != .empty
        {
            violations.append(
                .init(
                    code: "pending_focus_without_request",
                    message: "Pending managed focus exists without a request id."
                )
            )
        }

        for window in snapshot.windows {
            if let observedWorkspaceId = window.observedState.workspaceId,
               observedWorkspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "observed_workspace_mismatch",
                        message: "Observed workspace \(observedWorkspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let desiredWorkspaceId = window.desiredState.workspaceId,
               desiredWorkspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "desired_workspace_mismatch",
                        message: "Desired workspace \(desiredWorkspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let restoreIntent = window.restoreIntent,
               restoreIntent.workspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "restore_workspace_mismatch",
                        message: "Restore intent workspace \(restoreIntent.workspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let observedMonitorId = window.observedState.monitorId,
               !snapshot.topologyProfile.displays.contains(where: { $0.displayId == observedMonitorId.displayId })
            {
                violations.append(
                    .init(
                        code: "observed_monitor_missing",
                        message: "Observed monitor \(observedMonitorId) is missing from the topology for \(window.token)."
                    )
                )
            }

            if let desiredMonitorId = window.desiredState.monitorId,
               !snapshot.topologyProfile.displays.contains(where: { $0.displayId == desiredMonitorId.displayId })
            {
                violations.append(
                    .init(
                        code: "desired_monitor_missing",
                        message: "Desired monitor \(desiredMonitorId) is missing from the topology for \(window.token)."
                    )
                )
            }

            if let desiredDisposition = window.desiredState.disposition,
               desiredDisposition != window.mode,
               window.lifecyclePhase != .replacing,
               window.lifecyclePhase != .destroyed
            {
                violations.append(
                    .init(
                        code: "desired_mode_mismatch",
                        message: "Desired mode \(desiredDisposition) does not match entry mode \(window.mode) for \(window.token)."
                    )
                )
            }

            switch window.lifecyclePhase {
            case .floating where window.mode != .floating:
                violations.append(
                    .init(
                        code: "floating_phase_mode_mismatch",
                        message: "Floating lifecycle phase must carry floating mode for \(window.token)."
                    )
                )
            case .tiled where window.mode != .tiling:
                violations.append(
                    .init(
                        code: "tiled_phase_mode_mismatch",
                        message: "Tiled lifecycle phase must carry tiling mode for \(window.token)."
                    )
                )
            case .destroyed where snapshot.selectedManagedToken == window.token:
                violations.append(
                    .init(
                        code: "destroyed_window_selected",
                        message: "Destroyed window \(window.token) is still selected."
                    )
                )
            default:
                break
            }
        }

        for (workspaceId, layout) in snapshot.layouts {
            for column in layout.columns {
                for tile in column.tiles {
                    guard let window = windowByToken[tile.token] else {
                        violations.append(
                            .init(
                                code: "layout_token_missing",
                                message: "Layout token \(tile.token) in workspace \(workspaceId.uuidString) is missing from the window registry."
                            )
                        )
                        continue
                    }
                    if window.workspaceId != workspaceId {
                        violations.append(
                            .init(
                                code: "layout_token_wrong_workspace",
                                message: "Layout token \(tile.token) is laid out in workspace \(workspaceId.uuidString) but the window registry has it in \(window.workspaceId.uuidString)."
                            )
                        )
                    }
                }
            }

            if let selectedNodeId = snapshot.viewports[workspaceId]?.selectedNodeId,
               layout.hasColumns,
               layout.token(for: selectedNodeId) == nil
            {
                violations.append(
                    .init(
                        code: "selection_unresolved",
                        message: "Selected node \(selectedNodeId) in workspace \(workspaceId.uuidString) does not resolve to any laid-out window."
                    )
                )
            }
        }

        return violations
    }
}
