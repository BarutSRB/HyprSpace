// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension LayoutRefreshController {
    func beginInventoryStabilityBarrier() {
        let wasActive = layoutState.inventoryStabilityBarrierActive
        layoutState.inventoryStabilityBarrierActive = true
        layoutState.inventoryStabilityHoldFullRescans = true
        if let pendingRefresh = layoutState.pendingRefresh,
           pendingRefresh.kind == .fullRescan
        {
            layoutState.pendingRefresh = nil
            holdInventoryStabilityFullRescan(pendingRefresh, isNewerThanHeld: true)
        }
        layoutState.missingConfirmationTask?.cancel()
        layoutState.missingConfirmationTask = nil
        layoutState.pendingMissingConfirmationScope = nil
        if !wasActive {
            resetMissingDetectionCounts()
        }
        if layoutState.activeRefresh?.kind == .fullRescan {
            layoutState.activeRefreshTask?.cancel()
        }
    }

    func releaseInventoryStabilityHold() {
        guard layoutState.inventoryStabilityBarrierActive else { return }
        layoutState.inventoryStabilityHoldFullRescans = false
        releaseInventoryStabilityHeldFullRescan()
        startNextRefreshIfNeeded()
    }

    func endInventoryStabilityBarrier() {
        layoutState.inventoryStabilityBarrierActive = false
        layoutState.inventoryStabilityHoldFullRescans = false
        releaseInventoryStabilityHeldFullRescan()
        startNextRefreshIfNeeded()
    }

    func cancelInventoryStabilityBarrier() {
        layoutState.inventoryStabilityBarrierActive = false
        layoutState.inventoryStabilityHoldFullRescans = false
        releaseInventoryStabilityHeldFullRescan()
    }

    func scheduleMissingConfirmation(scope: RescanScope) {
        guard !scope.isEmpty else { return }
        if let pendingScope = layoutState.pendingMissingConfirmationScope {
            layoutState.pendingMissingConfirmationScope = pendingScope.merged(with: scope)
        } else {
            layoutState.pendingMissingConfirmationScope = scope
        }
        guard layoutState.missingConfirmationTask == nil else { return }
        layoutState.missingConfirmationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self,
                  let pendingScope = self.layoutState.pendingMissingConfirmationScope
            else { return }
            self.layoutState.missingConfirmationTask = nil
            self.layoutState.pendingMissingConfirmationScope = nil
            self.requestFullRescan(reason: .staleFullRescan, scope: pendingScope)
        }
    }

    func holdInventoryStabilityFullRescan(
        _ refresh: ScheduledRefresh,
        isNewerThanHeld: Bool
    ) {
        precondition(refresh.kind == .fullRescan)
        let pendingRefresh = layoutState.pendingRefresh
        let heldRefresh = layoutState.inventoryStabilityHeldFullRescan
        if isNewerThanHeld {
            layoutState.pendingRefresh = heldRefresh
            mergePendingRefresh(refresh)
        } else {
            layoutState.pendingRefresh = refresh
            if let heldRefresh {
                mergePendingRefresh(heldRefresh)
            }
        }
        layoutState.inventoryStabilityHeldFullRescan = layoutState.pendingRefresh
        layoutState.pendingRefresh = pendingRefresh
    }

    func releaseInventoryStabilityHeldFullRescan() {
        guard let heldRefresh = layoutState.inventoryStabilityHeldFullRescan else { return }
        layoutState.inventoryStabilityHeldFullRescan = nil
        mergePendingRefresh(heldRefresh)
    }
}
