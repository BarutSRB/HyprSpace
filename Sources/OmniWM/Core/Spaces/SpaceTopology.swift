// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct SpaceTopology: Equatable, Sendable {
    struct DisplaySpaces: Equatable, Sendable {
        var displayIdentifier: String
        var spaceIds: [UInt64]
        var currentSpaceId: UInt64
    }

    var displays: [DisplaySpaces] = []
    var activeSpaceId: UInt64 = 0
    var fullscreenSpaceIds: Set<UInt64> = []
    var windowSpace: [Int: UInt64] = [:]

    var isPopulated: Bool {
        !displays.isEmpty
    }

    var debugSummary: String {
        guard isPopulated || !windowSpace.isEmpty else { return "none" }
        var lines = [
            "active=\(activeSpaceId) populated=\(isPopulated) fullscreen=\(formatIds(fullscreenSpaceIds.sorted()))"
        ]
        for display in displays {
            lines.append(
                "display=\(display.displayIdentifier) current=\(display.currentSpaceId) spaces=\(formatIds(display.spaceIds))"
            )
        }
        for windowId in windowSpace.keys.sorted() {
            lines.append("window=\(windowId) space=\(windowSpace[windowId] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatIds(_ ids: [UInt64]) -> String {
        "[\(ids.map(String.init).joined(separator: ","))]"
    }

    func spaceForWindow(_ windowId: Int) -> UInt64? {
        windowSpace[windowId]
    }

    func isFullscreenSpace(_ spaceId: UInt64) -> Bool {
        fullscreenSpaceIds.contains(spaceId)
    }

    func isCurrentSpace(_ spaceId: UInt64) -> Bool {
        displays.contains { $0.currentSpaceId == spaceId }
    }

    func isKnownSpace(_ spaceId: UInt64) -> Bool {
        displays.contains { $0.currentSpaceId == spaceId || $0.spaceIds.contains(spaceId) }
    }

    func isDisplayShowingFullscreenSpace(_ displayIdentifier: String) -> Bool? {
        let displayIdentifier = DisplayUUID.canonical(displayIdentifier) ?? displayIdentifier
        var currentSpaceId: UInt64?
        for display in displays {
            let candidate = DisplayUUID.canonical(display.displayIdentifier) ?? display.displayIdentifier
            guard candidate == displayIdentifier else { continue }
            guard currentSpaceId == nil else { return nil }
            currentSpaceId = display.currentSpaceId
        }
        guard let currentSpaceId else { return nil }
        return fullscreenSpaceIds.contains(currentSpaceId)
    }

    func isDisplayShowingFullscreenSpace(on monitor: Monitor) -> Bool? {
        isDisplayShowingFullscreenSpace(monitor.displayUUID ?? String(monitor.displayId))
    }

    /// Canonical identifiers of the displays whose current space is a native fullscreen space.
    /// Ambiguous identifiers (listed more than once) are skipped, matching
    /// `isDisplayShowingFullscreenSpace(_:)`.
    var displaysShowingFullscreenSpace: Set<String> {
        var seen: [String: UInt64] = [:]
        var ambiguous: Set<String> = []
        for display in displays {
            let identifier = DisplayUUID.canonical(display.displayIdentifier) ?? display.displayIdentifier
            if seen.updateValue(display.currentSpaceId, forKey: identifier) != nil {
                ambiguous.insert(identifier)
            }
        }
        return Set(
            seen.compactMap { identifier, currentSpaceId in
                guard !ambiguous.contains(identifier), fullscreenSpaceIds.contains(currentSpaceId) else {
                    return nil
                }
                return identifier
            }
        )
    }

    func normalizingDisplayIdentifiers(using monitors: [Monitor]) -> SpaceTopology {
        var topology = self
        let mainMonitor = monitors.first(where: \.isMain) ?? monitors.first
        for index in topology.displays.indices {
            let identifier = topology.displays[index].displayIdentifier
            if let canonical = DisplayUUID.canonical(identifier) {
                topology.displays[index].displayIdentifier = canonical
                continue
            }
            let monitor: Monitor?
            if identifier.caseInsensitiveCompare("Main") == .orderedSame {
                monitor = mainMonitor
            } else if let displayId = UInt32(identifier) {
                monitor = monitors.first { $0.displayId == displayId }
            } else {
                monitor = nil
            }
            if let monitor {
                topology.displays[index].displayIdentifier = monitor.displayUUID ?? String(monitor.displayId)
            }
        }
        return topology
    }

    func isWindowOnFullscreenSpace(_ windowId: Int) -> Bool {
        guard let spaceId = windowSpace[windowId] else { return false }
        return fullscreenSpaceIds.contains(spaceId)
    }

    func isWindowOnKnownInactiveSpace(_ windowId: Int) -> Bool {
        guard let spaceId = windowSpace[windowId] else { return false }
        return isKnownSpace(spaceId) && !isCurrentSpace(spaceId)
    }

    func selectWindowSpace(from candidates: [UInt64]) -> UInt64? {
        if let currentDesktop = candidates.first(where: { isCurrentSpace($0) && !isFullscreenSpace($0) }) {
            return currentDesktop
        }
        if let knownDesktop = candidates.first(where: { isKnownSpace($0) && !isFullscreenSpace($0) }) {
            return knownDesktop
        }
        if let current = candidates.first(where: { isCurrentSpace($0) }) {
            return current
        }
        return candidates.first { $0 != 0 }
    }
}
