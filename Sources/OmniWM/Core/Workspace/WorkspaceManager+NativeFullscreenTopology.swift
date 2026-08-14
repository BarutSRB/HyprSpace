// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension WorkspaceManager {
    func commitSpaceTopology(_ topology: SpaceTopology) {
        let topology = topology.normalizingDisplayIdentifiers(using: monitors)
        guard topology != spaceTopology else { return }
        recordReconcileEvent(.spaceTopologyChanged(topology: topology, source: .service))
    }

    func reconcileNativeFullscreenWithTopology() {
        let topology = spaceTopology
        guard topology.isPopulated else { return }
        for entry in allEntries() where entry.mode == .tiling {
            reconcileNativeFullscreenWithTopology(for: entry.token)
        }
    }

    @discardableResult
    func reconcileNativeFullscreenWithTopology(for token: WindowToken) -> Bool {
        let topology = spaceTopology
        guard topology.isPopulated,
              let entry = entry(for: token),
              entry.mode == .tiling,
              entry.windowId > 0,
              let spaceId = topology.spaceForWindow(entry.windowId)
        else {
            return false
        }

        let onFullscreenSpace = topology.isFullscreenSpace(spaceId)
        let isSuspended = entry.layoutReason == .nativeFullscreen
        if onFullscreenSpace, !isSuspended, topology.isCurrentSpace(spaceId) {
            return markNativeFullscreenSuspended(entry.token, ownsNonManagedFocus: false)
        }
        if !onFullscreenSpace, isSuspended {
            return restoreNativeFullscreenRecord(
                for: entry.token,
                clearsNonManagedFocusOwner: false
            )
        }
        return false
    }

    func isWindowOnObservedNativeFullscreenSpace(_ windowId: Int) -> Bool {
        spaceTopology.isWindowOnFullscreenSpace(windowId)
    }
}
