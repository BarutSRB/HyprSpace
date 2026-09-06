// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum MonitorRoutingMode: String, Codable, CaseIterable {
    case macOS
    case custom
}

struct MonitorArrangement: Codable, Equatable, Identifiable {
    var id: UUID
    var monitors: [MonitorRoutingSettings]

    init(id: UUID = UUID(), monitors: [MonitorRoutingSettings]) {
        self.id = id
        self.monitors = monitors
    }
}

struct MonitorRoutingSettings: MonitorSettingsType {
    var id: String {
        DisplayUUID.canonical(monitorDisplayUUID) ??
            monitorDisplayId.map(String.init) ??
            monitorName
    }

    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?
    var gridColumn: Int
    var gridRow: Int

    init(
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        gridColumn: Int,
        gridRow: Int
    ) {
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.gridColumn = gridColumn
        self.gridRow = gridRow
    }

    private enum CodingKeys: String, CodingKey {
        case monitorName, monitorDisplayUUID, monitorDisplayId, gridColumn, gridRow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        gridColumn = try container.decode(Int.self, forKey: .gridColumn)
        gridRow = try container.decode(Int.self, forKey: .gridRow)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encode(gridColumn, forKey: .gridColumn)
        try container.encode(gridRow, forKey: .gridRow)
    }
}
