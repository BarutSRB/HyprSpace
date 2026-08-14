// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class LaunchOverlayController {
    private var panels: [LaunchOverlayPanel] = []
    private var completion: (() -> Void)?
    private var didFinish = false

    func play(screens: [NSScreen] = NSScreen.screens, completion: @escaping () -> Void) {
        self.completion = completion
        guard !screens.isEmpty else {
            finish()
            return
        }

        for (index, screen) in screens.enumerated() {
            let panel = LaunchOverlayPanel(screen: screen)
            OwnedWindowRegistry.shared.register(
                panel,
                surfaceId: "launch-overlay-\(index)-\(screen.displayId ?? 0)",
                policy: SurfacePolicy(
                    kind: .launchOverlay,
                    hitTestPolicy: .passthrough,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: false
                )
            )
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let startTime = CACurrentMediaTime()
        for panel in panels {
            panel.startAnimation(at: startTime)
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LaunchOverlayView.totalDuration))
            self?.finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        for panel in panels {
            panel.teardown()
            OwnedWindowRegistry.shared.unregister(panel)
            panel.orderOut(nil)
        }
        panels.removeAll()
        let completion = completion
        self.completion = nil
        completion?()
    }
}
