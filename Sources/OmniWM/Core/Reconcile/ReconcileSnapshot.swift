// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum WindowLifecyclePhase: String, Codable, Equatable {
    case tiled
    case floating
    case hidden
    case offscreen
    case replacing
    case nativeFullscreen
    case destroyed
}

struct ObservedWindowState: Equatable {
    var frame: CGRect?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var isVisible: Bool
    var isNativeFullscreen: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        ObservedWindowState(
            frame: nil,
            workspaceId: workspaceId,
            monitorId: monitorId,
            isVisible: true,
            isNativeFullscreen: false
        )
    }
}

struct DesiredWindowState: Equatable {
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var disposition: TrackedWindowMode?
    var floatingFrame: CGRect?
    var rescueEligible: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        disposition: TrackedWindowMode
    ) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: disposition,
            floatingFrame: nil,
            rescueEligible: disposition == .floating
        )
    }

    var summary: String {
        var parts: [String] = []
        if let workspaceId {
            parts.append("workspace=\(workspaceId.uuidString)")
        }
        if let disposition {
            parts.append("mode=\(disposition)")
        }
        if rescueEligible {
            parts.append("rescue=true")
        }
        return parts.joined(separator: ",")
    }
}

struct DisplayFingerprint: Hashable, Equatable, Codable, Sendable {
    let displayUUID: String?
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayUUID = monitor.displayUUID
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }

    private enum CodingKeys: String, CodingKey {
        case displayUUID, displayId, name, anchorPoint, frameSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try DisplayUUID.decode(from: container, forKey: .displayUUID)
        displayId = try container.decode(CGDirectDisplayID.self, forKey: .displayId)
        name = try container.decode(String.self, forKey: .name)
        anchorPoint = try container.decode(CGPoint.self, forKey: .anchorPoint)
        frameSize = try container.decode(CGSize.self, forKey: .frameSize)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayUUID, forKey: .displayUUID)
        try container.encode(displayId, forKey: .displayId)
        try container.encode(name, forKey: .name)
        try container.encode(anchorPoint, forKey: .anchorPoint)
        try container.encode(frameSize, forKey: .frameSize)
    }
}

struct TopologyProfile: Hashable, Equatable, Codable, Sendable {
    let displays: [DisplayFingerprint]

    init(monitors: [Monitor]) {
        self.init(sortedMonitors: Monitor.sortedByPosition(monitors))
    }

    init(sortedMonitors: [Monitor]) {
        displays = sortedMonitors.map(DisplayFingerprint.init)
    }
}

struct RestoreIntent: Equatable {
    let topologyProfile: TopologyProfile
    var workspaceId: WorkspaceDescriptor.ID
    var preferredMonitor: DisplayFingerprint?
    var floatingFrame: CGRect?
    var normalizedFloatingOrigin: CGPoint?
    var restoreToFloating: Bool
    var rescueEligible: Bool
    var niriPlacement: PersistedNiriPlacement? = nil
    var detachedNiriContainerSizingState: NiriContainerSizingState? = nil
}

enum ReplacementCorrelation {
    enum Reason: String, Equatable {
        case managedReplacement
        case nativeFullscreen
        case manualRekey
    }
}

struct PendingManagedFocusSnapshot: Equatable {
    var token: WindowToken?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var requestId: UInt64?

    static let empty = PendingManagedFocusSnapshot(
        token: nil,
        workspaceId: nil,
        monitorId: nil,
        requestId: nil
    )
}

struct MonitorSession: Equatable {
    var visibleWorkspaceId: WorkspaceDescriptor.ID?
    var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
}

struct FocusSessionSnapshot: Equatable {
    var focusedToken: WindowToken? = nil
    var pendingManagedFocus: PendingManagedFocusSnapshot = .empty
    var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
    var lastTiledFocusedToken: WindowToken? = nil
    var tiledFocusHistory: [WindowToken] = []
    var focusLease: FocusPolicyLease? = nil
    var isNonManagedFocusActive: Bool = false
    var nonManagedFocusToken: WindowToken? = nil
    var suppressedFocusToken: WindowToken? = nil
    var systemModalFocusToken: WindowToken? = nil
    var interactionMonitorId: Monitor.ID? = nil
    var previousInteractionMonitorId: Monitor.ID? = nil
}

extension FocusSessionSnapshot {
    @discardableResult
    mutating func recordTiledFocus(_ token: WindowToken) -> Bool {
        let previous = tiledFocusHistory
        tiledFocusHistory.removeAll { $0 == token }
        tiledFocusHistory.insert(token, at: 0)
        if tiledFocusHistory.count > 32 {
            tiledFocusHistory.removeLast(tiledFocusHistory.count - 32)
        }
        lastTiledFocusedToken = token
        return tiledFocusHistory != previous
    }

    @discardableResult
    mutating func rememberFocus(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        var changed = false
        if lastFocusedByWorkspace[workspaceId] != token {
            lastFocusedByWorkspace[workspaceId] = token
            changed = true
        }
        switch mode {
        case .tiling:
            if lastTiledFocusedByWorkspace[workspaceId] != token {
                lastTiledFocusedByWorkspace[workspaceId] = token
                changed = true
            }
        case .floating:
            if lastFloatingFocusedByWorkspace[workspaceId] != token {
                lastFloatingFocusedByWorkspace[workspaceId] = token
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    mutating func clearRememberedFocus(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> Bool {
        var changed = false

        if lastTiledFocusedToken == token {
            lastTiledFocusedToken = nil
            changed = true
        }
        if tiledFocusHistory.contains(token) {
            tiledFocusHistory.removeAll { $0 == token }
            changed = true
        }

        if let workspaceId {
            if lastTiledFocusedByWorkspace[workspaceId] == token {
                lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastFloatingFocusedByWorkspace[workspaceId] == token {
                lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastFocusedByWorkspace[workspaceId] == token {
                lastFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            return changed
        }

        for (id, rememberedToken) in lastTiledFocusedByWorkspace where rememberedToken == token {
            lastTiledFocusedByWorkspace[id] = nil
            changed = true
        }
        for (id, rememberedToken) in lastFloatingFocusedByWorkspace where rememberedToken == token {
            lastFloatingFocusedByWorkspace[id] = nil
            changed = true
        }
        for (id, rememberedToken) in lastFocusedByWorkspace where rememberedToken == token {
            lastFocusedByWorkspace[id] = nil
            changed = true
        }

        return changed
    }

    @discardableResult
    mutating func replaceRememberedFocus(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        var changed = false

        if lastTiledFocusedToken == oldToken {
            lastTiledFocusedToken = newToken
            changed = true
        }
        if tiledFocusHistory.contains(oldToken) {
            tiledFocusHistory = tiledFocusHistory.map { $0 == oldToken ? newToken : $0 }
            changed = true
        }

        for (workspaceId, token) in lastTiledFocusedByWorkspace where token == oldToken {
            lastTiledFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }
        for (workspaceId, token) in lastFloatingFocusedByWorkspace where token == oldToken {
            lastFloatingFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }
        for (workspaceId, token) in lastFocusedByWorkspace where token == oldToken {
            lastFocusedByWorkspace[workspaceId] = newToken
            changed = true
        }

        return changed
    }

    @discardableResult
    mutating func reconcileRememberedFocus(
        afterModeChangeOf token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID,
        to newMode: TrackedWindowMode
    ) -> Bool {
        var changed = false
        switch newMode {
        case .tiling:
            if lastFloatingFocusedByWorkspace[workspaceId] == token {
                lastFloatingFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
        case .floating:
            if lastTiledFocusedByWorkspace[workspaceId] == token {
                lastTiledFocusedByWorkspace[workspaceId] = nil
                changed = true
            }
            if lastTiledFocusedToken == token {
                lastTiledFocusedToken = nil
                changed = true
            }
            if tiledFocusHistory.contains(token) {
                tiledFocusHistory.removeAll { $0 == token }
                changed = true
            }
        }

        if focusedToken == token || pendingManagedFocus.token == token {
            changed = rememberFocus(token, in: workspaceId, mode: newMode) || changed
        }

        return changed
    }

    @discardableResult
    mutating func clearPendingManagedFocus() -> Bool {
        guard pendingManagedFocus != .empty else { return false }
        pendingManagedFocus = .empty
        return true
    }

    @discardableResult
    mutating func clearPendingManagedFocus(
        matching token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?
    ) -> Bool {
        let request = pendingManagedFocus
        let matchesToken = token.map { request.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { request.workspaceId == $0 } ?? true
        let matchesRequest = requestId.map { request.requestId == $0 } ?? (request.requestId == nil)
        guard matchesToken, matchesWorkspace, matchesRequest else { return false }
        return clearPendingManagedFocus()
    }
}

struct ReconcileWindowSnapshot: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let mode: TrackedWindowMode
    let lifecyclePhase: WindowLifecyclePhase
    let observedState: ObservedWindowState
    let desiredState: DesiredWindowState
    let restoreIntent: RestoreIntent?
    let interactionPolicy: WindowInteractionPolicy
}

struct ReconcileSnapshot: Equatable {
    let topologyProfile: TopologyProfile
    let focusSession: FocusSessionSnapshot
    let windows: [ReconcileWindowSnapshot]
    var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    var layouts: [WorkspaceDescriptor.ID: LayoutTopology] = [:]

    var focusedToken: WindowToken? {
        focusSession.focusedToken
    }

    var interactionMonitorId: Monitor.ID? {
        focusSession.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        focusSession.previousInteractionMonitorId
    }
}
