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
    private var currentCornerRadii = WindowCornerRadii(uniform: 12.0)
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null

    private let defaultCornerRadii = WindowCornerRadii(uniform: 12.0)
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
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 12.0),
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

        context.saveGState()
        context.clear(frame)

        // Outer curve matches the window's outer boundary corner radius (cornerRadii)
        let outerPath = Self.roundedRectPath(in: frame, radii: cornerRadii)

        // Concentric inner curve has radius R_inner = max(0, R_outer - borderWidth)
        let innerRadii = WindowCornerRadii(
            topLeft: max(0, cornerRadii.topLeft - borderWidth),
            topRight: max(0, cornerRadii.topRight - borderWidth),
            bottomLeft: max(0, cornerRadii.bottomLeft - borderWidth),
            bottomRight: max(0, cornerRadii.bottomRight - borderWidth)
        )
        let innerRect = frame.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = Self.roundedRectPath(in: innerRect, radii: innerRadii)

        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        context.addPath(clipPath)
        context.clip(using: .evenOdd)

        context.setFillColor(config.color.cgColor)
        context.addPath(outerPath)
        context.fillPath()

        context.restoreGState()
        context.flush()
        operations.flushWindow(wid)
    }

    /// Builds the outer fill path for a border ring.
    /// Rather than naively computing `outerRadius = innerRadius + borderWidth` (which produces
    /// mismatched squircle tangent extensions), this version keeps the same tangent distances
    /// along the straight edges as the inner path and adjusts only the curve shape outward by
    /// `borderWidth`, so both arcs are visually concentric.
    static func outerRoundedRectPath(outerRect: CGRect, innerRect: CGRect, innerRadii: WindowCornerRadii) -> CGPath {
        let path = CGMutablePath()
        guard outerRect.width > 0, outerRect.height > 0 else { return path }

        let radii = innerRadii.normalized(to: innerRect.size)
        let w = outerRect.minX - innerRect.minX  // borderWidth

        // Squircle constants
        let kTangent: CGFloat = 1.52866
        let kControlInner: CGFloat = 0.74182

        // For the outer path corners, the tangent extension from the outer rect corner
        // is the same as the inner path: kTangent * innerRadius. This ensures the
        // straight edges of both paths have the same endpoints along the edge.
        // The control points are then pushed outward to make the curve bow outward by w.
        func outerCurvePoints(r: CGFloat) -> (tangent: CGFloat, ctrl: CGFloat) {
            // tangent: same distance from corner as inner curve
            let t = r * kTangent
            // control point ratio scales with (r+w)/r to bow the curve outward
            let outerR = r + w
            let ctrl = outerR > 0 ? outerR * kControlInner : t
            return (t, ctrl)
        }

        let (brT, brC) = outerCurvePoints(r: radii.bottomRight)
        let (trT, trC) = outerCurvePoints(r: radii.topRight)
        let (tlT, tlC) = outerCurvePoints(r: radii.topLeft)
        let (blT, blC) = outerCurvePoints(r: radii.bottomLeft)

        path.move(to: CGPoint(x: outerRect.minX + blT, y: outerRect.minY))

        path.addLine(to: CGPoint(x: outerRect.maxX - brT, y: outerRect.minY))
        if radii.bottomRight > 0 {
            path.addCurve(
                to: CGPoint(x: outerRect.maxX, y: outerRect.minY + brT),
                control1: CGPoint(x: outerRect.maxX - brC, y: outerRect.minY),
                control2: CGPoint(x: outerRect.maxX, y: outerRect.minY + brC)
            )
        } else {
            path.addLine(to: CGPoint(x: outerRect.maxX, y: outerRect.minY))
        }

        path.addLine(to: CGPoint(x: outerRect.maxX, y: outerRect.maxY - trT))
        if radii.topRight > 0 {
            path.addCurve(
                to: CGPoint(x: outerRect.maxX - trT, y: outerRect.maxY),
                control1: CGPoint(x: outerRect.maxX, y: outerRect.maxY - trC),
                control2: CGPoint(x: outerRect.maxX - trC, y: outerRect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: outerRect.maxX, y: outerRect.maxY))
        }

        path.addLine(to: CGPoint(x: outerRect.minX + tlT, y: outerRect.maxY))
        if radii.topLeft > 0 {
            path.addCurve(
                to: CGPoint(x: outerRect.minX, y: outerRect.maxY - tlT),
                control1: CGPoint(x: outerRect.minX + tlC, y: outerRect.maxY),
                control2: CGPoint(x: outerRect.minX, y: outerRect.maxY - tlC)
            )
        } else {
            path.addLine(to: CGPoint(x: outerRect.minX, y: outerRect.maxY))
        }

        path.addLine(to: CGPoint(x: outerRect.minX, y: outerRect.minY + blT))
        if radii.bottomLeft > 0 {
            path.addCurve(
                to: CGPoint(x: outerRect.minX + blT, y: outerRect.minY),
                control1: CGPoint(x: outerRect.minX, y: outerRect.minY + blC),
                control2: CGPoint(x: outerRect.minX + blC, y: outerRect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: outerRect.minX, y: outerRect.minY))
        }

        path.closeSubpath()
        return path
    }

    static func roundedRectPath(in rect: CGRect, radii: WindowCornerRadii) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull else { return path }
        let radii = radii.normalized(to: rect.size)

        let kTangent: CGFloat = 1.52866
        let kControl: CGFloat = 0.74182

        let br = radii.bottomRight
        let brT = br * kTangent
        let brC = br * kControl

        let tr = radii.topRight
        let trT = tr * kTangent
        let trC = tr * kControl

        let tl = radii.topLeft
        let tlT = tl * kTangent
        let tlC = tl * kControl

        let bl = radii.bottomLeft
        let blT = bl * kTangent
        let blC = bl * kControl

        path.move(to: CGPoint(x: rect.minX + blT, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.maxX - brT, y: rect.minY))
        if br > 0 {
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + brT),
                control1: CGPoint(x: rect.maxX - brC, y: rect.minY),
                control2: CGPoint(x: rect.maxX, y: rect.minY + brC)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - trT))
        if tr > 0 {
            path.addCurve(
                to: CGPoint(x: rect.maxX - trT, y: rect.maxY),
                control1: CGPoint(x: rect.maxX, y: rect.maxY - trC),
                control2: CGPoint(x: rect.maxX - trC, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX + tlT, y: rect.maxY))
        if tl > 0 {
            path.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - tlT),
                control1: CGPoint(x: rect.minX + tlC, y: rect.maxY),
                control2: CGPoint(x: rect.minX, y: rect.maxY - tlC)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + blT))
        if bl > 0 {
            path.addCurve(
                to: CGPoint(x: rect.minX + blT, y: rect.minY),
                control1: CGPoint(x: rect.minX, y: rect.minY + blC),
                control2: CGPoint(x: rect.minX + blC, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }

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
