// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension WorkspaceManager {
    private static let nativeFullscreenTransitionTimeout: Duration = .seconds(10)

    var isAppFullscreenActive: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains { $0.transition == .suspended }
    }

    var hasNativeFullscreenLifecycleContext: Bool {
        !nativeFullscreenRecordsByOriginalToken.isEmpty
    }

    var hasPendingNativeFullscreenTransition: Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains { $0.transition.isPending }
    }

    func hasPendingNativeFullscreenTransition(for token: WindowToken) -> Bool {
        nativeFullscreenRecord(for: token)?.transition.isPending == true
    }

    func hasPendingNativeFullscreenTransition(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.workspaceId == workspaceId && $0.transition.isPending
        }
    }

    var activeNativeFullscreenFocusOwnerToken: WindowToken? {
        guard isNonManagedFocusActive,
              let token = nonManagedFocusToken,
              let record = nativeFullscreenRecord(for: token),
              record.currentToken == token,
              record.transition != .enterRequested,
              isNativeFullscreenSuspended(token)
        else {
            return nil
        }
        return token
    }

    @discardableResult
    func selectNativeFullscreenPlaceholder(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        onMonitor monitorId: Monitor.ID? = nil
    ) -> Bool {
        guard showsNativeFullscreenPlaceholder(for: token),
              nativeFullscreenRecord(for: token)?.workspaceId == workspaceId
        else {
            return false
        }
        let normalizedMonitorId = monitorId.flatMap { self.monitor(byId: $0)?.id } ?? self.monitorId(for: workspaceId)
        var changed = rememberFocus(token, in: workspaceId)
        if let normalizedMonitorId {
            changed = updateInteractionMonitor(normalizedMonitorId, preservePrevious: true, notify: false) || changed
        }
        changed = applyFocusReconcileEvent(
            .nativeFullscreenPlaceholderSelected(
                token: token,
                workspaceId: workspaceId,
                source: .workspaceManager
            )
        ) || changed
        if changed {
            notifySessionStateChanged()
        }
        return changed
    }

    var nativeFullscreenTransitionTimeoutCount: Int {
        nativeFullscreenTransitionTimeoutTasks.count
    }

    func cancelNativeFullscreenTransitionTimeouts() {
        for (originalToken, task) in nativeFullscreenTransitionTimeoutTasks {
            task.cancel()
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .deadlineCancelled,
                    originalToken: originalToken
                )
            )
        }
        nativeFullscreenTransitionTimeoutTasks.removeAll()
    }

    func resumeNativeFullscreenTransitionTimeouts() {
        for record in nativeFullscreenRecordsByOriginalToken.values where record.transition.isPending {
            updateNativeFullscreenTransitionTimeout(for: record)
        }
    }

    func updateNativeFullscreenTransitionTimeout(for record: NativeFullscreenRecord) {
        cancelNativeFullscreenTransitionTimeout(originalToken: record.originalToken)
        guard record.transition.isPending else { return }
        let originalToken = record.originalToken
        let generation = record.transitionGeneration
        nativeFullscreenTransitionTimeoutTasks[originalToken] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.nativeFullscreenTransitionTimeout)
            guard let self, !Task.isCancelled else { return }
            guard let record = self.nativeFullscreenRecordsByOriginalToken[originalToken],
                  record.transitionGeneration == generation
            else {
                return
            }
            self.nativeFullscreenTransitionTimeoutTasks.removeValue(forKey: originalToken)
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .deadlineFired,
                    originalToken: originalToken,
                    currentToken: record.currentToken,
                    workspaceId: record.workspaceId,
                    transition: .init(record.transition),
                    generation: generation
                )
            )
            _ = self.expireNativeFullscreenTransition(
                originalToken: originalToken,
                generation: generation
            )
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .deadlineScheduled,
                originalToken: originalToken,
                currentToken: record.currentToken,
                workspaceId: record.workspaceId,
                transition: .init(record.transition),
                generation: generation
            )
        )
    }

    func cancelNativeFullscreenTransitionTimeout(originalToken: WindowToken) {
        guard let task = nativeFullscreenTransitionTimeoutTasks.removeValue(forKey: originalToken) else { return }
        task.cancel()
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .deadlineCancelled,
                originalToken: originalToken
            )
        )
    }
}

private extension WorkspaceNativeFullscreenTransition {
    var isPending: Bool {
        self == .enterRequested || self == .exitRequested
    }
}
