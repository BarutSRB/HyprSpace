// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorGapSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var innerGap: Double?
    var outerGapLeft: Double?
    var outerGapRight: Double?
    var outerGapTop: Double?
    var outerGapBottom: Double?
    var fullscreenUsesOuterGaps: Bool?

    var hasOverrides: Bool {
        innerGap != nil || outerGapLeft != nil || outerGapRight != nil ||
            outerGapTop != nil || outerGapBottom != nil || fullscreenUsesOuterGaps != nil
    }

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        innerGap: Double? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil,
        fullscreenUsesOuterGaps: Bool? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.innerGap = innerGap
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
        self.fullscreenUsesOuterGaps = fullscreenUsesOuterGaps
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case innerGap, outerGapLeft, outerGapRight, outerGapTop, outerGapBottom, fullscreenUsesOuterGaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        innerGap = try container.decodeIfPresent(Double.self, forKey: .innerGap)
        outerGapLeft = try container.decodeIfPresent(Double.self, forKey: .outerGapLeft)
        outerGapRight = try container.decodeIfPresent(Double.self, forKey: .outerGapRight)
        outerGapTop = try container.decodeIfPresent(Double.self, forKey: .outerGapTop)
        outerGapBottom = try container.decodeIfPresent(Double.self, forKey: .outerGapBottom)
        fullscreenUsesOuterGaps = try container.decodeIfPresent(Bool.self, forKey: .fullscreenUsesOuterGaps)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encodeIfPresent(innerGap, forKey: .innerGap)
        try container.encodeIfPresent(outerGapLeft, forKey: .outerGapLeft)
        try container.encodeIfPresent(outerGapRight, forKey: .outerGapRight)
        try container.encodeIfPresent(outerGapTop, forKey: .outerGapTop)
        try container.encodeIfPresent(outerGapBottom, forKey: .outerGapBottom)
        try container.encodeIfPresent(fullscreenUsesOuterGaps, forKey: .fullscreenUsesOuterGaps)
    }
}

struct ResolvedGapSettings: Equatable {
    let innerGap: CGFloat
    let outerGapLeft: CGFloat
    let outerGapRight: CGFloat
    let outerGapTop: CGFloat
    let outerGapBottom: CGFloat
    let fullscreenUsesOuterGaps: Bool
}
