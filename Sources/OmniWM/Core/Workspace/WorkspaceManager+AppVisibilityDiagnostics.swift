// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct AppVisibilityWindowDiagnostics {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let workspaceVisible: Bool
    let mode: TrackedWindowMode
    let hiddenReason: HiddenReason?
    let layoutReason: LayoutReason
    let nativeFullscreenTransition: WorkspaceNativeFullscreenTransition?
}

struct AppVisibilityPIDDiagnostics {
    let pid: pid_t
    let worldHidden: Bool
    let generation: UInt64
    let workspaceCount: Int
    let visibleWorkspaceCount: Int
    let windows: [AppVisibilityWindowDiagnostics]
}

enum AppVisibilityProjectionEngineDiagnostics {
    case notInstalled
    case noWorkspaceState(excludedCount: Int, missingCount: Int, unexpectedCount: Int)
    case state(excludedCount: Int, missingCount: Int, unexpectedCount: Int)
}

struct AppVisibilityProjectionDiagnostics {
    let workspaceId: WorkspaceDescriptor.ID
    let expectedExcludedCount: Int
    let niri: AppVisibilityProjectionEngineDiagnostics
    let dwindle: AppVisibilityProjectionEngineDiagnostics
}

@MainActor
extension WorkspaceManager {
    func appVisibilityDiagnosticsSnapshot(
        including additionalPIDs: Set<pid_t> = []
    ) -> [AppVisibilityPIDDiagnostics] {
        let entriesByPID = Dictionary(grouping: allEntries(), by: \.pid)
        let visibleWorkspaceIds = visibleWorkspaceIds()
        let pids = hiddenAppPIDs.union(entriesByPID.keys).union(additionalPIDs)
        return pids.sorted().map { pid in
            let entries = (entriesByPID[pid] ?? []).sorted {
                if $0.workspaceId != $1.workspaceId {
                    return $0.workspaceId.uuidString < $1.workspaceId.uuidString
                }
                return $0.windowId < $1.windowId
            }
            let windows = entries.map { entry in
                AppVisibilityWindowDiagnostics(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    workspaceVisible: visibleWorkspaceIds.contains(entry.workspaceId),
                    mode: entry.mode,
                    hiddenReason: entry.hiddenState?.reason,
                    layoutReason: entry.layoutReason,
                    nativeFullscreenTransition: nativeFullscreenRecord(for: entry.token)?.transition
                )
            }
            let workspaceIds = Set(entries.map(\.workspaceId))
            return AppVisibilityPIDDiagnostics(
                pid: pid,
                worldHidden: isAppHidden(pid: pid),
                generation: appVisibilityGeneration(for: pid),
                workspaceCount: workspaceIds.count,
                visibleWorkspaceCount: workspaceIds.intersection(visibleWorkspaceIds).count,
                windows: windows
            )
        }
    }

    func appVisibilityProjectionDiagnosticsSnapshot() -> [AppVisibilityProjectionDiagnostics] {
        workspaces.compactMap { workspace in
            let expected = Set(
                tiledEntries(in: workspace.id).lazy
                    .filter { self.isAppHidden(pid: $0.pid) }
                    .map(\.token)
            )
            let niri = projectionDiagnostics(
                engine: niriEngine,
                hasWorkspaceState: niriEngine?.root(for: workspace.id) != nil,
                excludedTokens: niriEngine?.projectionExclusions(in: workspace.id),
                expected: expected
            )
            let dwindle = projectionDiagnostics(
                engine: dwindleEngine,
                hasWorkspaceState: dwindleEngine?.root(for: workspace.id) != nil,
                excludedTokens: dwindleEngine?.excludedTokens(in: workspace.id),
                expected: expected
            )
            guard !expected.isEmpty || niri.hasExclusions || dwindle.hasExclusions else { return nil }
            return AppVisibilityProjectionDiagnostics(
                workspaceId: workspace.id,
                expectedExcludedCount: expected.count,
                niri: niri,
                dwindle: dwindle
            )
        }
    }

    private func projectionDiagnostics<Engine>(
        engine: Engine?,
        hasWorkspaceState: Bool,
        excludedTokens: Set<WindowToken>?,
        expected: Set<WindowToken>
    ) -> AppVisibilityProjectionEngineDiagnostics {
        guard engine != nil else { return .notInstalled }
        let excludedTokens = excludedTokens ?? []
        let excludedCount = excludedTokens.count
        let missingCount = expected.subtracting(excludedTokens).count
        let unexpectedCount = excludedTokens.subtracting(expected).count
        guard hasWorkspaceState else {
            return .noWorkspaceState(
                excludedCount: excludedCount,
                missingCount: missingCount,
                unexpectedCount: unexpectedCount
            )
        }
        return .state(
            excludedCount: excludedCount,
            missingCount: missingCount,
            unexpectedCount: unexpectedCount
        )
    }
}

private extension AppVisibilityProjectionEngineDiagnostics {
    var hasExclusions: Bool {
        switch self {
        case .notInstalled:
            false
        case let .noWorkspaceState(excludedCount, _, _),
             let .state(excludedCount, _, _):
            excludedCount > 0
        }
    }
}
