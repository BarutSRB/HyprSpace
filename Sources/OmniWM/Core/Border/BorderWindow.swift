// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

@MainActor
final class BorderWindow {
    enum SegmentKind: Int, CaseIterable {
        case top
        case bottom
        case left
        case right
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        static let allCases: [SegmentKind] = [
            .top,
            .bottom,
            .left,
            .right,
            .topLeft,
            .topRight,
            .bottomLeft,
            .bottomRight
        ]

        var isCorner: Bool {
            switch self {
            case .topLeft,
                 .topRight,
                 .bottomLeft,
                 .bottomRight:
                true
            case .top,
                 .bottom,
                 .left,
                 .right:
                false
            }
        }
    }

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
        var withTransactionScope: @MainActor (@MainActor () -> Void) -> Void
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
            withTransactionScope: { body in
                SkyLight.shared.withTransactionScope(body)
            },
            backingScaleForFrame: { targetFrame in
                let targetScreen = NSScreen.screens.first(where: {
                    $0.frame.contains(targetFrame.center)
                }) ?? NSScreen.main ?? NSScreen.screens.first
                return (targetScreen?.backingScaleFactor ?? 2.0, targetScreen?.frame ?? .null)
            }
        )
    }

    private struct SegmentGeometry {
        let frame: CGRect
        let capacity: CGSize
        let borderWidth: CGFloat
        let outerRadii: WindowCornerRadii
        let innerRadii: WindowCornerRadii
    }

    private struct SegmentBoundaries {
        let horizontalCapacity: CGFloat
        let verticalCapacity: CGFloat
        let edgeThicknessCapacity: CGFloat
        let leftEdgeRight: CGFloat
        let rightEdgeLeft: CGFloat
        let bottomEdgeTop: CGFloat
        let topEdgeBottom: CGFloat
        let topLeftRight: CGFloat
        let topLeftBottom: CGFloat
        let topRightLeft: CGFloat
        let topRightBottom: CGFloat
        let bottomLeftRight: CGFloat
        let bottomLeftTop: CGFloat
        let bottomRightLeft: CGFloat
        let bottomRightTop: CGFloat
        let topEdgeWidth: CGFloat
        let bottomEdgeWidth: CGFloat
        let leftEdgeHeight: CGFloat
        let rightEdgeHeight: CGFloat
    }

    private struct RasterKey: Equatable {
        let scale: CGFloat
        let configGeneration: UInt64
        let outerRadius: CGFloat
        let innerRadius: CGFloat
    }

    private enum PlacementOperation {
        case none
        case hide
        case moveOnly
        case moveAndOrder
    }

    private final class Segment {
        let kind: SegmentKind
        var wid: UInt32 = 0
        var context: CGContext?
        var capacity: CGSize = .zero
        var shapeSize: CGSize = .zero
        var localFrame: CGRect = .zero
        var frameOnScreen: CGRect?
        var rasterKey: RasterKey?
        var isVisible = false

        init(kind: SegmentKind) {
            self.kind = kind
        }
    }

    private let minimumCornerCapacity: CGFloat = 64
    private let minimumEdgeThicknessCapacity: CGFloat = 12
    private let segments = SegmentKind.allCases.map(Segment.init)
    private var config: BorderConfig
    private var configGeneration: UInt64 = 1
    private let operations: Operations

    private var appliedFrame: CGRect = .zero
    private var isVisible = false
    private var lastOrderedTargetWid: UInt32 = 0
    private var cachedScale: CGFloat = 0
    private var cachedScaleScreenFrame: CGRect = .null

    private let orderingLevel: Int32 = 3

    init(config: BorderConfig, operations: Operations = .live) {
        self.config = config
        self.operations = operations
    }

    isolated deinit {
        destroy()
    }

    func destroy() {
        for segment in segments {
            release(segment)
        }
        isVisible = false
        lastOrderedTargetWid = 0
    }

    @discardableResult
    func update(
        frame targetFrame: CGRect,
        targetWid: UInt32,
        cornerRadii: WindowCornerRadii = WindowCornerRadii(uniform: 9.0),
        forceOrdering: Bool = false
    ) -> Bool {
        BorderOpMetricsRecorder.shared.noteUpdate()
        let (scale, screenFrame) = backingInfo(for: targetFrame)
        let resolvedCornerRadii = cornerRadii.nonnegative
        let frame = targetFrame.roundedToPhysicalPixels(scale: scale)
        let localFrame = CGRect(origin: .zero, size: frame.size)
        let borderWidth = effectiveBorderWidth(in: localFrame, scale: scale)
        let innerFrame = localFrame.insetBy(dx: borderWidth, dy: borderWidth)
        let outerRadii = resolvedCornerRadii.adding(borderWidth).normalized(to: localFrame.size)
        let innerRadii = resolvedCornerRadii.normalized(to: innerFrame.size)
        let boundaries = segmentBoundaries(
            bounds: localFrame,
            screenFrame: screenFrame,
            borderWidth: borderWidth,
            outerRadii: outerRadii,
            innerRadii: innerRadii,
            scale: scale
        )
        let createdAnyWindow = segments.contains { $0.wid == 0 }
        var reshapeCount = 0

        for segment in segments {
            let geometry = segmentGeometry(
                for: segment.kind,
                bounds: localFrame,
                boundaries: boundaries,
                borderWidth: borderWidth,
                outerRadii: outerRadii,
                innerRadii: innerRadii,
                scale: scale
            )
            guard let segmentReshapeCount = prepare(
                segment,
                geometry: geometry,
                bounds: localFrame,
                scale: scale
            ) else {
                destroy()
                return false
            }
            reshapeCount += segmentReshapeCount
        }
        BorderOpMetricsRecorder.shared.noteReshape(count: reshapeCount)

        appliedFrame = frame

        let needsOrdering = forceOrdering || createdAnyWindow || !isVisible || lastOrderedTargetWid != targetWid
        var moveOnlyCount = 0
        var moveAndOrderCount = 0
        var hideCount = 0
        operations.withTransactionScope {
            for segment in segments {
                switch place(segment, in: frame, relativeTo: targetWid, needsOrdering: needsOrdering) {
                case .none:
                    break
                case .hide:
                    hideCount += 1
                case .moveOnly:
                    moveOnlyCount += 1
                case .moveAndOrder:
                    moveAndOrderCount += 1
                }
            }
        }
        BorderOpMetricsRecorder.shared.noteMoveOnly(count: moveOnlyCount)
        BorderOpMetricsRecorder.shared.noteMoveAndOrder(count: moveAndOrderCount)
        BorderOpMetricsRecorder.shared.noteHide(count: hideCount)
        isVisible = true
        lastOrderedTargetWid = targetWid
        return true
    }

    func invalidateScaleCache() {
        cachedScale = 0
        cachedScaleScreenFrame = .null
    }

    private func backingInfo(for targetFrame: CGRect) -> (CGFloat, CGRect) {
        if cachedScale > 0, cachedScaleScreenFrame.contains(targetFrame.center) {
            return (cachedScale, cachedScaleScreenFrame)
        }
        let (scale, screenFrame) = operations.backingScaleForFrame(targetFrame)
        cachedScale = scale
        cachedScaleScreenFrame = screenFrame
        return (scale, screenFrame)
    }

    private func segmentGeometry(
        for kind: SegmentKind,
        bounds: CGRect,
        boundaries: SegmentBoundaries,
        borderWidth: CGFloat,
        outerRadii: WindowCornerRadii,
        innerRadii: WindowCornerRadii,
        scale: CGFloat
    ) -> SegmentGeometry {
        let horizontalCapacity = boundaries.horizontalCapacity
        let verticalCapacity = boundaries.verticalCapacity
        let edgeThicknessCapacity = boundaries.edgeThicknessCapacity
        let leftEdgeRight = boundaries.leftEdgeRight
        let rightEdgeLeft = boundaries.rightEdgeLeft
        let bottomEdgeTop = boundaries.bottomEdgeTop
        let topEdgeBottom = boundaries.topEdgeBottom
        let topLeftRight = boundaries.topLeftRight
        let topLeftBottom = boundaries.topLeftBottom
        let topRightLeft = boundaries.topRightLeft
        let topRightBottom = boundaries.topRightBottom
        let bottomLeftRight = boundaries.bottomLeftRight
        let bottomLeftTop = boundaries.bottomLeftTop
        let bottomRightLeft = boundaries.bottomRightLeft
        let bottomRightTop = boundaries.bottomRightTop

        let frame: CGRect
        let capacity: CGSize
        switch kind {
        case .top:
            frame = CGRect(
                x: topLeftRight,
                y: topEdgeBottom,
                width: boundaries.topEdgeWidth,
                height: max(0, bounds.height - topEdgeBottom)
            )
            capacity = CGSize(width: horizontalCapacity, height: edgeThicknessCapacity)
        case .bottom:
            frame = CGRect(
                x: bottomLeftRight,
                y: 0,
                width: boundaries.bottomEdgeWidth,
                height: bottomEdgeTop
            )
            capacity = CGSize(width: horizontalCapacity, height: edgeThicknessCapacity)
        case .left:
            frame = CGRect(
                x: 0,
                y: bottomLeftTop,
                width: leftEdgeRight,
                height: boundaries.leftEdgeHeight
            )
            capacity = CGSize(width: edgeThicknessCapacity, height: verticalCapacity)
        case .right:
            frame = CGRect(
                x: rightEdgeLeft,
                y: bottomRightTop,
                width: max(0, bounds.width - rightEdgeLeft),
                height: boundaries.rightEdgeHeight
            )
            capacity = CGSize(width: edgeThicknessCapacity, height: verticalCapacity)
        case .topLeft:
            frame = CGRect(
                x: 0,
                y: topLeftBottom,
                width: topLeftRight,
                height: max(0, bounds.height - topLeftBottom)
            )
            capacity = cornerCapacity(
                for: max(topLeftRight, bounds.height - topLeftBottom),
                scale: scale
            )
        case .topRight:
            frame = CGRect(
                x: topRightLeft,
                y: topRightBottom,
                width: max(0, bounds.width - topRightLeft),
                height: max(0, bounds.height - topRightBottom)
            )
            capacity = cornerCapacity(
                for: max(bounds.width - topRightLeft, bounds.height - topRightBottom),
                scale: scale
            )
        case .bottomLeft:
            frame = CGRect(
                x: 0,
                y: 0,
                width: bottomLeftRight,
                height: bottomLeftTop
            )
            capacity = cornerCapacity(for: max(bottomLeftRight, bottomLeftTop), scale: scale)
        case .bottomRight:
            frame = CGRect(
                x: bottomRightLeft,
                y: 0,
                width: max(0, bounds.width - bottomRightLeft),
                height: bottomRightTop
            )
            capacity = cornerCapacity(for: max(bounds.width - bottomRightLeft, bottomRightTop), scale: scale)
        }
        return SegmentGeometry(
            frame: frame,
            capacity: capacity.roundedUpToPhysicalPixels(scale: scale),
            borderWidth: borderWidth,
            outerRadii: outerRadii,
            innerRadii: innerRadii
        )
    }

    private func segmentBoundaries(
        bounds: CGRect,
        screenFrame: CGRect,
        borderWidth: CGFloat,
        outerRadii: WindowCornerRadii,
        innerRadii: WindowCornerRadii,
        scale: CGFloat
    ) -> SegmentBoundaries {
        let width = borderWidth
        let topLeftExtent = cornerExtent(outer: outerRadii.topLeft, inner: innerRadii.topLeft, width: width)
        let topRightExtent = cornerExtent(outer: outerRadii.topRight, inner: innerRadii.topRight, width: width)
        let bottomLeftExtent = cornerExtent(
            outer: outerRadii.bottomLeft,
            inner: innerRadii.bottomLeft,
            width: width
        )
        let bottomRightExtent = cornerExtent(
            outer: outerRadii.bottomRight,
            inner: innerRadii.bottomRight,
            width: width
        )
        let horizontalCapacity = max(bounds.width, validSpan(screenFrame.width), validSpan(screenFrame.height))
        let verticalCapacity = max(bounds.height, validSpan(screenFrame.width), validSpan(screenFrame.height))
        let edgeThicknessCapacity = max(width, minimumEdgeThicknessCapacity)
        let leftEdgeRight = snappedBoundary(width, limit: bounds.width, scale: scale)
        let rightEdgeLeft = snappedBoundary(bounds.width - width, limit: bounds.width, scale: scale)
        let bottomEdgeTop = snappedBoundary(width, limit: bounds.height, scale: scale)
        let topEdgeBottom = snappedBoundary(bounds.height - width, limit: bounds.height, scale: scale)
        let topLeftRight = snappedBoundary(topLeftExtent, limit: bounds.width, scale: scale)
        let topLeftBottom = snappedBoundary(bounds.height - topLeftExtent, limit: bounds.height, scale: scale)
        let rawTopRightLeft = snappedBoundary(
            bounds.width - topRightExtent,
            limit: bounds.width,
            scale: scale
        )
        let rawTopRightBottom = snappedBoundary(
            bounds.height - topRightExtent,
            limit: bounds.height,
            scale: scale
        )
        let bottomLeftRight = snappedBoundary(bottomLeftExtent, limit: bounds.width, scale: scale)
        let bottomLeftTop = snappedBoundary(bottomLeftExtent, limit: bounds.height, scale: scale)
        let rawBottomRightLeft = snappedBoundary(
            bounds.width - bottomRightExtent,
            limit: bounds.width,
            scale: scale
        )
        let bottomRightTop = snappedBoundary(bottomRightExtent, limit: bounds.height, scale: scale)
        let topEdgeWidth = max(0, rawTopRightLeft - topLeftRight)
        let bottomEdgeWidth = max(0, rawBottomRightLeft - bottomLeftRight)
        let leftEdgeHeight = max(0, topLeftBottom - bottomLeftTop)
        let rightEdgeHeight = max(0, rawTopRightBottom - bottomRightTop)
        let topRightLeft = topLeftRight + topEdgeWidth
        let topRightBottom = bottomRightTop + rightEdgeHeight
        let bottomRightLeft = bottomLeftRight + bottomEdgeWidth
        return SegmentBoundaries(
            horizontalCapacity: horizontalCapacity,
            verticalCapacity: verticalCapacity,
            edgeThicknessCapacity: edgeThicknessCapacity,
            leftEdgeRight: leftEdgeRight,
            rightEdgeLeft: rightEdgeLeft,
            bottomEdgeTop: bottomEdgeTop,
            topEdgeBottom: topEdgeBottom,
            topLeftRight: topLeftRight,
            topLeftBottom: topLeftBottom,
            topRightLeft: topRightLeft,
            topRightBottom: topRightBottom,
            bottomLeftRight: bottomLeftRight,
            bottomLeftTop: bottomLeftTop,
            bottomRightLeft: bottomRightLeft,
            bottomRightTop: bottomRightTop,
            topEdgeWidth: topEdgeWidth,
            bottomEdgeWidth: bottomEdgeWidth,
            leftEdgeHeight: leftEdgeHeight,
            rightEdgeHeight: rightEdgeHeight
        )
    }

    private func cornerExtent(outer: CGFloat, inner: CGFloat, width: CGFloat) -> CGFloat {
        max(width, outer, width + inner)
    }

    private func effectiveBorderWidth(in bounds: CGRect, scale: CGFloat) -> CGFloat {
        min(
            max(0, config.width).roundedToPhysicalPixel(scale: max(scale, 1)),
            min(bounds.width, bounds.height)
        )
    }

    private func snappedBoundary(_ value: CGFloat, limit: CGFloat, scale: CGFloat) -> CGFloat {
        min(max(0, value.roundedToPhysicalPixel(scale: scale)), limit)
    }

    private func cornerCapacity(for extent: CGFloat, scale: CGFloat) -> CGSize {
        let side = max(minimumCornerCapacity, extent).roundedUpToPhysicalPixel(scale: scale)
        return CGSize(width: side, height: side)
    }

    private func validSpan(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 0
    }

    private func prepare(
        _ segment: Segment,
        geometry: SegmentGeometry,
        bounds: CGRect,
        scale: CGFloat
    ) -> Int? {
        var reshapeCount = 0
        let needsCreate = segment.wid == 0
            || segment.capacity.width < geometry.capacity.width
            || segment.capacity.height < geometry.capacity.height
        if needsCreate {
            release(segment)
            guard create(segment, capacity: geometry.capacity, scale: scale) else { return nil }
        } else if segment.rasterKey?.scale != scale {
            operations.configureWindow(segment.wid, Float(scale), false)
        }

        let rasterKey = RasterKey(
            scale: scale,
            configGeneration: configGeneration,
            outerRadius: outerRadius(for: segment.kind, radii: geometry.outerRadii),
            innerRadius: innerRadius(for: segment.kind, radii: geometry.innerRadii)
        )
        if segment.rasterKey != rasterKey {
            if exposeCapacity(segment) {
                reshapeCount += 1
            }
            draw(segment, bounds: bounds, geometry: geometry)
            segment.rasterKey = rasterKey
        }

        if setShape(segment, size: geometry.frame.size) {
            reshapeCount += 1
        }
        segment.localFrame = geometry.frame
        return reshapeCount
    }

    private func create(_ segment: Segment, capacity: CGSize, scale: CGFloat) -> Bool {
        let capacityFrame = CGRect(origin: .zero, size: capacity)
        let wid = operations.createBorderWindow(capacityFrame)
        guard wid != 0 else { return false }
        segment.wid = wid
        segment.capacity = capacity
        segment.shapeSize = capacity

        operations.configureWindow(wid, Float(scale), false)
        let tags: UInt64 = (1 << 1) | (1 << 9)
        operations.setWindowTags(wid, tags)
        operations.excludeFromScreencaptureSelection(wid)

        guard let context = operations.createWindowContext(wid) else {
            release(segment)
            return false
        }
        context.interpolationQuality = .none
        segment.context = context
        return true
    }

    private func release(_ segment: Segment) {
        segment.context = nil
        if segment.wid != 0 {
            operations.releaseBorderWindow(segment.wid)
        }
        segment.wid = 0
        segment.capacity = .zero
        segment.shapeSize = .zero
        segment.localFrame = .zero
        segment.frameOnScreen = nil
        segment.rasterKey = nil
        segment.isVisible = false
    }

    private func exposeCapacity(_ segment: Segment) -> Bool {
        setShape(segment, size: segment.capacity)
    }

    private func setShape(_ segment: Segment, size: CGSize) -> Bool {
        guard segment.shapeSize != size else { return false }
        operations.setWindowShape(segment.wid, CGRect(origin: .zero, size: size))
        segment.shapeSize = size
        return true
    }

    private func draw(_ segment: Segment, bounds: CGRect, geometry: SegmentGeometry) {
        guard let context = segment.context else { return }
        let rasterBounds = CGRect(origin: .zero, size: segment.capacity)
        context.saveGState()
        context.clear(rasterBounds)
        context.setFillColor(config.color.cgColor)

        if segment.kind.isCorner {
            let offset = geometry.frame.origin
            let translatedBounds = bounds.offsetBy(dx: -offset.x, dy: -offset.y)
            let translatedInnerBounds = translatedBounds.insetBy(
                dx: geometry.borderWidth,
                dy: geometry.borderWidth
            )
            let ring = CGMutablePath()
            ring.addPath(Self.roundedRectPath(in: translatedBounds, radii: geometry.outerRadii))
            ring.addPath(Self.roundedRectPath(in: translatedInnerBounds, radii: geometry.innerRadii))
            context.addPath(ring)
            context.drawPath(using: .eoFill)
        } else {
            context.fill(rasterBounds)
        }

        context.restoreGState()
        context.flush()
        operations.flushWindow(segment.wid)
        BorderOpMetricsRecorder.shared.noteRedraw(rasterizedArea: rasterBounds.width * rasterBounds.height)
        BorderOpMetricsRecorder.shared.noteFlush()
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

    private func outerRadius(for kind: SegmentKind, radii: WindowCornerRadii) -> CGFloat {
        switch kind {
        case .topLeft: radii.topLeft
        case .topRight: radii.topRight
        case .bottomLeft: radii.bottomLeft
        case .bottomRight: radii.bottomRight
        case .top,
             .bottom,
             .left,
             .right: 0
        }
    }

    private func innerRadius(for kind: SegmentKind, radii: WindowCornerRadii) -> CGFloat {
        switch kind {
        case .topLeft: radii.topLeft
        case .topRight: radii.topRight
        case .bottomLeft: radii.bottomLeft
        case .bottomRight: radii.bottomRight
        case .top,
             .bottom,
             .left,
             .right: 0
        }
    }

    private func place(
        _ segment: Segment,
        in targetFrame: CGRect,
        relativeTo targetWid: UInt32,
        needsOrdering: Bool
    ) -> PlacementOperation {
        let localFrame = segment.localFrame
        guard localFrame.width > 0,
              localFrame.height > 0
        else {
            if segment.isVisible {
                operations.transactionHide(segment.wid)
                segment.isVisible = false
                return .hide
            }
            segment.isVisible = false
            return .none
        }

        let appKitFrame = absoluteFrame(for: segment.kind, in: targetFrame)
        segment.frameOnScreen = appKitFrame
        let origin = ScreenCoordinateSpace.toWindowServer(rect: appKitFrame).origin
        if needsOrdering || !segment.isVisible {
            operations.transactionMoveAndOrder(segment.wid, origin, orderingLevel, targetWid, .below)
            segment.isVisible = true
            return .moveAndOrder
        } else {
            operations.transactionMove(segment.wid, origin)
            segment.isVisible = true
            return .moveOnly
        }
    }

    private func absoluteFrame(for kind: SegmentKind, in targetFrame: CGRect) -> CGRect {
        let localFrame = segments[kind.rawValue].localFrame
        let x: CGFloat
        let y: CGFloat
        switch kind {
        case .top:
            x = targetFrame.minX + segments[SegmentKind.topLeft.rawValue].localFrame.width
            y = targetFrame.minY + localFrame.minY
        case .bottom:
            x = targetFrame.minX + segments[SegmentKind.bottomLeft.rawValue].localFrame.width
            y = targetFrame.minY
        case .left:
            x = targetFrame.minX
            y = targetFrame.minY + segments[SegmentKind.bottomLeft.rawValue].localFrame.height
        case .right:
            x = targetFrame.minX + localFrame.minX
            y = targetFrame.minY + segments[SegmentKind.bottomRight.rawValue].localFrame.height
        case .topLeft:
            let leftFrame = segments[SegmentKind.left.rawValue].localFrame
            x = targetFrame.minX
            y = (targetFrame.minY + leftFrame.minY) + leftFrame.height
        case .topRight:
            let topFrame = segments[SegmentKind.top.rawValue].localFrame
            let rightFrame = segments[SegmentKind.right.rawValue].localFrame
            x = (targetFrame.minX + topFrame.minX) + topFrame.width
            y = (targetFrame.minY + rightFrame.minY) + rightFrame.height
        case .bottomLeft:
            x = targetFrame.minX
            y = targetFrame.minY
        case .bottomRight:
            let bottomFrame = segments[SegmentKind.bottom.rawValue].localFrame
            x = (targetFrame.minX + bottomFrame.minX) + bottomFrame.width
            y = targetFrame.minY
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: localFrame.size)
    }

    func reorder(relativeTo targetWid: UInt32) {
        guard segments.contains(where: { $0.wid != 0 }) else { return }
        var moveAndOrderCount = 0
        operations.withTransactionScope {
            for segment in segments where segment.isVisible {
                guard let frame = segment.frameOnScreen else { continue }
                let origin = ScreenCoordinateSpace.toWindowServer(rect: frame).origin
                operations.transactionMoveAndOrder(segment.wid, origin, orderingLevel, targetWid, .below)
                moveAndOrderCount += 1
            }
        }
        BorderOpMetricsRecorder.shared.noteMoveAndOrder(count: moveAndOrderCount)
        isVisible = true
        lastOrderedTargetWid = targetWid
    }

    func hide() {
        guard segments.contains(where: { $0.wid != 0 }) else { return }
        var hideCount = 0
        operations.withTransactionScope {
            for segment in segments where segment.isVisible {
                operations.transactionHide(segment.wid)
                segment.isVisible = false
                segment.frameOnScreen = nil
                hideCount += 1
            }
        }
        BorderOpMetricsRecorder.shared.noteHide(count: hideCount)
        isVisible = false
        lastOrderedTargetWid = 0
    }

    func updateConfig(_ newConfig: BorderConfig) {
        guard config != newConfig else { return }
        config = newConfig
        configGeneration &+= 1
    }

    var windowId: UInt32? {
        segments.first(where: { $0.wid != 0 })?.wid
    }

    func windowId(for kind: SegmentKind) -> UInt32? {
        let wid = segments[kind.rawValue].wid
        return wid == 0 ? nil : wid
    }

    func frameOnScreen(for kind: SegmentKind) -> CGRect? {
        let segment = segments[kind.rawValue]
        return segment.isVisible ? segment.frameOnScreen : nil
    }

    var frameOnScreen: CGRect? {
        isVisible ? appliedFrame : nil
    }
}

private extension CGSize {
    func roundedUpToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedUpToPhysicalPixel(scale: scale),
            height: height.roundedUpToPhysicalPixel(scale: scale)
        )
    }
}

private extension CGFloat {
    func roundedUpToPhysicalPixel(scale: CGFloat) -> CGFloat {
        let scale = Swift.max(scale, 1)
        return ceil(self * scale) / scale
    }
}
