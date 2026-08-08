// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum MouseWarpGeometry {
    static let cornerSafetyInset: CGFloat = 16

    enum Edge: Equatable {
        case left
        case right
        case top
        case bottom
    }

    struct Crossing: Equatable {
        let direction: Direction
        let entryEdge: Edge
        let ratio: CGFloat
    }

    static func crossing(location: CGPoint, frame: CGRect, margin: CGFloat) -> Crossing? {
        if location.x <= frame.minX + margin {
            return Crossing(direction: .left, entryEdge: .right, ratio: yRatio(location, frame))
        }
        if location.x >= frame.maxX - margin {
            return Crossing(direction: .right, entryEdge: .left, ratio: yRatio(location, frame))
        }
        if location.y >= frame.maxY - margin {
            return Crossing(direction: .up, entryEdge: .bottom, ratio: xRatio(location, frame))
        }
        if location.y <= frame.minY + margin {
            return Crossing(direction: .down, entryEdge: .top, ratio: xRatio(location, frame))
        }
        return nil
    }

    static func destinationPoint(on frame: CGRect, entryEdge: Edge, ratio: CGFloat, margin: CGFloat) -> CGPoint {
        let clampedRatio = min(max(ratio, 0), 1)
        let edgeInset = max(1, margin + 1)
        let tangentInset = max(edgeInset, cornerSafetyInset)

        switch entryEdge {
        case .left,
             .right:
            let x = clampedCoordinate(
                entryEdge == .left ? frame.minX + edgeInset : frame.maxX - edgeInset,
                min: frame.minX,
                max: frame.maxX,
                inset: edgeInset
            )
            let y = clampedCoordinate(
                frame.maxY - (clampedRatio * frame.height),
                min: frame.minY,
                max: frame.maxY,
                inset: tangentInset
            )
            return CGPoint(x: x, y: y)
        case .top,
             .bottom:
            let x = clampedCoordinate(
                frame.minX + (clampedRatio * frame.width),
                min: frame.minX,
                max: frame.maxX,
                inset: tangentInset
            )
            let y = clampedCoordinate(
                entryEdge == .top ? frame.maxY - edgeInset : frame.minY + edgeInset,
                min: frame.minY,
                max: frame.maxY,
                inset: edgeInset
            )
            return CGPoint(x: x, y: y)
        }
    }

    static func clampedCoordinate(
        _ value: CGFloat,
        min minValue: CGFloat,
        max maxValue: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        let lower = minValue + inset
        let upper = maxValue - inset
        guard minValue < maxValue, lower <= upper else {
            return (minValue + maxValue) / 2
        }
        return min(max(value, lower), upper)
    }

    private static func yRatio(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        guard frame.height > 0 else { return 0.5 }
        return (frame.maxY - point.y) / frame.height
    }

    private static func xRatio(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        guard frame.width > 0 else { return 0.5 }
        return (point.x - frame.minX) / frame.width
    }
}
