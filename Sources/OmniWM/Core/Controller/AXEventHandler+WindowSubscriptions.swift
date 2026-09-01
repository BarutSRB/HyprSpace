// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
extension AXEventHandler {
    func retainPreparedWindowSubscription(_ windowId: UInt32) {
        preparedWindowSubscriptionRetainCounts[windowId, default: 0] += 1
        noteWindowSubscriptionIdentityChanged()
    }

    @discardableResult
    func releasePreparedWindowSubscription(_ windowId: UInt32) -> Bool {
        guard let count = preparedWindowSubscriptionRetainCounts[windowId] else { return false }
        if count == 1 {
            preparedWindowSubscriptionRetainCounts.removeValue(forKey: windowId)
        } else {
            preparedWindowSubscriptionRetainCounts[windowId] = count - 1
        }
        noteWindowSubscriptionIdentityChanged()
        return true
    }

    @discardableResult
    func releasePreparedWindowSubscriptions(
        _ windowId: UInt32,
        count: Int
    ) -> Bool {
        guard count > 0 else { return false }
        let retainedCount = preparedWindowSubscriptionRetainCounts[windowId] ?? 0
        assert(retainedCount >= count)
        if retainedCount <= count {
            preparedWindowSubscriptionRetainCounts.removeValue(forKey: windowId)
        } else {
            preparedWindowSubscriptionRetainCounts[windowId] = retainedCount - count
        }
        noteWindowSubscriptionIdentityChanged()
        return true
    }

    func releasePreparedWindowSubscriptions(_ windowIds: [UInt32]) {
        guard !windowIds.isEmpty else { return }
        var changed = false
        for windowId in windowIds {
            guard let count = preparedWindowSubscriptionRetainCounts[windowId] else { continue }
            changed = true
            if count == 1 {
                preparedWindowSubscriptionRetainCounts.removeValue(forKey: windowId)
            } else {
                preparedWindowSubscriptionRetainCounts[windowId] = count - 1
            }
        }
        guard changed else { return }
        noteWindowSubscriptionIdentityChanged()
    }

    func noteManagedWindowSubscriptionIdentityChanged() {
        noteWindowSubscriptionIdentityChanged()
    }

    func beginWindowSubscriptionIdentityTransition() {
        windowSubscriptionIdentityRevision &+= 1
    }

    func desiredWindowSubscriptionIds() -> [UInt32] {
        guard let controller else { return [] }
        let entries = controller.workspaceManager.allEntries()
        var ids = Set(preparedWindowSubscriptionRetainCounts.keys)
        ids.reserveCapacity(ids.count + entries.count)
        for entry in entries {
            if let windowId = UInt32(exactly: entry.windowId) {
                ids.insert(windowId)
            }
        }
        return ids.sorted()
    }

    func refreshWindowSubscriptions() {
        let desiredIds = desiredWindowSubscriptionIds()
        guard !desiredIds.isEmpty else { return }
        guard desiredIds != lastSuccessfulWindowSubscriptionIds
            || lastSuccessfulWindowSubscriptionRevision != windowSubscriptionIdentityRevision
        else {
            return
        }
        guard lastWindowSubscriptionFailureRevision != windowSubscriptionIdentityRevision else { return }

        guard subscribeToWindows(desiredIds) else {
            lastWindowSubscriptionFailureRevision = windowSubscriptionIdentityRevision
            FallbackFiringRecorder.shared.note(.skylight, "windowSubscriptionFailed")
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "cgs.windowSubscription.failed.\(desiredIds.count)"
            )
            return
        }

        lastSuccessfulWindowSubscriptionIds = desiredIds
        lastSuccessfulWindowSubscriptionRevision = windowSubscriptionIdentityRevision
        lastWindowSubscriptionFailureRevision = nil
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "cgs.windowSubscription.succeeded.\(desiredIds.count)"
        )
    }

    private func noteWindowSubscriptionIdentityChanged() {
        windowSubscriptionIdentityRevision &+= 1
        refreshWindowSubscriptions()
    }
}
