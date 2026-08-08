// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    struct Operations {
        var createBorderWindow: @MainActor (CGRect) -> UInt32
        var releaseBorderWindow: @MainActor (UInt32) -> Void
        var configureWindow: @MainActor (UInt32, Float, Bool) -> Void
        var setWindowTags: @MainActor (UInt32, UInt64) -> Void
        var excludeFromScreencaptureSelection: @MainActor (UInt32) -> Void
        var createWindowContext: @MainActor (UInt32) -> CGContext?
        var setWindowShape: @MainActor (UInt32, CGRect) -> Void
        var flushWindow: @MainActor (UInt32) -> Void
        var transactionMove: @MainActor (UInt32, CGPoint) -> Void
        var transactionMoveAndOrder: @MainActor (UInt32, CGPoint, Int32, UInt32, SkyLightWindowOrder) -> Void
        var transactionHide: @MainActor (UInt32) -> Void
        var backingScaleForFrame: @MainActor (CGRect) -> (scale: CGFloat, screenFrame: CGRect)

        static let live = Self(
            createBorderWindow: { SkyLight.shared.createBorderWindow(frame: $0) },
            releaseBorderWindow: { SkyLight.shared.releaseBorderWindow($0) },
            configureWindow: { SkyLight.shared.configureWindow($0, resolution: $1, opaque: $2) },
            setWindowTags: { SkyLight.shared.setWindowTags($0, tags: $1) },
            excludeFromScreencaptureSelection: { SkyLight.shared.excludeFromScreencaptureWindowSelection($0) },
            createWindowContext: { SkyLight.shared.createWindowContext(for: $0) },
            setWindowShape: { SkyLight.shared.setWindowShape($0, frame: $1) },
            flushWindow: { SkyLight.shared.flushWindow($0) },
            transactionMove: { SkyLight.shared.transactionMove($0, origin: $1) },
            transactionMoveAndOrder: {
                SkyLight.shared.transactionMoveAndOrder($0, origin: $1, level: $2, relativeTo: $3, order: $4)
            },
            transactionHide: { SkyLight.shared.transactionHide($0) },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return (targetScreen?.backingScaleFactor ?? 2.0, targetScreen?.frame ?? .null)
            }
        )
    }

    private var wid: UInt32 = 0
    private var context: CGContext?
    private var config: BorderConfig
    private let operations: Operations

    private var currentFrame: CGRect = .zero
    private var appliedFrame: CGRect = .zero
    private var origin: CGPoint = .zero
    private var needsRedraw = true
    private var isVisible = false
    private var lastOrderedTargetWid: UInt32 = 0
    private var lastConfiguredScale: CGFloat = 0
    private var currentCornerRadii = WindowCornerRadii(uniform: 9.0)
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null

    private let defaultCornerRadii = WindowCornerRadii(uniform: 9.0)
    private let orderingLevel: Int32 = 3

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    func destroy() {
        context = nil
        if wid != 0 {
            operations.releaseBorderWindow(wid)
            wid = 0
        }
        isVisible = false
        lastOrderedTargetWid = 0
        currentCornerRadii = defaultCornerRadii
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetWid: UInt32,
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 9.0),
        forceOrdering: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        let scale = backingScale(for: targetFrame)
        let resolvedCornerRadii = cornerRadii.nonnegative

        var frame = targetFrame.roundedToPhysicalPixels(scale: scale)
        appliedFrame = frame
        origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
        frame.origin = .zero

        let createdWindow: Bool
        if wid == 0 {
            createWindow(frame: frame, scale: scale)
            guard wid != 0 else { return false }
            createdWindow = true
        } else {
            createdWindow = false
        }

        if scale != lastConfiguredScale, wid != 0 {
            operations.configureWindow(wid, Float(scale), false)
            lastConfiguredScale = scale
            needsRedraw = true
        }

        if frame.size != currentFrame.size {
            reshapeWindow(frame: frame)
            needsRedraw = true
        }
        if currentCornerRadii != resolvedCornerRadii {
            needsRedraw = true
        }
        currentFrame = frame
        currentCornerRadii = resolvedCornerRadii

        if needsRedraw {
            draw(frame: frame)
        }

        let needsOrdering = forceOrdering || createdWindow || !isVisible || lastOrderedTargetWid != targetWid
        move(relativeTo: targetWid, needsOrdering: needsOrdering)
        isVisible = true
        lastOrderedTargetWid = targetWid
        return true
    }

    func invalidateScaleCache() {
        cachedScale = 0
        cachedScaleScreenFrame = .null
    }

    private func backingScale(for targetFrame: CGRect) -> CGFloat {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return cachedScale
        }
        let (scale, screenFrame) = operations.backingScaleForFrame(targetFrame)
        cachedScale = scale
        cachedScaleScreenFrame = screenFrame
        return scale
    }

    private func createWindow(frame: CGRect, scale: CGFloat) {
        wid = operations.createBorderWindow(frame)
        guard wid != 0 else { return }

        operations.configureWindow(wid, Float(scale), false)
        lastConfiguredScale = scale

        let tags: UInt64 = (1 << 1) | (1 << 9)
        operations.setWindowTags(wid, tags)
        operations.excludeFromScreencaptureSelection(wid)

        guard let context = operations.createWindowContext(wid) else {
            operations.releaseBorderWindow(wid)
            wid = 0
            return
        }
        context.interpolationQuality = .none
        self.context = context
    }

    private func reshapeWindow(frame: CGRect) {
        BorderOpMetricsRecorder.shared.noteReshape()
        operations.setWindowShape(wid, frame)
    }

    private func draw(frame: CGRect) {
        guard let context else { return }
        needsRedraw = false
        BorderOpMetricsRecorder.shared.noteRedraw()

        let borderWidth = config.width
        let cornerRadii = currentCornerRadii
        let outerRadii = cornerRadii.adding(borderWidth)

        context.saveGState()
        context.clear(frame)

        let innerRect = frame.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = Self.roundedRectPath(in: innerRect, radii: cornerRadii)

        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        context.addPath(clipPath)
        context.clip(using: .evenOdd)

        context.setFillColor(config.color.cgColor)

        let outerPath = Self.roundedRectPath(in: frame, radii: outerRadii)
        context.addPath(outerPath)
        context.fillPath()

        context.restoreGState()
        context.flush()
        operations.flushWindow(wid)
    }

    static func roundedRectPath(in rect: CGRect, radii: WindowCornerRadii) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull else { return path }
        let radii = radii.normalized(to: rect.size)

        path.move(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radii.bottomRight),
            radius: radii.bottomRight
        )

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.topRight))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - radii.topRight, y: rect.maxY),
            radius: radii.topRight
        )

        path.addLine(to: CGPoint(x: rect.minX + radii.topLeft, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radii.topLeft),
            radius: radii.topLeft
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.bottomLeft))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.minY),
            radius: radii.bottomLeft
        )

        path.closeSubpath()
        return path
    }

    private func move(relativeTo targetWid: UInt32, needsOrdering: Bool) {
        if needsOrdering {
            BorderOpMetricsRecorder.shared.noteMoveAndOrder()
            operations.transactionMoveAndOrder(wid, origin, orderingLevel, targetWid, .below)
            return
        }

        BorderOpMetricsRecorder.shared.noteMoveOnly()
        operations.transactionMove(wid, origin)
    }

    func reorder(relativeTo targetWid: UInt32) {
        guard wid != 0 else { return }
        move(relativeTo: targetWid, needsOrdering: true)
        isVisible = true
        lastOrderedTargetWid = targetWid
    }

    func hide() {
        guard wid != 0 else { return }
        BorderOpMetricsRecorder.shared.noteHide()
        operations.transactionHide(wid)
        isVisible = false
        lastOrderedTargetWid = 0
    }

    func updateConfig(_ newConfig: BorderConfig) {
        guard config != newConfig else { return }
        if config.color != newConfig.color || config.width != newConfig.width {
            needsRedraw = true
        }
        config = newConfig
    }

    var windowId: UInt32? {
        wid == 0 ? nil : wid
    }

    var frameOnScreen: CGRect? {
        wid == 0 || !isVisible ? nil : appliedFrame
    }
}
