// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowFrameReconciler {
    weak var controller: WMController?
    private var reconciliationTask: Task<Void, Never>?
    private var highFrequencyUntil: Date?

    private static let standardIntervalNanos: UInt64 = 1_500_000_000 // 1.5 seconds
    private static let highFrequencyIntervalNanos: UInt64 = 100_000_000 // 100ms (high frequency burst post-move)

    init(controller: WMController? = nil) {
        self.controller = controller
    }

    func start() {
        stop()
        reconciliationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let highFreqActive = self?.isHighFrequencyActive == true
                let sleepNanos = highFreqActive ? Self.highFrequencyIntervalNanos : Self.standardIntervalNanos
                try? await Task.sleep(nanoseconds: sleepNanos)
                guard !Task.isCancelled, let self else { break }
                self.reconcileWindowBoundaries()
            }
        }
    }

    func stop() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
    }

    var isHighFrequencyActive: Bool {
        guard let highFrequencyUntil else { return false }
        return Date() < highFrequencyUntil
    }

    func triggerHighFrequencyBurst(durationSeconds: TimeInterval = 10.0) {
        highFrequencyUntil = Date().addingTimeInterval(durationSeconds)
    }

    func reconcileWindowBoundaries() {
        guard let controller, controller.isEnabled else { return }

        // Must not reconcile during active mouse drag or interactive gesture
        guard (NSEvent.pressedMouseButtons & 1) == 0, !controller.isInteractiveGestureActive else { return }

        let visibleWorkspaceIds = controller.workspaceManager.visibleWorkspaceIds()
        for wsId in visibleWorkspaceIds {
            let entries = controller.workspaceManager.entries(in: wsId).filter { $0.mode == .tiling }
            var observedFrames: [(axRef: AXWindowRef, windowId: CGWindowID, targetFrame: CGRect, observedFrame: CGRect)] = []

            for entry in entries {
                let token = entry.token

                var expectedFrame: CGRect?
                if let dwindleEngine = controller.workspaceManager.dwindleEngine,
                   let leaf = dwindleEngine.findNode(for: token, in: wsId)
                {
                    expectedFrame = leaf.cachedFrame
                } else if let niriEngine = controller.workspaceManager.niriEngine,
                          let node = niriEngine.findNode(for: token, in: wsId)
                {
                    expectedFrame = node.renderedFrame ?? node.frame
                }
                guard let targetFrame = expectedFrame else { continue }

                let observedFrame = AXWindowService.framePreferFast(entry.axRef)
                    ?? (try? AXWindowService.frame(entry.axRef))

                guard let observed = observedFrame else { continue }
                observedFrames.append((entry.axRef, CGWindowID(entry.windowId), targetFrame, observed))

                // Auto-fix off-screen glitched windows (e.g. left at -20000 post-drag)
                let isOffscreenGlitched = observed.minX < -5000 || observed.minY < -5000
                if isOffscreenGlitched || !observed.approximatelyEqual(to: targetFrame, tolerance: 2.0) {
                    _ = AXWindowService.setFrame(
                        entry.axRef,
                        frame: targetFrame,
                        currentFrameHint: observed,
                        verify: false
                    )
                    SkyLight.shared.transactionMove(UInt32(entry.windowId), origin: targetFrame.origin)
                    controller.axManager.confirmFrameWrite(for: entry.windowId, frame: targetFrame)
                    controller.layoutRefreshController.requestImmediateRelayout(
                        reason: .interactiveGesture,
                        affectedWorkspaceIds: [wsId]
                    )
                }
            }

            // Auto-fix overlapping tiled windows (glitched overlay recovery)
            if observedFrames.count > 1 {
                for i in 0..<observedFrames.count {
                    for j in (i + 1)..<observedFrames.count {
                        let a = observedFrames[i]
                        let b = observedFrames[j]
                        let intersection = a.observedFrame.intersection(b.observedFrame)
                        if intersection.width > 20 && intersection.height > 20 {
                            // Significant overlay glitch detected — re-seat both windows to expected target frames
                            _ = AXWindowService.setFrame(a.axRef, frame: a.targetFrame, verify: false)
                            _ = AXWindowService.setFrame(b.axRef, frame: b.targetFrame, verify: false)
                            SkyLight.shared.transactionMove(UInt32(a.windowId), origin: a.targetFrame.origin)
                            SkyLight.shared.transactionMove(UInt32(b.windowId), origin: b.targetFrame.origin)
                            controller.layoutRefreshController.requestImmediateRelayout(
                                reason: .interactiveGesture,
                                affectedWorkspaceIds: [wsId]
                            )
                        }
                    }
                }
            }
        }
    }
}
