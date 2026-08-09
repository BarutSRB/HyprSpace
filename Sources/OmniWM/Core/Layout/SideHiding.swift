// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum HideSide {
    case left
    case right

    var opposite: HideSide {
        switch self {
        case .left:
            .right
        case .right:
            .left
        }
    }
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

    /// Parks a window that belongs to an inactive workspace, or to the scratchpad.
    ///
    /// The window leaves the display diagonally, past one of its bottom corners, so both axes
    /// run off the screen at once. macOS refuses a placement that is entirely off-screen and
    /// snaps the window back, so a `reveal` of the window has to stay on the display: taking it
    /// out through a corner makes that residue a `reveal`-sized square in the corner instead of
    /// a `reveal`-wide line down the full height of the window.
    ///
    /// The corner has to have empty space behind it, otherwise the parked body lands on a
    /// neighbouring display. When both corners are occupied - a display directly below catches
    /// either of them - parking falls back to the side edges, which keep the window's own row
    /// and never reach the display below.
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
        let candidates = [
            bottomCornerOrigin(for: size, side: requestedSide, reveal: reveal, monitor: monitor),
            bottomCornerOrigin(for: size, side: requestedSide.opposite, reveal: reveal, monitor: monitor),
            sideEdgeOrigin(for: size, side: requestedSide, targetY: targetY, reveal: reveal, monitor: monitor),
            sideEdgeOrigin(
                for: size,
                side: requestedSide.opposite,
                targetY: targetY,
                reveal: reveal,
                monitor: monitor
            )
        ]

        return leastOverlappingOrigin(
            among: candidates,
            size: size,
            monitor: monitor,
            monitors: monitors
        )
    }

    /// Origin that pushes the window past a bottom corner of the display itself.
    ///
    /// Both axes are measured against `frame` rather than `visibleFrame`: the placement macOS
    /// constrains is the one against the physical display, and referencing the full frame keeps
    /// the residue at the very edge, underneath a Dock that sits on that edge, rather than
    /// stranding it in the strip the Dock reserves.
    private static func bottomCornerOrigin(
        for size: CGSize,
        side: HideSide,
        reveal: CGFloat,
        monitor: HiddenPlacementMonitorContext
    ) -> CGPoint {
        CGPoint(
            x: horizontalOrigin(for: size, side: side, reveal: reveal, bounds: monitor.frame),
            // AppKit coordinates: y grows up, so minY is the bottom edge of the display.
            y: monitor.frame.minY - size.height + reveal
        )
    }

    /// Origin that pushes the window past a side edge, keeping the row it is already on.
    private static func sideEdgeOrigin(
        for size: CGSize,
        side: HideSide,
        targetY: CGFloat,
        reveal: CGFloat,
        monitor: HiddenPlacementMonitorContext
    ) -> CGPoint {
        CGPoint(
            x: horizontalOrigin(for: size, side: side, reveal: reveal, bounds: monitor.visibleFrame),
            y: targetY
        )
    }

    private static func horizontalOrigin(
        for size: CGSize,
        side: HideSide,
        reveal: CGFloat,
        bounds: CGRect
    ) -> CGFloat {
        switch side {
        case .left:
            bounds.minX - size.width + reveal
        case .right:
            bounds.maxX - reveal
        }
    }

    /// First candidate that spills onto no other display, else the one that spills the least.
    private static func leastOverlappingOrigin(
        among candidates: [CGPoint],
        size: CGSize,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> CGPoint {
        var bestOrigin = candidates[0]
        var bestOverlap = CGFloat.greatestFiniteMagnitude

        for candidate in candidates {
            let overlap = overlapArea(
                for: CGRect(origin: candidate, size: size),
                monitor: monitor,
                monitors: monitors
            )
            if overlap == 0 {
                return candidate
            }
            if overlap < bestOverlap {
                bestOrigin = candidate
                bestOverlap = overlap
            }
        }

        return bestOrigin
    }

    /// Whether `frame` is already parked as deeply as it is going to get.
    ///
    /// macOS clamps how far a window may leave the bottom of a display - it keeps a strip of the
    /// top edge on screen, and how deep that strip is differs per window - so a settled park
    /// usually sits above the origin that was asked for. Comparing against that origin would
    /// never match, and the park would be rewritten on every refresh, so a park counts as done
    /// once only a hairline of the window is left on its own display and none of its body has
    /// landed on another one.
    static func isParked(
        frame: CGRect,
        baseReveal: CGFloat,
        scale: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> Bool {
        let tolerance: CGFloat = 0.01
        let reveal = effectiveReveal(baseReveal: baseReveal, scale: scale) + tolerance
        let onScreen = frame.intersection(monitor.frame)
        let showsHairlineAtMost = onScreen.isNull || onScreen.width <= reveal || onScreen.height <= reveal

        return showsHairlineAtMost && overlapArea(for: frame, monitor: monitor, monitors: monitors) == 0
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
