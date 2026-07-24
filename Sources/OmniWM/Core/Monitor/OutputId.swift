// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct OutputId: Hashable, Codable {
    let displayUUID: String?
    let displayId: CGDirectDisplayID?
    let name: String

    init(
        displayUUID: String? = nil,
        displayId: CGDirectDisplayID? = nil,
        name: String
    ) {
        self.displayUUID = DisplayUUID.canonical(displayUUID)
        self.displayId = displayId
        self.name = name
    }

    init(from monitor: Monitor) {
        displayUUID = monitor.displayUUID
        displayId = monitor.displayId
        name = monitor.name
    }

    func resolveMonitor(in monitors: [Monitor]) -> Monitor? {
        if let displayUUID {
            return uniqueMonitor(in: monitors) {
                $0.displayUUID == displayUUID
            }
        }

        guard let displayId else { return nil }
        return uniqueMonitor(in: monitors) {
            $0.displayUUID == nil &&
                $0.displayId == displayId &&
                Monitor.namesMatch($0.name, name)
        }
    }

    static func == (lhs: OutputId, rhs: OutputId) -> Bool {
        if lhs.displayUUID != nil || rhs.displayUUID != nil {
            return lhs.displayUUID == rhs.displayUUID
        }
        return lhs.displayId == rhs.displayId &&
            lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        if let displayUUID {
            hasher.combine(displayUUID)
        } else {
            hasher.combine(displayId)
            hasher.combine(name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case displayUUID, displayId, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try DisplayUUID.decode(from: container, forKey: .displayUUID)
        displayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .displayId)
        name = try container.decode(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try DisplayUUID.encode(
            displayUUID,
            displayId: displayId,
            to: &container,
            uuidKey: .displayUUID,
            displayIdKey: .displayId
        )
    }

    private func uniqueMonitor(
        in monitors: [Monitor],
        matching predicate: (Monitor) -> Bool
    ) -> Monitor? {
        var match: Monitor?
        for monitor in monitors where predicate(monitor) {
            guard match == nil else { return nil }
            match = monitor
        }
        return match
    }
}
