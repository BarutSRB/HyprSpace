// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct MonitorOrientationSettings: MonitorSettingsType {
    var id: String {
        DisplayUUID.canonical(monitorDisplayUUID) ??
            monitorDisplayId.map(String.init) ??
            monitorName
    }

    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?
    var orientation: Monitor.Orientation?

    init(
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        orientation: Monitor.Orientation? = nil
    ) {
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case monitorName, monitorDisplayUUID, monitorDisplayId, orientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        orientation = try container.decodeIfPresent(Monitor.Orientation.self, forKey: .orientation)
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
        try container.encodeIfPresent(orientation, forKey: .orientation)
    }
}
