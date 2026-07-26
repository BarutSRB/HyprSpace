// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum MonitorSetupStaircaseGeometry {
    struct Transition: Equatable {
        let sideBySide: [CGRect]
        let staircase: [CGRect]
    }

    static func logicalFrames(displayCount: Int) -> [CGRect] {
        let sizes = displaySizes(displayCount: displayCount)
        var origin = CGPoint.zero
        return sizes.map { size in
            let frame = CGRect(origin: origin, size: size)
            origin = CGPoint(x: frame.maxX, y: frame.maxY)
            return frame
        }
    }

    static func canvasRects(
        displayCount: Int,
        in canvas: CGSize,
        padding: CGFloat
    ) -> [CGRect] {
        transition(displayCount: displayCount, in: canvas, padding: padding).staircase
    }

    static func transition(
        displayCount: Int,
        in canvas: CGSize,
        padding: CGFloat
    ) -> Transition {
        let staircase = logicalFrames(displayCount: displayCount)
        let sideBySide = staircase.map { frame in
            CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.height)
        }
        let fitted = MonitorArrangementGeometry.canvasRects(
            forFramesYUp: sideBySide + staircase,
            in: canvas,
            padding: padding
        )
        let splitIndex = sideBySide.count
        return Transition(
            sideBySide: Array(fitted.prefix(splitIndex)),
            staircase: Array(fitted.dropFirst(splitIndex))
        )
    }

    private static func displaySizes(displayCount: Int) -> [CGSize] {
        guard displayCount > 0 else { return [] }
        var scale: CGFloat = 1
        return (0 ..< displayCount).map { _ in
            defer { scale *= 0.82 }
            return CGSize(width: 1600 * scale, height: 900 * scale)
        }
    }
}
