// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorNiriSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var visibleContainerCount: Int?
    var centerFocusedColumn: CenterFocusedColumn?
    var alwaysCenterSingleColumn: Bool?
    var singleWindowFit: SingleWindowFit?
    var infiniteLoop: Bool?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        visibleContainerCount: Int? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        infiniteLoop: Bool? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.visibleContainerCount = visibleContainerCount
        self.centerFocusedColumn = centerFocusedColumn
        self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        self.singleWindowFit = singleWindowFit
        self.infiniteLoop = infiniteLoop
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId, visibleContainerCount
        case centerFocusedColumn, alwaysCenterSingleColumn
        case singleWindowFit
        case infiniteLoop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        visibleContainerCount = try container.decodeIfPresent(Int.self, forKey: .visibleContainerCount)
        centerFocusedColumn = try container.decodeIfPresent(String.self, forKey: .centerFocusedColumn)
            .flatMap { CenterFocusedColumn(rawValue: $0) }
        alwaysCenterSingleColumn = try container.decodeIfPresent(Bool.self, forKey: .alwaysCenterSingleColumn)
        singleWindowFit = try container.decodeIfPresent(String.self, forKey: .singleWindowFit)
            .map { SingleWindowFit(serialized: $0) }
        infiniteLoop = try container.decodeIfPresent(Bool.self, forKey: .infiniteLoop)
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
        try container.encodeIfPresent(visibleContainerCount, forKey: .visibleContainerCount)
        try container.encodeIfPresent(centerFocusedColumn?.rawValue, forKey: .centerFocusedColumn)
        try container.encodeIfPresent(alwaysCenterSingleColumn, forKey: .alwaysCenterSingleColumn)
        try container.encodeIfPresent(singleWindowFit?.serialized, forKey: .singleWindowFit)
        try container.encodeIfPresent(infiniteLoop, forKey: .infiniteLoop)
    }
}

struct ResolvedNiriSettings: Equatable {
    let visibleContainerCount: Int
    let centerFocusedColumn: CenterFocusedColumn
    let alwaysCenterSingleColumn: Bool
    let singleWindowFit: SingleWindowFit
    let infiniteLoop: Bool
}
