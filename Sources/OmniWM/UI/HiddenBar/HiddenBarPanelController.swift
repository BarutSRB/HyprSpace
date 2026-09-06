// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct HiddenBarPanelPlacement: Equatable {
    let anchor: CGPoint
    let visibleFrame: CGRect
}

@MainActor
final class HiddenBarPanelController {
    private static let surfaceId = "hidden-bar-panel"
    nonisolated static let rowHeight: CGFloat = 24
    nonisolated static let spacing: CGFloat = 8
    nonisolated static let padding: CGFloat = 8
    nonisolated static let glyphInset: CGFloat = 2
    nonisolated static let minimumTargetSide: CGFloat = 24

    var onActivate: ((MenuBarItemKey) -> Void)?
    var isExemptWindow: ((NSWindow) -> Bool)?

    private let model = HiddenBarPanelModel()
    private var panel: NonactivatingPanel?
    private let dismissalMonitor = PanelDismissalMonitor()
    private var lastPlacement: HiddenBarPanelPlacement?
    private weak var previousKeyWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private(set) var isVisible = false

    func toggle(placement: HiddenBarPanelPlacement, items: [HiddenBarGlyph]) {
        if isVisible {
            dismiss()
        } else {
            show(placement: placement, items: items)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        let keyWindow = previousKeyWindow
        let firstResponder = previousFirstResponder
        isVisible = false
        lastPlacement = nil
        previousKeyWindow = nil
        previousFirstResponder = nil
        dismissalMonitor.stop()
        OwnedWindowRegistry.shared.unregister(surfaceId: Self.surfaceId)
        panel?.orderOut(nil)
        if let keyWindow, keyWindow.isVisible {
            keyWindow.makeKey()
            if let firstResponder {
                keyWindow.makeFirstResponder(firstResponder)
            }
        }
    }

    nonisolated static func panelAnchor(
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        barVisible: Bool
    ) -> CGPoint {
        guard barVisible else {
            return CGPoint(x: monitor.frame.midX, y: monitor.visibleFrame.maxY)
        }
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        return CGPoint(
            x: monitor.frame.midX + CGFloat(resolved.xOffset),
            y: geometry.originY(for: monitor) + CGFloat(resolved.yOffset)
        )
    }

    nonisolated static func glyphDisplayWidth(for size: CGSize, rowHeight: CGFloat) -> CGFloat {
        let contentHeight = rowHeight - glyphInset * 2
        let scale = min(1, contentHeight / max(size.height, 1))
        return max(minimumTargetSide, max(8, (size.width * scale).rounded(.up)) + glyphInset * 2)
    }

    nonisolated static func rowRanges(
        itemWidths: [CGFloat],
        maxContentWidth: CGFloat,
        spacing: CGFloat
    ) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var accumulated: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let candidate = index == start ? width : accumulated + spacing + width
            if index > start, candidate > maxContentWidth {
                ranges.append(start ..< index)
                start = index
                accumulated = width
            } else {
                accumulated = candidate
            }
        }
        if start < itemWidths.count {
            ranges.append(start ..< itemWidths.count)
        }
        return ranges
    }

    nonisolated static func barSize(
        itemWidths: [CGFloat],
        rowHeight: CGFloat,
        maxContentWidth: CGFloat,
        spacing: CGFloat,
        padding: CGFloat
    ) -> CGSize {
        guard !itemWidths.isEmpty else {
            return CGSize(width: 140, height: rowHeight + padding * 2)
        }
        let ranges = rowRanges(itemWidths: itemWidths, maxContentWidth: maxContentWidth, spacing: spacing)
        let maxRowWidth = ranges
            .map { range in
                itemWidths[range].reduce(0, +) + spacing * CGFloat(range.count - 1)
            }
            .max() ?? 0
        let rows = CGFloat(ranges.count)
        return CGSize(
            width: min(maxRowWidth, maxContentWidth) + padding * 2,
            height: rows * rowHeight + (rows - 1) * spacing + padding * 2
        )
    }

    nonisolated static func panelFrame(anchor: CGPoint, size: CGSize, screenVisibleFrame: CGRect) -> CGRect {
        NonactivatingPanel.frame(anchor: anchor, size: size, screenVisibleFrame: screenVisibleFrame)
    }

    private func show(placement: HiddenBarPanelPlacement, items: [HiddenBarGlyph]) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if NSApp.keyWindow !== panel {
            previousKeyWindow = NSApp.keyWindow
            previousFirstResponder = NSApp.keyWindow?.firstResponder
        }
        lastPlacement = placement
        applyContent(items: items, placement: placement, panel: panel)

        OwnedWindowRegistry.shared.register(
            panel,
            surfaceId: Self.surfaceId,
            kind: .hiddenBarPanel,
            hitTestPolicy: .interactive,
            capturePolicy: .excluded,
            suppressesManagedFocusRecovery: true
        )
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        dismissalMonitor.start(
            panels: [panel],
            isExemptWindow: { [weak self] window in
                self?.isExemptWindow?(window) == true
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        Task { @MainActor [weak self] in
            self?.model.focusRequest &+= 1
        }
    }

    func refresh(items: [HiddenBarGlyph]) {
        guard isVisible, let panel, let lastPlacement else { return }
        applyContent(items: items, placement: lastPlacement, panel: panel)
    }

    private func applyContent(items: [HiddenBarGlyph], placement: HiddenBarPanelPlacement, panel: NonactivatingPanel) {
        let maxContentWidth = placement.visibleFrame.width - 16 - Self.padding * 2
        model.maxContentWidth = maxContentWidth
        model.items = items
        let widths = items.map { Self.glyphDisplayWidth(for: $0.size, rowHeight: Self.rowHeight) }
        let size = Self.barSize(
            itemWidths: widths,
            rowHeight: Self.rowHeight,
            maxContentWidth: maxContentWidth,
            spacing: Self.spacing,
            padding: Self.padding
        )
        panel.setFrame(
            Self.panelFrame(anchor: placement.anchor, size: size, screenVisibleFrame: placement.visibleFrame),
            display: true
        )
    }

    private func makePanel() -> NonactivatingPanel {
        let panel = NonactivatingPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 200, height: 60)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = NSHostingView(
            rootView: HiddenBarPanelView(
                model: model,
                onActivate: { [weak self] key in
                    self?.dismiss()
                    self?.onActivate?(key)
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )
        return panel
    }
}
