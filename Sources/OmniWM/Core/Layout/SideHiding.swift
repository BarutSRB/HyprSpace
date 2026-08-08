// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum HideSide {
    case left
    case right
}

enum AxisHideEdge {
    case minimum
    case maximum

    init(encodedHideSide: HideSide) {
        switch encodedHideSide {
        case .left:
            self = .minimum
        case .right:
            self = .maximum
        }
    }

    var encodedHideSide: HideSide {
        switch self {
        case .minimum:
            .left
        case .maximum:
            .right
        }
    }

    var opposite: AxisHideEdge {
        switch self {
        case .minimum:
            .maximum
        case .maximum:
            .minimum
        }
    }
}

struct HiddenPlacementMonitorContext {
    let id: Monitor.ID
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: Monitor.ID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(_ monitor: Monitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }

    init(_ monitor: NiriMonitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }
}

struct HiddenWindowPlacement {
    let requestedEdge: AxisHideEdge
    let resolvedEdge: AxisHideEdge
    let origin: CGPoint

    func frame(for size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size)
    }
}

enum HiddenWindowPlacementResolver {
    static func effectiveReveal(baseReveal: CGFloat, scale: CGFloat) -> CGFloat {
        guard baseReveal > 0 else { return 0 }
        return max(baseReveal / max(1.0, scale), 1.0)
    }

    static func physicalScreenEdgeOrigin(
        for size: CGSize,
        requestedSide: HideSide,
        targetY: CGFloat,
        baseReveal: CGFloat,
        scale: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGPoint {
        let reveal = effectiveReveal(baseReveal: baseReveal, scale: scale)

        func origin(for side: HideSide) -> CGPoint {
            switch side {
            case .left:
                CGPoint(
                    x: monitor.visibleFrame.minX - size.width + reveal,
                    y: targetY
                )
            case .right:
                CGPoint(
                    x: monitor.visibleFrame.maxX - reveal,
                    y: targetY
                )
            }
        }

        let primaryOrigin = origin(for: requestedSide)
        let primaryOverlap = overlapArea(
            for: CGRect(origin: primaryOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        if primaryOverlap == 0 {
            return primaryOrigin
        }

        let alternateSide: HideSide = requestedSide == .left ? .right : .left
        let alternateOrigin = origin(for: alternateSide)
        let alternateOverlap = overlapArea(
            for: CGRect(origin: alternateOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        return alternateOverlap < primaryOverlap ? alternateOrigin : primaryOrigin
    }

    static func placement(
        for size: CGSize,
        requestedEdge: AxisHideEdge,
        orthogonalOrigin: CGFloat,
        baseReveal: CGFloat,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> HiddenWindowPlacement {
        let reveal = effectiveReveal(baseReveal: baseReveal, scale: scale)

        func origin(for edge: AxisHideEdge) -> CGPoint {
            switch orientation {
            case .horizontal:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: monitor.visibleFrame.minX - size.width + reveal,
                        y: orthogonalOrigin
                    )
                case .maximum:
                    return CGPoint(
                        x: monitor.visibleFrame.maxX - reveal,
                        y: orthogonalOrigin
                    )
                }
            case .vertical:
                switch edge {
                case .minimum:
                    return CGPoint(
                        x: orthogonalOrigin,
                        y: monitor.visibleFrame.minY - size.height + reveal
                    )
                case .maximum:
                    return CGPoint(
                        x: orthogonalOrigin,
                        y: monitor.visibleFrame.maxY - reveal
                    )
                }
            }
        }

        let primaryOrigin = origin(for: requestedEdge)
        let primaryOverlap = overlapArea(
            for: CGRect(origin: primaryOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        if primaryOverlap == 0 {
            return HiddenWindowPlacement(
                requestedEdge: requestedEdge,
                resolvedEdge: requestedEdge,
                origin: primaryOrigin
            )
        }

        let alternateEdge = requestedEdge.opposite
        let alternateOrigin = origin(for: alternateEdge)
        let alternateOverlap = overlapArea(
            for: CGRect(origin: alternateOrigin, size: size),
            monitor: monitor,
            monitors: monitors
        )
        if alternateOverlap < primaryOverlap {
            return HiddenWindowPlacement(
                requestedEdge: requestedEdge,
                resolvedEdge: alternateEdge,
                origin: alternateOrigin
            )
        }

        return HiddenWindowPlacement(
            requestedEdge: requestedEdge,
            resolvedEdge: requestedEdge,
            origin: primaryOrigin
        )
    }

    private static func overlapArea(
        for rect: CGRect,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGFloat {
        var area: CGFloat = 0
        for other in monitors where other.id != monitor.id {
            let intersection = rect.intersection(other.frame)
            if intersection.isNull { continue }
            area += intersection.width * intersection.height
        }
        return area
    }
}
