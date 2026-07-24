// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorBarSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var enabled: Bool?
    var showLabels: Bool?
    var showFloatingWindows: Bool?
    var deduplicateAppIcons: Bool?
    var hideEmptyWorkspaces: Bool?
    var reserveLayoutSpace: Bool?
    var notchMode: WorkspaceBarNotchMode?
    var notchActiveZoneWidth: Double?
    var position: WorkspaceBarPosition?
    var windowLevel: WorkspaceBarWindowLevel?
    var height: Double?
    var backgroundOpacity: Double?
    var xOffset: Double?
    var yOffset: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        enabled: Bool? = nil,
        showLabels: Bool? = nil,
        showFloatingWindows: Bool? = nil,
        deduplicateAppIcons: Bool? = nil,
        hideEmptyWorkspaces: Bool? = nil,
        reserveLayoutSpace: Bool? = nil,
        notchMode: WorkspaceBarNotchMode? = nil,
        notchActiveZoneWidth: Double? = nil,
        position: WorkspaceBarPosition? = nil,
        windowLevel: WorkspaceBarWindowLevel? = nil,
        height: Double? = nil,
        backgroundOpacity: Double? = nil,
        xOffset: Double? = nil,
        yOffset: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.enabled = enabled
        self.showLabels = showLabels
        self.showFloatingWindows = showFloatingWindows
        self.deduplicateAppIcons = deduplicateAppIcons
        self.hideEmptyWorkspaces = hideEmptyWorkspaces
        self.reserveLayoutSpace = reserveLayoutSpace
        self.notchMode = notchMode
        self.notchActiveZoneWidth = notchActiveZoneWidth
        self.position = position
        self.windowLevel = windowLevel
        self.height = height
        self.backgroundOpacity = backgroundOpacity
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case enabled, showLabels, showFloatingWindows, deduplicateAppIcons
        case hideEmptyWorkspaces, reserveLayoutSpace, notchMode, notchActiveZoneWidth, position, windowLevel
        case height, backgroundOpacity, xOffset, yOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels)
        showFloatingWindows = try container.decodeIfPresent(Bool.self, forKey: .showFloatingWindows)
        deduplicateAppIcons = try container.decodeIfPresent(Bool.self, forKey: .deduplicateAppIcons)
        hideEmptyWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .hideEmptyWorkspaces)
        reserveLayoutSpace = try container.decodeIfPresent(Bool.self, forKey: .reserveLayoutSpace)
        notchMode = try container.decodeIfPresent(String.self, forKey: .notchMode)
            .flatMap { WorkspaceBarNotchMode(rawValue: $0) }
        notchActiveZoneWidth = try container.decodeIfPresent(Double.self, forKey: .notchActiveZoneWidth)
        position = try container.decodeIfPresent(String.self, forKey: .position)
            .flatMap { WorkspaceBarPosition(rawValue: $0) }
        windowLevel = try container.decodeIfPresent(String.self, forKey: .windowLevel)
            .flatMap { WorkspaceBarWindowLevel(rawValue: $0) }
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        xOffset = try container.decodeIfPresent(Double.self, forKey: .xOffset)
        yOffset = try container.decodeIfPresent(Double.self, forKey: .yOffset)
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
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(showLabels, forKey: .showLabels)
        try container.encodeIfPresent(showFloatingWindows, forKey: .showFloatingWindows)
        try container.encodeIfPresent(deduplicateAppIcons, forKey: .deduplicateAppIcons)
        try container.encodeIfPresent(hideEmptyWorkspaces, forKey: .hideEmptyWorkspaces)
        try container.encodeIfPresent(reserveLayoutSpace, forKey: .reserveLayoutSpace)
        try container.encodeIfPresent(notchMode?.rawValue, forKey: .notchMode)
        try container.encodeIfPresent(notchActiveZoneWidth, forKey: .notchActiveZoneWidth)
        try container.encodeIfPresent(position?.rawValue, forKey: .position)
        try container.encodeIfPresent(windowLevel?.rawValue, forKey: .windowLevel)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(xOffset, forKey: .xOffset)
        try container.encodeIfPresent(yOffset, forKey: .yOffset)
    }
}

struct ResolvedBarSettings {
    let enabled: Bool
    let showLabels: Bool
    let showFloatingWindows: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let excludedBundleIDs: Set<String>
    let reserveLayoutSpace: Bool
    let notchMode: WorkspaceBarNotchMode
    let notchActiveZoneWidth: Double
    let systemStatsButton: Bool
    let position: WorkspaceBarPosition
    let windowLevel: WorkspaceBarWindowLevel
    let height: Double
    let backgroundOpacity: Double
    let xOffset: Double
    let yOffset: Double
    let accentColor: SettingsColor?
    let textColor: SettingsColor?
}
