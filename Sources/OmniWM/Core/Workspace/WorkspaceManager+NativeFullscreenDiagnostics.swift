// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension WorkspaceManager {
    func nativeFullscreenLifecycleDiagnosticsSnapshot() -> NativeFullscreenLifecycleDiagnosticsSnapshot {
        let visibleWorkspaces = visibleWorkspaceIds()
        let records = nativeFullscreenRecordsByOriginalToken.values
            .sorted {
                ($0.originalToken.pid, $0.originalToken.windowId)
                    < ($1.originalToken.pid, $1.originalToken.windowId)
            }
            .map { record in
                let entry = entry(for: record.currentToken)
                let monitor = monitor(for: record.workspaceId)
                let displayUUID = monitor?.displayUUID
                return NativeFullscreenLifecycleDiagnosticsSnapshot.Record(
                    originalToken: record.originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    transition: nativeFullscreenTransitionLabel(record.transition),
                    generation: record.transitionGeneration,
                    deadlineArmed: nativeFullscreenTransitionTimeoutTasks[record.originalToken] != nil,
                    entryPresent: entry != nil,
                    layoutReason: entry.map { String(describing: $0.layoutReason) },
                    workspaceVisible: visibleWorkspaces.contains(record.workspaceId),
                    appHidden: isAppHidden(pid: record.currentToken.pid),
                    cornerHidden: isHiddenInCorner(record.currentToken),
                    displayId: monitor?.displayId,
                    displayUUID: displayUUID,
                    displayShowingFullscreen: displayUUID.flatMap {
                        spaceTopology.isDisplayShowingFullscreenSpace($0)
                    }
                )
            }
        return NativeFullscreenLifecycleDiagnosticsSnapshot(
            records: records,
            isNonManagedFocusActive: isNonManagedFocusActive,
            nonManagedFocusToken: nonManagedFocusToken,
            activeFocusOwnerToken: activeNativeFullscreenFocusOwnerToken,
            renderableFocusToken: renderableFocusToken
        )
    }

    private func nativeFullscreenTransitionLabel(_ transition: NativeFullscreenTransition) -> String {
        switch transition {
        case .enterRequested:
            "enterRequested"
        case .suspended:
            "suspended"
        case .exitRequested:
            "exitRequested"
        }
    }
}
