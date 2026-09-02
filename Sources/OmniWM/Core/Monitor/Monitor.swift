// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation

enum DisplayUUID {
    static func canonical(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: trimmed)
        else { return nil }
        return uuid.uuidString
    }

    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let canonical = canonical(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid display UUID"
            )
        }
        return canonical
    }

    static func encode<Key: CodingKey>(
        _ value: String?,
        displayId: CGDirectDisplayID?,
        to container: inout KeyedEncodingContainer<Key>,
        uuidKey: Key,
        displayIdKey: Key
    ) throws {
        if let value {
            guard let canonical = canonical(value) else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: container.codingPath + [uuidKey],
                        debugDescription: "Invalid display UUID"
                    )
                )
            }
            try container.encode(canonical, forKey: uuidKey)
        } else {
            try container.encodeIfPresent(displayId, forKey: displayIdKey)
        }
    }
}

struct Monitor: Identifiable, Hashable {
    struct ID: Hashable {
        let displayId: CGDirectDisplayID

        static let fallback = ID(displayId: CGMainDisplayID())
    }

    let id: ID
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let hasNotch: Bool
    var notchRange: ClosedRange<CGFloat>?

    let name: String
    let displayUUID: String?

    init(
        id: ID,
        displayId: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        hasNotch: Bool,
        notchRange: ClosedRange<CGFloat>? = nil,
        name: String,
        displayUUID: String? = nil
    ) {
        self.id = id
        self.displayId = displayId
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
        self.notchRange = notchRange
        self.name = name
        self.displayUUID = DisplayUUID.canonical(displayUUID)
    }

    static func current() -> [Monitor] {
        let monitors = NSScreen.screens.compactMap { screen -> Monitor? in
            guard let displayId = screen.displayId else {
                FallbackFiringRecorder.shared.note(.monitor, "nsScreenDisplayIdNil")
                return nil
            }
            let hasNotch = screen.safeAreaInsets.top > 0
            return Monitor(
                id: ID(displayId: displayId),
                displayId: displayId,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasNotch: hasNotch,
                notchRange: notchRange(of: screen),
                name: screen.localizedName,
                displayUUID: SkyLight.displayUUID(for: displayId)
            )
        }
        return discardingAmbiguousDisplayUUIDs(in: monitors)
    }

    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        !lhs.isEmpty &&
            !rhs.isEmpty &&
            lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func discardingAmbiguousDisplayUUIDs(in monitors: [Monitor]) -> [Monitor] {
        let uuidCounts = monitors.reduce(into: [String: Int]()) { counts, monitor in
            guard let displayUUID = monitor.displayUUID else { return }
            counts[displayUUID, default: 0] += 1
        }
        guard uuidCounts.values.contains(where: { $0 > 1 }) else { return monitors }
        FallbackFiringRecorder.shared.note(.monitor, "duplicateDisplayUUID")

        return monitors.map { monitor in
            guard let displayUUID = monitor.displayUUID,
                  uuidCounts[displayUUID, default: 0] > 1
            else { return monitor }
            return Monitor(
                id: monitor.id,
                displayId: monitor.displayId,
                frame: monitor.frame,
                visibleFrame: monitor.visibleFrame,
                hasNotch: monitor.hasNotch,
                notchRange: monitor.notchRange,
                name: monitor.name
            )
        }
    }

    private static func notchRange(of screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.maxX < right.minX
        else {
            return nil
        }
        return left.maxX ... right.minX
    }

    static func refreshRate(for displayId: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayId), mode.refreshRate > 0 else {
            FallbackFiringRecorder.shared.note(.monitor, "refreshRateFallback60")
            return 60.0
        }
        return mode.refreshRate
    }

    static func fallback() -> Monitor {
        if NSScreen.main == nil {
            FallbackFiringRecorder.shared.note(.monitor, "nsScreenMainNil")
        }
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let displayId = NSScreen.main?.displayId ?? CGMainDisplayID()
        let hasNotch = NSScreen.main?.safeAreaInsets.top ?? 0 > 0
        return Monitor(
            id: .fallback,
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: hasNotch,
            notchRange: NSScreen.main.flatMap { notchRange(of: $0) },
            name: "Fallback"
        )
    }
}

struct MonitorNeighborAxes: Equatable {
    let horizontal: Bool
    let vertical: Bool

    static let none = MonitorNeighborAxes(horizontal: false, vertical: false)
}

extension Monitor {
    enum Orientation: String, Codable, Equatable {
        case horizontal
        case vertical
    }

    func neighborAxes(among monitors: [Monitor]) -> MonitorNeighborAxes {
        var horizontal = false
        var vertical = false
        for other in monitors where other.id != id {
            if (other.frame.minY ..< other.frame.maxY).overlaps(frame.minY ..< frame.maxY) {
                horizontal = true
            }
            if (other.frame.minX ..< other.frame.maxX).overlaps(frame.minX ..< frame.maxX) {
                vertical = true
            }
        }
        return MonitorNeighborAxes(horizontal: horizontal, vertical: vertical)
    }

    var autoOrientation: Orientation {
        frame.width >= frame.height ? .horizontal : .vertical
    }

    var isMain: Bool {
        let mainDisplayId = CGMainDisplayID()
        if mainDisplayId != 0 {
            return displayId == mainDisplayId
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
           let displayId = screen.displayId
        {
            return self.displayId == displayId
        }
        return frame.minX == 0 && frame.minY == 0
    }

    var workspaceAnchorPoint: CGPoint {
        frame.topLeftCorner
    }

    func relation(to monitor: Monitor) -> Orientation {
        let otherYRange = monitor.frame.minY ..< monitor.frame.maxY
        let myYRange = frame.minY ..< frame.maxY
        return myYRange.overlaps(otherYRange) ? .horizontal : .vertical
    }

    static func sortedByPosition(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted {
            if $0.frame.minX != $1.frame.minX {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.frame.maxY > $1.frame.maxY
        }
    }
}

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

extension CGRect {
    var topLeftCorner: CGPoint {
        CGPoint(x: minX, y: maxY)
    }
}

extension CGRect {
    func distanceSquared(to point: CGPoint) -> CGFloat {
        // Keep fallback distance calculations aligned with CGRect.contains(_:),
        // which treats maxX/maxY as exclusive bounds.
        let maxInclusiveX = maxX > minX ? maxX.nextDown : minX
        let maxInclusiveY = maxY > minY ? maxY.nextDown : minY
        let clampedX = min(max(point.x, minX), maxInclusiveX)
        let clampedY = min(max(point.y, minY), maxInclusiveY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

extension CGPoint {
    func monitorApproximation(in monitors: [Monitor]) -> Monitor? {
        if let containing = monitors.first(where: { $0.frame.contains(self) }) {
            return containing
        }
        return monitors.min(by: { $0.frame.distanceSquared(to: self) < $1.frame.distanceSquared(to: self) })
    }
}

extension Monitor {
    static func isUsableConfiguration(_ monitors: [Monitor]) -> Bool {
        !monitors.isEmpty
            && monitors.allSatisfy { $0.frame.width > 1 && $0.frame.height > 1 }
    }
}
