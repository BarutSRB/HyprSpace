// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorDwindleSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var smartSplit: Bool?
    var defaultSplitRatio: Double?
    var splitWidthMultiplier: Double?
    var singleWindowFit: SingleWindowFit?
    var useGlobalGaps: Bool?
    var innerGap: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        smartSplit: Bool? = nil,
        defaultSplitRatio: Double? = nil,
        splitWidthMultiplier: Double? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        useGlobalGaps: Bool? = nil,
        innerGap: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.smartSplit = smartSplit
        self.defaultSplitRatio = defaultSplitRatio
        self.splitWidthMultiplier = splitWidthMultiplier
        self.singleWindowFit = singleWindowFit
        self.useGlobalGaps = useGlobalGaps
        self.innerGap = innerGap
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case smartSplit, defaultSplitRatio, splitWidthMultiplier
        case singleWindowFit
        case useGlobalGaps, innerGap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        smartSplit = try container.decodeIfPresent(Bool.self, forKey: .smartSplit)
        defaultSplitRatio = try container.decodeIfPresent(Double.self, forKey: .defaultSplitRatio)
        splitWidthMultiplier = try container.decodeIfPresent(Double.self, forKey: .splitWidthMultiplier)
        singleWindowFit = try container.decodeIfPresent(String.self, forKey: .singleWindowFit)
            .map { SingleWindowFit(serialized: $0) }
        useGlobalGaps = try container.decodeIfPresent(Bool.self, forKey: .useGlobalGaps)
        innerGap = try container.decodeIfPresent(Double.self, forKey: .innerGap)
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
        try container.encodeIfPresent(smartSplit, forKey: .smartSplit)
        try container.encodeIfPresent(defaultSplitRatio, forKey: .defaultSplitRatio)
        try container.encodeIfPresent(splitWidthMultiplier, forKey: .splitWidthMultiplier)
        try container.encodeIfPresent(singleWindowFit?.serialized, forKey: .singleWindowFit)
        try container.encodeIfPresent(useGlobalGaps, forKey: .useGlobalGaps)
        try container.encodeIfPresent(innerGap, forKey: .innerGap)
    }
}

struct ResolvedDwindleSettings: Equatable {
    let smartSplit: Bool
    let defaultSplitRatio: CGFloat
    let splitWidthMultiplier: CGFloat
    let singleWindowFit: SingleWindowFit
    let useGlobalGaps: Bool
    let innerGap: CGFloat
}
