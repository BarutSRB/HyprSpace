// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum MouseContainment {
    enum Verdict: Equatable {
        case allow
        case wall(clamped: CGPoint)
    }

    static func evaluate(
        location: CGPoint,
        source: Monitor,
        destination: Monitor,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Verdict {
        guard source.id != destination.id else { return .allow }
        guard MonitorRouting.completeLayout(layout, for: monitors) != nil else { return .allow }
        guard let direction = physicalDirection(from: source, to: destination) else { return .allow }

        switch MonitorRouting.gridAdjacent(
            from: source,
            direction: direction,
            layout: layout,
            monitors: monitors,
            wrapAround: false
        ) {
        case let .monitor(routed) where routed.id == destination.id:
            return .allow
        case .fallBackToMacOS:
            return .allow
        case .monitor,
             .edge:
            break
        }

        guard isReachable(from: source, to: destination, layout: layout, monitors: monitors) else {
            return .allow
        }

        return .wall(clamped: clamped(location, inside: source.frame, margin: margin))
    }

    private static func physicalDirection(from source: Monitor, to destination: Monitor) -> Direction? {
        let dx = destination.frame.center.x - source.frame.center.x
        let dy = destination.frame.center.y - source.frame.center.y
        let absX = abs(dx)
        let absY = abs(dy)

        guard absX != absY else { return nil }
        if absX > absY {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .up : .down
    }

    private static func isReachable(
        from source: Monitor,
        to destination: Monitor,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor]
    ) -> Bool {
        let directions: [Direction] = [.left, .right, .up, .down]
        var visited = Set<Monitor.ID>()
        var pending = [source]
        visited.insert(source.id)

        while let current = pending.first {
            pending.removeFirst()
            if current.id == destination.id {
                return true
            }
            for direction in directions {
                switch MonitorRouting.gridAdjacent(
                    from: current,
                    direction: direction,
                    layout: layout,
                    monitors: monitors,
                    wrapAround: false
                ) {
                case let .monitor(next) where visited.insert(next.id).inserted:
                    pending.append(next)
                case .monitor,
                     .edge,
                     .fallBackToMacOS:
                    break
                }
            }
        }

        return false
    }

    private static func clamped(_ point: CGPoint, inside frame: CGRect, margin: CGFloat) -> CGPoint {
        let inset = margin + 1
        return CGPoint(
            x: clamped(point.x, min: frame.minX, max: frame.maxX, inset: inset),
            y: clamped(point.y, min: frame.minY, max: frame.maxY, inset: inset)
        )
    }

    private static func clamped(
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
}
