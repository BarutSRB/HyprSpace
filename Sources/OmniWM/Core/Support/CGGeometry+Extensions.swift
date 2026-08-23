// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import Synchronization

enum FloatingFrameGeometry {
    static func origin(
        from normalizedOrigin: CGPoint,
        windowSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let availableWidth = max(0, visibleFrame.width - windowSize.width)
        let availableHeight = max(0, visibleFrame.height - windowSize.height)
        return CGPoint(
            x: visibleFrame.minX + min(max(0, normalizedOrigin.x), 1) * availableWidth,
            y: visibleFrame.minY + min(max(0, normalizedOrigin.y), 1) * availableHeight
        )
    }

    static func clamped(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let maxX = visibleFrame.maxX - frame.width
        let maxY = visibleFrame.maxY - frame.height
        let clampedX = min(max(frame.origin.x, visibleFrame.minX), max(maxX, visibleFrame.minX))
        let clampedY = min(max(frame.origin.y, visibleFrame.minY), max(maxY, visibleFrame.minY))
        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: frame.size)
    }
}

enum FrameTolerance {
    static let frameWrite: CGFloat = 1.0
    static let screenMatch: CGFloat = 2.0
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(origin.x - other.origin.x) < tolerance &&
            abs(origin.y - other.origin.y) < tolerance &&
            abs(width - other.width) < tolerance &&
            abs(height - other.height) < tolerance
    }
}

enum ScreenCoordinateSpace {
    private struct ScreenTransform {
        let appKitFrame: CGRect
        let quartzFrame: CGRect
        let scaleX: CGFloat
        let scaleY: CGFloat

        func toAppKit(point: CGPoint) -> CGPoint {
            let dx = point.x - quartzFrame.minX
            let dy = point.y - quartzFrame.minY
            let x = appKitFrame.minX + (dx / scaleX)
            let y = appKitFrame.maxY - (dy / scaleY)
            return CGPoint(x: x, y: y)
        }

        func toWindowServer(point: CGPoint) -> CGPoint {
            let dx = point.x - appKitFrame.minX
            let dy = appKitFrame.maxY - point.y
            let x = quartzFrame.minX + (dx * scaleX)
            let y = quartzFrame.minY + (dy * scaleY)
            return CGPoint(x: x, y: y)
        }

        func toAppKit(rect: CGRect) -> CGRect {
            let dx = rect.origin.x - quartzFrame.minX
            let dy = rect.origin.y - quartzFrame.minY
            let x = appKitFrame.minX + (dx / scaleX)
            let height = rect.size.height / scaleY
            let width = rect.size.width / scaleX
            let y = appKitFrame.maxY - (dy / scaleY) - height
            return CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        }

        func toWindowServer(rect: CGRect) -> CGRect {
            let dx = rect.origin.x - appKitFrame.minX
            let dy = appKitFrame.maxY - rect.origin.y - rect.size.height
            let x = quartzFrame.minX + (dx * scaleX)
            let y = quartzFrame.minY + (dy * scaleY)
            let width = rect.size.width * scaleX
            let height = rect.size.height * scaleY
            return CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
        }
    }

    private struct CacheState {
        var transforms: [ScreenTransform]?
        var globalFrame: CGRect?
    }

    private static let cache = Mutex(CacheState())

    static func invalidateCache() {
        cache.withLock { $0 = CacheState() }
    }

    private static func transforms() -> [ScreenTransform] {
        if let cached = cache.withLock({ $0.transforms }) {
            return cached
        }
        let transforms = NSScreen.screens.compactMap { screen -> ScreenTransform? in
            guard let displayId = screen.displayId else { return nil }
            let quartzFrame = CGDisplayBounds(displayId)
            let appKitFrame = screen.frame
            let scaleX = quartzFrame.width / max(1.0, appKitFrame.width)
            let scaleY = quartzFrame.height / max(1.0, appKitFrame.height)
            return ScreenTransform(
                appKitFrame: appKitFrame,
                quartzFrame: quartzFrame,
                scaleX: scaleX,
                scaleY: scaleY
            )
        }
        cache.withLock { $0.transforms = transforms }
        return transforms
    }

    static var globalFrame: CGRect {
        if let cached = cache.withLock({ $0.globalFrame }) {
            return cached
        }
        let frame = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
        cache.withLock { $0.globalFrame = frame }
        return frame
    }

    private static func transformForQuartz(point: CGPoint) -> ScreenTransform? {
        transforms().first { $0.quartzFrame.contains(point) }
    }

    private static func transformForAppKit(point: CGPoint) -> ScreenTransform? {
        transforms().first { $0.appKitFrame.contains(point) }
    }

    private static func transformClosestToQuartz(point: CGPoint) -> ScreenTransform? {
        if let transform = transformForQuartz(point: point) {
            return transform
        }
        return transforms().min { lhs, rhs in
            lhs.quartzFrame.distanceSquared(to: point) < rhs.quartzFrame.distanceSquared(to: point)
        }
    }

    private static func transformClosestToAppKit(point: CGPoint) -> ScreenTransform? {
        if let transform = transformForAppKit(point: point) {
            return transform
        }
        return transforms().min { lhs, rhs in
            lhs.appKitFrame.distanceSquared(to: point) < rhs.appKitFrame.distanceSquared(to: point)
        }
    }

    static func toAppKit(point: CGPoint) -> CGPoint {
        if let transform = transformClosestToQuartz(point: point) {
            return transform.toAppKit(point: point)
        }
        let global = globalFrame
        return CGPoint(x: point.x, y: global.maxY - point.y)
    }

    static func toAppKit(rect: CGRect) -> CGRect {
        if let transform = transformClosestToQuartz(point: rect.center) {
            return transform.toAppKit(rect: rect)
        }
        let global = globalFrame
        let flippedY = global.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }

    static func toWindowServer(point: CGPoint) -> CGPoint {
        if let transform = transformClosestToAppKit(point: point) {
            return transform.toWindowServer(point: point)
        }
        let global = globalFrame
        return CGPoint(x: point.x, y: global.maxY - point.y)
    }

    static func toWindowServer(rect: CGRect) -> CGRect {
        if let transform = transformClosestToAppKit(point: rect.center) {
            return transform.toWindowServer(rect: rect)
        }
        let global = globalFrame
        let flippedY = global.maxY - (rect.origin.y + rect.size.height)
        return CGRect(origin: CGPoint(x: rect.origin.x, y: flippedY), size: rect.size)
    }
}

extension NSScreen {
    static func screen(containing point: CGPoint) -> NSScreen? {
        screens.first(where: { $0.frame.contains(point) })
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        screens.first(where: { $0.frame.intersects(rect) })
            ?? screen(containing: rect.center)
    }
}
