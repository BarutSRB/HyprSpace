// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    let borderLayer = CAShapeLayer()
    private let containerLayer = CALayer()

    init(frame: CGRect) {
        super.init(
            contentRect: frame.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isRestorable = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.integral.size))
        view.wantsLayer = true
        borderLayer.fillRule = .evenOdd
        borderLayer.strokeColor = nil
        borderLayer.actions = [
            "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.addSublayer(borderLayer)
        view.layer = containerLayer
        contentView = view
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func applyFrame(_ targetFrame: CGRect) {
        let panelFrame = targetFrame.integral
        let layerFrame = targetFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        guard frame != panelFrame || borderLayer.frame != layerFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        CATransaction.commit()
    }

    func updateBorder(
        surfaceFrame: CGRect,
        targetFrame: CGRect,
        cornerRadii: WindowCornerRadii,
        width: CGFloat,
        color: CGColor,
        scale: CGFloat
    ) {
        let path = CGMutablePath()
        path.addPath(BorderWindow.roundedRectPath(in: surfaceFrame, radii: cornerRadii.adding(width)))
        path.addPath(BorderWindow.roundedRectPath(in: targetFrame, radii: cornerRadii))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.bounds = surfaceFrame
        containerLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        borderLayer.path = path
        borderLayer.fillColor = color
        CATransaction.commit()
    }
}
