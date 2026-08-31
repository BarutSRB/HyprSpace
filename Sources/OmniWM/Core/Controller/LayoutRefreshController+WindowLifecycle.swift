// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

@MainActor
extension LayoutRefreshController {
    func restoreNativeFullscreenAfterStructuralReplacement(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        appFullscreen: Bool
    ) {
        guard !appFullscreen,
              let workspaceManager = controller?.workspaceManager
        else {
            return
        }
        let trackedToken = workspaceManager.entry(for: newToken) == nil
            ? oldToken
            : newToken
        guard workspaceManager.nativeFullscreenRecord(for: trackedToken) != nil
            || workspaceManager.layoutReason(for: trackedToken) == .nativeFullscreen
        else {
            return
        }
        _ = workspaceManager.restoreNativeFullscreenRecord(for: trackedToken)
        markNativeFullscreenRestoredForFrameApply(trackedToken)
        _ = controller?.reconcileScratchpadMemberAfterNativeFullscreenExit(trackedToken)
    }

    func exactNativeFullscreenRetirementKeys(
        scope: RescanScope,
        trackedEntries: [WindowState]
    ) -> Set<WindowToken> {
        guard case let .targeted(_, _, nativeSpaceWindowIdsByPID) = scope,
              let workspaceManager = controller?.workspaceManager
        else { return [] }
        return Set(
            trackedEntries.lazy
                .filter {
                    $0.layoutReason == .nativeFullscreen
                        && nativeSpaceWindowIdsByPID[$0.pid]?.contains($0.windowId) == true
                        && workspaceManager.spaceTopology.spaceForWindow($0.windowId) == nil
                }
                .map(\.token)
        )
    }

    func yieldToDeferredCreate(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode?,
        factsAreDeferred: Bool = false,
        facts: WindowRuleFacts,
        scope: RescanScope,
        capturedWindowServerInfoByWindowId: [Int: WindowServerInfo],
        capturedWindowServerAuthoritativeWindowIds: Set<Int>? = nil,
        capturedWindowServerAuthoritativePIDs: Set<pid_t>? = nil,
        entry: WindowState?,
        seenKeys: inout Set<WindowToken>
    ) -> Bool {
        guard let controller,
              entry == nil,
              let windowId = UInt32(exactly: token.windowId),
              controller.axEventHandler.isCreatedWindowDeferred(windowId)
        else {
            return false
        }
        guard let mode else {
            if !factsAreDeferred {
                controller.axEventHandler.recordDeferredReplacementAssessment(
                    windowId: windowId,
                    scope: scope
                )
            }
            return true
        }
        if let match = controller.axEventHandler.structuralReplacementMatch(
            token: token,
            bundleId: bundleId,
            mode: mode,
            facts: facts,
            capturedWindowServerInfoByWindowId: capturedWindowServerInfoByWindowId,
            capturedWindowServerAuthoritativeWindowIds: capturedWindowServerAuthoritativeWindowIds,
            capturedWindowServerAuthoritativePIDs: capturedWindowServerAuthoritativePIDs
        ) {
            seenKeys.insert(match.token)
            controller.axEventHandler.protectDeferredReplacement(
                windowId: windowId,
                token: match.token,
                scope: scope
            )
        }
        controller.axEventHandler.recordDeferredReplacementAssessment(
            windowId: windowId,
            scope: scope
        )
        return true
    }

    func preserveHiddenWindowsDuringTargetedFullRescan(
        _ entries: [WindowState],
        eligibleKeys: Set<WindowToken>,
        windowServerInfoByWindowId: [Int: WindowServerInfo],
        seenKeys: inout Set<WindowToken>
    ) {
        guard let controller else { return }
        for entry in entries
            where eligibleKeys.contains(entry.token)
            && controller.workspaceManager.hiddenState(for: entry.token) != nil
            && windowServerInfoByWindowId[entry.windowId]?.pid == entry.pid
        {
            seenKeys.insert(entry.token)
        }
    }

    func confirmedMissingEntriesDuringFullRescan(
        seenKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>?,
        nativeFullscreenRetirementKeys: Set<WindowToken> = [],
        permitsMissingRetirement: Bool
    ) -> [WindowState] {
        if permitsMissingRetirement {
            return confirmedMissingEntries(
                keys: seenKeys,
                eligibleKeys: eligibleKeys,
                nativeFullscreenRetirementKeys: nativeFullscreenRetirementKeys,
                requiredConsecutiveMisses: 2
            )
        }
        _ = confirmedMissingEntries(
            keys: seenKeys,
            eligibleKeys: [],
            nativeFullscreenRetirementKeys: [],
            requiredConsecutiveMisses: 2
        )
        return []
    }

    func confirmedMissingEntries(
        keys activeKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>? = nil,
        nativeFullscreenRetirementKeys: Set<WindowToken> = [],
        requiredConsecutiveMisses: Int = 1
    ) -> [WindowState] {
        guard let workspaceManager = controller?.workspaceManager else { return [] }
        let threshold = max(1, requiredConsecutiveMisses)
        let scopedEntries = if let eligibleKeys {
            eligibleKeys.compactMap { workspaceManager.entry(for: $0) }
        } else {
            workspaceManager.allEntries()
        }
        let knownEntries = scopedEntries.filter {
            $0.lifetimeAuthority == .axTopLevelInventory
                || nativeFullscreenRetirementKeys.contains($0.token)
        }

        for token in activeKeys {
            guard let handle = workspaceManager.handle(for: token) else { continue }
            layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
        }

        var confirmedMissing: [WindowState] = []
        confirmedMissing.reserveCapacity(knownEntries.count)
        for entry in knownEntries where !activeKeys.contains(entry.token) {
            guard let handle = workspaceManager.handle(for: entry.token) else { continue }
            if (
                entry.layoutReason == .nativeFullscreen
                    && !nativeFullscreenRetirementKeys.contains(entry.token)
            )
                || workspaceManager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
            {
                layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
                continue
            }
            let misses = (layoutState.consecutiveMissCountByHandle[handle] ?? 0) + 1
            if misses >= threshold {
                confirmedMissing.append(entry)
                layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
            } else {
                layoutState.consecutiveMissCountByHandle[handle] = misses
            }
        }

        let staleHandles = layoutState.consecutiveMissCountByHandle.keys.filter {
            workspaceManager.handle(for: $0.id) !== $0
        }
        for handle in staleHandles {
            layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
        }

        return confirmedMissing.sorted {
            if $0.pid == $1.pid {
                return $0.windowId < $1.windowId
            }
            return $0.pid < $1.pid
        }
    }

    func resetMissingDetectionCounts() {
        layoutState.consecutiveMissCountByHandle.removeAll(keepingCapacity: true)
    }

    func recordWindowPresence(_ handle: WindowHandle) {
        layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
    }

    func makeNiriRemovalSeeds(
        from payloads: [WindowRemovalPayload]
    ) -> [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] {
        var seeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]
        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                continue
            case .niri,
                 .defaultLayout:
                let existing = seeds[payload.workspaceId]
                var removedNodeIds = existing?.removedNodeIds ?? []
                if let removedNodeId = payload.removedNodeId {
                    removedNodeIds.append(removedNodeId)
                }
                let mergedOldFrames = (existing?.oldFrames ?? [:])
                    .merging(payload.niriOldFrames) { current, _ in current }
                seeds[payload.workspaceId] = NiriWindowRemovalSeed(
                    removedNodeIds: removedNodeIds,
                    oldFrames: mergedOldFrames,
                    removedColumn: existing?.removedColumn == true || payload.removedNiriColumn
                )
            }
        }
        return seeds
    }

    static func shouldReadmitTrackedWindow(
        entry: WindowState,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        ruleEffects: ManagedWindowRuleEffects,
        shouldPreservePreFullscreenState: Bool,
        appFullscreen: Bool
    ) -> Bool {
        shouldPreservePreFullscreenState
            || appFullscreen
            || entry.workspaceId != workspaceId
            || entry.mode != mode
            || entry.ruleEffects != ruleEffects
    }

    func observedWindowFrame(_ entry: WindowState) -> CGRect? {
        fastFrame(for: entry.token, axRef: entry.axRef)
    }

    static func hiddenEdgeReveal(isZoomApp: Bool) -> CGFloat {
        isZoomApp ? 0 : hiddenWindowEdgeRevealEpsilon
    }

    func isZoomApp(_ pid: pid_t) -> Bool {
        controller?.appInfoCache.bundleId(for: pid) == "us.zoom.xos"
    }

    func markNativeFullscreenRestoredForFrameApply(_ token: WindowToken) {
        nativeFullscreenRestoredFrameApplyTokens.insert(token)
    }

    func rekeyNativeFullscreenRestoredFrameApply(
        from oldToken: WindowToken,
        to newToken: WindowToken
    ) {
        guard nativeFullscreenRestoredFrameApplyTokens.remove(oldToken) != nil else { return }
        nativeFullscreenRestoredFrameApplyTokens.insert(newToken)
    }

    func consumeNativeFullscreenRestoredFrameApply(for token: WindowToken) -> Bool {
        nativeFullscreenRestoredFrameApplyTokens.remove(token) != nil
    }
}
