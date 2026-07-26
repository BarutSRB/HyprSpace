// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
final class MonitorIdentificationOverlayController {
    private struct PresentedPanel {
        let window: NSPanel
        let surfaceId: String
    }

    private var panels: [PresentedPanel] = []
    private var dismissalTask: Task<Void, Never>?

    var visibleCount: Int {
        panels.count
    }

    func show(
        monitors: [Monitor],
        displayLabels: [Monitor.ID: MonitorDisplayLabel],
        duration: Duration = .seconds(4)
    ) {
        hide()

        let screenByDisplayId = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayId.map { ($0, screen) }
            }
        )

        for (index, monitor) in monitors.enumerated() {
            guard let screen = screenByDisplayId[monitor.displayId] else { continue }
            let panel = makePanel(
                screen: screen,
                number: index + 1,
                name: displayLabels[monitor.id]?.accessibilityName ?? monitor.name
            )
            let surfaceId = "monitor-identification-\(monitor.displayId)"
            OwnedWindowRegistry.shared.register(
                panel,
                surfaceId: surfaceId,
                policy: SurfacePolicy(
                    kind: .utility,
                    hitTestPolicy: .passthrough,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: false
                )
            )
            panel.orderFrontRegardless()
            panels.append(PresentedPanel(window: panel, surfaceId: surfaceId))
        }

        guard !panels.isEmpty else { return }
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        for panel in panels {
            OwnedWindowRegistry.shared.unregister(surfaceId: panel.surfaceId)
            panel.window.orderOut(nil)
            panel.window.close()
        }
        panels.removeAll()
    }

    private func makePanel(screen: NSScreen, number: Int, name: String) -> NSPanel {
        let size = NSSize(width: 240, height: 180)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MonitorIdentificationBadge(number: number, name: name))
        return panel
    }
}

private struct MonitorIdentificationBadge: View {
    let number: Int
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            Text(number.formatted())
                .font(.system(size: 72, weight: .bold, design: .rounded))
            Text(name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.28))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display \(number), \(name)")
    }
}
