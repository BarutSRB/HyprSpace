// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class WindowFrameReconciler {
    private weak var controller: WMController?
    private var highFrequencyTimer: Timer?
    private var highFrequencyUntil: Date?

    init(controller: WMController) {
        self.controller = controller
    }

    isolated deinit {
        highFrequencyTimer?.invalidate()
        highFrequencyTimer = nil
        highFrequencyUntil = nil
    }

    func triggerHighFrequencyBurst(durationSeconds: TimeInterval = 5.0) {
        let deadline = Date().addingTimeInterval(durationSeconds)
        if let current = highFrequencyUntil, current > deadline {
            return
        }
        highFrequencyUntil = deadline
        startHighFrequencyTimerIfNeeded()
    }

    private func startHighFrequencyTimerIfNeeded() {
        guard highFrequencyTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateHighFrequencyTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highFrequencyTimer = timer
    }

    private func stopHighFrequencyTimer() {
        highFrequencyTimer?.invalidate()
        highFrequencyTimer = nil
        highFrequencyUntil = nil
    }

    private func evaluateHighFrequencyTick() {
        guard let highFrequencyUntil else {
            stopHighFrequencyTimer()
            return
        }

        if Date() >= highFrequencyUntil {
            stopHighFrequencyTimer()
            return
        }

        reconcileManagedFrames()
    }

    func reconcileManagedFrames() {
        guard let controller else { return }
        let entries = controller.workspaceManager.allEntries()
        var workspaceIdsToRefresh: Set<WorkspaceDescriptor.ID> = []

        for entry in entries {
            guard entry.mode == .tiling,
                  let frame = AXWindowService.framePreferFast(entry.axRef) ?? (try? AXWindowService.frame(entry.axRef))
            else { continue }

            if isOffscreenOrGlitched(frame: frame) {
                workspaceIdsToRefresh.insert(entry.workspaceId)
            }
        }

        for wsId in workspaceIdsToRefresh {
            controller.layoutRefreshController.requestRelayout(
                reason: .layoutCommand,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func isOffscreenOrGlitched(frame: CGRect) -> Bool {
        if frame.minX < -10000 || frame.minY < -10000 || frame.width <= 0 || frame.height <= 0 {
            return true
        }
        return false
    }
}
