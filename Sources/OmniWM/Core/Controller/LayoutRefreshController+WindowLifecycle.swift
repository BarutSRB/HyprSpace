// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

@MainActor
extension LayoutRefreshController {
    struct FullRescanFloatingFocusCandidate: Equatable {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let createdAt: Date

        init?(
            token: WindowToken,
            workspaceId: WorkspaceDescriptor.ID,
            isNewAdmission: Bool,
            mode: TrackedWindowMode,
            createPlacementContext: WindowCreatePlacementContext?
        ) {
            guard isNewAdmission,
                  mode == .floating,
                  let createPlacementContext
            else {
                return nil
            }
            self.token = token
            self.workspaceId = workspaceId
            createdAt = createPlacementContext.createdAt
        }
    }

    static func newestFullRescanFloatingFocusCandidate(
        _ current: FullRescanFloatingFocusCandidate?,
        considering candidate: FullRescanFloatingFocusCandidate
    ) -> FullRescanFloatingFocusCandidate {
        guard let current else { return candidate }
        return candidate.createdAt > current.createdAt ? candidate : current
    }

    func focusFullRescanFloatingCandidate(
        _ candidate: FullRescanFloatingFocusCandidate?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?
    ) -> WorkspaceDescriptor.ID? {
        guard let candidate,
              controller?.windowActionHandler.focusCreatedFloatingWindow(candidate.token) == true
        else {
            return fallbackWorkspaceId
        }
        return candidate.workspaceId
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

    func confirmedMissingEntriesDuringFullRescan(
        seenKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>?,
        permitsMissingRetirement: Bool
    ) -> [WindowState] {
        if permitsMissingRetirement {
            return confirmedMissingEntries(
                keys: seenKeys,
                eligibleKeys: eligibleKeys,
                requiredConsecutiveMisses: 2
            )
        }
        _ = confirmedMissingEntries(
            keys: seenKeys,
            eligibleKeys: [],
            requiredConsecutiveMisses: 2
        )
        return []
    }

    func confirmedMissingEntries(
        keys activeKeys: Set<WindowToken>,
        eligibleKeys: Set<WindowToken>? = nil,
        requiredConsecutiveMisses: Int = 1
    ) -> [WindowState] {
        guard let workspaceManager = controller?.workspaceManager else { return [] }
        let threshold = max(1, requiredConsecutiveMisses)
        let knownEntries = if let eligibleKeys {
            eligibleKeys.compactMap { workspaceManager.entry(for: $0) }
        } else {
            workspaceManager.allEntries()
        }

        for token in activeKeys {
            guard let handle = workspaceManager.handle(for: token) else { continue }
            layoutState.consecutiveMissCountByHandle.removeValue(forKey: handle)
        }

        var confirmedMissing: [WindowState] = []
        confirmedMissing.reserveCapacity(knownEntries.count)
        for entry in knownEntries where !activeKeys.contains(entry.token) {
            guard let handle = workspaceManager.handle(for: entry.token) else { continue }
            if entry.layoutReason == .nativeFullscreen
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

    func preserveFocusedSheetDuringFullRescan(
        windowServerInfoByWindowId: [Int: WindowServerInfo],
        seenKeys: inout Set<WindowToken>
    ) {
        guard let controller,
              let token = controller.workspaceManager.systemModalFocusToken,
              controller.workspaceManager.focusedToken == token,
              !seenKeys.contains(token),
              let entry = controller.workspaceManager.entry(for: token),
              let metadata = entry.managedReplacementMetadata,
              metadata.role == (kAXSheetRole as String),
              let parentWindowId = metadata.parentWindowId,
              parentWindowId != 0,
              let windowId = UInt32(exactly: token.windowId),
              let windowInfo = windowServerInfoByWindowId[token.windowId]
              ?? controller.axEventHandler.resolveWindowInfo(windowId),
              windowInfo.id == windowId,
              windowInfo.pid == token.pid,
              windowInfo.parentId == parentWindowId
        else {
            return
        }
        seenKeys.insert(token)
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

    func consumeNativeFullscreenRestoredFrameApply(for token: WindowToken) -> Bool {
        nativeFullscreenRestoredFrameApplyTokens.remove(token) != nil
    }
}
