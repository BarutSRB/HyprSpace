// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct NiriContainerSizingState: Codable, Equatable, Sendable {
    let width: ProportionalSize
    let presetWidthIndex: Int?
    let isFullWidth: Bool
    let savedWidth: ProportionalSize?
    let hasManualSingleWindowWidthOverride: Bool
    let height: ProportionalSize
    let isFullHeight: Bool
    let savedHeight: ProportionalSize?
    let hasManualSingleWindowHeightOverride: Bool

    init(
        width: ProportionalSize,
        presetWidthIndex: Int?,
        isFullWidth: Bool,
        savedWidth: ProportionalSize?,
        hasManualSingleWindowWidthOverride: Bool,
        height: ProportionalSize = .default,
        isFullHeight: Bool = false,
        savedHeight: ProportionalSize? = nil,
        hasManualSingleWindowHeightOverride: Bool = false
    ) {
        self.width = width
        self.presetWidthIndex = presetWidthIndex
        self.isFullWidth = isFullWidth
        self.savedWidth = savedWidth
        self.hasManualSingleWindowWidthOverride = hasManualSingleWindowWidthOverride
        self.height = height
        self.isFullHeight = isFullHeight
        self.savedHeight = savedHeight
        self.hasManualSingleWindowHeightOverride = hasManualSingleWindowHeightOverride
    }
}

struct PersistedNiriColumnState: Codable, Equatable, Sendable {
    let displayMode: ColumnDisplay
    let activeTileIndex: Int
    let width: ProportionalSize
    let presetWidthIndex: Int?
    let isFullWidth: Bool
    let savedWidth: ProportionalSize?
    let hasManualSingleWindowWidthOverride: Bool
    let height: ProportionalSize
    let isFullHeight: Bool
    let savedHeight: ProportionalSize?
    let hasManualSingleWindowHeightOverride: Bool

    init(
        displayMode: ColumnDisplay,
        activeTileIndex: Int,
        width: ProportionalSize,
        presetWidthIndex: Int?,
        isFullWidth: Bool,
        savedWidth: ProportionalSize?,
        hasManualSingleWindowWidthOverride: Bool,
        height: ProportionalSize = .default,
        isFullHeight: Bool = false,
        savedHeight: ProportionalSize? = nil,
        hasManualSingleWindowHeightOverride: Bool = false
    ) {
        self.displayMode = displayMode
        self.activeTileIndex = activeTileIndex
        self.width = width
        self.presetWidthIndex = presetWidthIndex
        self.isFullWidth = isFullWidth
        self.savedWidth = savedWidth
        self.hasManualSingleWindowWidthOverride = hasManualSingleWindowWidthOverride
        self.height = height
        self.isFullHeight = isFullHeight
        self.savedHeight = savedHeight
        self.hasManualSingleWindowHeightOverride = hasManualSingleWindowHeightOverride
    }
}

struct PersistedNiriWindowState: Codable, Equatable, Sendable {
    let sizingMode: SizingMode
    let height: WeightedSize
    let savedHeight: WeightedSize?
    let windowWidth: WeightedSize
}

struct PersistedNiriPlacement: Codable, Equatable, Sendable {
    let columnIndex: Int
    let tileIndex: Int
    let column: PersistedNiriColumnState
    let window: PersistedNiriWindowState
}

struct PersistedRestoreIntent: Codable, Equatable, Sendable {
    let workspaceName: String
    let topologyProfile: TopologyProfile
    let preferredMonitor: DisplayFingerprint?
    let floatingFrame: CGRect?
    let normalizedFloatingOrigin: CGPoint?
    let restoreToFloating: Bool
    let rescueEligible: Bool
    let niriPlacement: PersistedNiriPlacement?
    let detachedNiriContainerSizingState: NiriContainerSizingState?

    init(
        workspaceName: String,
        topologyProfile: TopologyProfile,
        preferredMonitor: DisplayFingerprint?,
        floatingFrame: CGRect?,
        normalizedFloatingOrigin: CGPoint?,
        restoreToFloating: Bool,
        rescueEligible: Bool,
        niriPlacement: PersistedNiriPlacement? = nil,
        detachedNiriContainerSizingState: NiriContainerSizingState? = nil
    ) {
        self.workspaceName = workspaceName
        self.topologyProfile = topologyProfile
        self.preferredMonitor = preferredMonitor
        self.floatingFrame = floatingFrame
        self.normalizedFloatingOrigin = normalizedFloatingOrigin
        self.restoreToFloating = restoreToFloating
        self.rescueEligible = rescueEligible
        self.niriPlacement = niriPlacement
        self.detachedNiriContainerSizingState = detachedNiriContainerSizingState
    }
}

struct PersistedWindowRestoreIdentity: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    let windowId: Int
    let bundleId: String

    init?(token: WindowToken, metadata: ManagedReplacementMetadata) {
        guard let bundleId = PersistedWindowRestoreBaseKey.normalizeBundleId(metadata.bundleId) else {
            return nil
        }

        pid = token.pid
        windowId = token.windowId
        self.bundleId = bundleId
    }

    func matches(token: WindowToken, metadata: ManagedReplacementMetadata) -> Bool {
        guard let otherBundleId = PersistedWindowRestoreBaseKey.normalizeBundleId(metadata.bundleId) else {
            return false
        }

        return pid == token.pid && windowId == token.windowId && bundleId == otherBundleId
    }
}

struct PersistedWindowRestoreBaseKey: Codable, Equatable, Hashable, Sendable {
    let bundleId: String
    let role: String?
    let subrole: String?
    let windowLevel: Int32?
    let parentWindowId: UInt32?

    init?(
        bundleId: String?,
        role: String?,
        subrole: String?,
        windowLevel: Int32?,
        parentWindowId: UInt32?
    ) {
        guard let normalizedBundleId = Self.normalizeBundleId(bundleId) else {
            return nil
        }

        self.bundleId = normalizedBundleId
        self.role = Self.normalizeText(role)
        self.subrole = Self.normalizeText(subrole)
        self.windowLevel = windowLevel
        self.parentWindowId = parentWindowId
    }

    init?(metadata: ManagedReplacementMetadata) {
        self.init(
            bundleId: metadata.bundleId,
            role: metadata.role,
            subrole: metadata.subrole,
            windowLevel: metadata.windowLevel,
            parentWindowId: metadata.parentWindowId
        )
    }

    static func normalizeBundleId(_ bundleId: String?) -> String? {
        guard let bundleId = normalizeText(bundleId) else {
            return nil
        }
        return bundleId.lowercased()
    }

    fileprivate static func normalizeText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }
}

struct PersistedWindowRestoreKey: Codable, Equatable, Hashable, Sendable {
    let baseKey: PersistedWindowRestoreBaseKey
    let title: String?

    init?(metadata: ManagedReplacementMetadata, title: String? = nil) {
        guard let baseKey = PersistedWindowRestoreBaseKey(metadata: metadata) else {
            return nil
        }

        self.baseKey = baseKey
        self.title = Self.normalizeTitle(title ?? metadata.title)
    }

    func matches(_ metadata: ManagedReplacementMetadata) -> Bool {
        guard let otherBaseKey = PersistedWindowRestoreBaseKey(metadata: metadata),
              otherBaseKey == baseKey
        else {
            return false
        }

        guard let title else {
            return true
        }
        return title == Self.normalizeTitle(metadata.title)
    }

    static func normalizeTitle(_ title: String?) -> String? {
        PersistedWindowRestoreBaseKey.normalizeText(title)
    }
}

struct PersistedWindowRestoreEntry: Codable, Equatable, Sendable {
    let key: PersistedWindowRestoreKey
    let identity: PersistedWindowRestoreIdentity?
    let restoreIntent: PersistedRestoreIntent
}

struct PersistedWindowRestoreConsumptionKey: Equatable, Hashable, Sendable {
    let key: PersistedWindowRestoreKey
    let identity: PersistedWindowRestoreIdentity?

    init(entry: PersistedWindowRestoreEntry) {
        key = entry.key
        identity = entry.identity
    }
}

struct PersistedWindowRestoreCatalog: Codable, Equatable, Sendable {
    var entries: [PersistedWindowRestoreEntry]

    static let empty = PersistedWindowRestoreCatalog(entries: [])
}
