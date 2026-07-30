// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct NativeSpaceTopologySample: Equatable, Sendable {
    struct Display: Equatable, Sendable {
        let displayIdentifier: String
        let spaceIds: [UInt64]
        let currentSpaceId: UInt64
    }

    let displays: [Display]
    let activeSpaceId: UInt64
    let fullscreenSpaceIds: Set<UInt64>

    init?(topology: SpaceTopology) {
        guard !topology.displays.isEmpty else { return nil }

        let displays = topology.displays.map {
            Display(
                displayIdentifier: $0.displayIdentifier,
                spaceIds: $0.spaceIds.sorted(),
                currentSpaceId: $0.currentSpaceId
            )
        }.sorted { $0.displayIdentifier < $1.displayIdentifier }
        guard Set(displays.map(\.displayIdentifier)).count == displays.count else { return nil }

        var knownSpaceIds: Set<UInt64> = []
        for display in displays {
            guard !display.displayIdentifier.isEmpty,
                  !display.spaceIds.isEmpty,
                  display.currentSpaceId != 0,
                  display.spaceIds.contains(display.currentSpaceId),
                  Set(display.spaceIds).count == display.spaceIds.count
            else { return nil }
            let previousCount = knownSpaceIds.count
            knownSpaceIds.formUnion(display.spaceIds)
            guard knownSpaceIds.count == previousCount + display.spaceIds.count else { return nil }
        }
        guard topology.activeSpaceId == 0 || knownSpaceIds.contains(topology.activeSpaceId),
              topology.fullscreenSpaceIds.isSubset(of: knownSpaceIds)
        else { return nil }

        self.displays = displays
        activeSpaceId = topology.activeSpaceId
        fullscreenSpaceIds = topology.fullscreenSpaceIds
    }

    var inventorySpaceIds: Set<UInt64> {
        var spaceIds = Set(displays.map(\.currentSpaceId))
        if activeSpaceId != 0 {
            spaceIds.insert(activeSpaceId)
        }
        return spaceIds
    }

    func matchesExpectedDisplays(
        count: Int,
        displayUUIDs: Set<String>?,
        displayUUIDAliases: [String: String] = [:]
    ) -> Bool {
        guard displays.count == count else { return false }
        guard let displayUUIDs else { return true }
        let observedDisplayUUIDs = Set(
            displays.compactMap {
                DisplayUUID.canonical($0.displayIdentifier)
                    ?? displayUUIDAliases[$0.displayIdentifier]
            }
        )
        return observedDisplayUUIDs.count == displays.count
            && observedDisplayUUIDs == displayUUIDs
    }

    var topology: SpaceTopology {
        SpaceTopology(
            displays: displays.map {
                SpaceTopology.DisplaySpaces(
                    displayIdentifier: $0.displayIdentifier,
                    spaceIds: $0.spaceIds,
                    currentSpaceId: $0.currentSpaceId
                )
            },
            activeSpaceId: activeSpaceId,
            fullscreenSpaceIds: fullscreenSpaceIds,
            windowSpace: [:]
        )
    }
}

struct NativeSpaceInventoryStabilityGate {
    static let globalFallbackObservationCount = 10

    private var previousSample: NativeSpaceTopologySample?
    private var observationCount = 0
    private var requestedGlobalFallback = false

    var usesRetryInterval: Bool {
        observationCount >= Self.globalFallbackObservationCount
    }

    mutating func observe(_ sample: NativeSpaceTopologySample?) -> NativeSpaceInventoryStabilityObservation {
        guard let sample else {
            previousSample = nil
            return pendingObservation()
        }
        guard previousSample == sample else {
            previousSample = sample
            return pendingObservation(topologyToApply: sample)
        }
        return .init(authoritativeTopologyToApply: sample)
    }

    private mutating func pendingObservation(
        topologyToApply: NativeSpaceTopologySample? = nil
    ) -> NativeSpaceInventoryStabilityObservation {
        observationCount += 1
        let requestsGlobalFallback =
            !requestedGlobalFallback
                && observationCount >= Self.globalFallbackObservationCount
        requestedGlobalFallback = requestedGlobalFallback || requestsGlobalFallback
        return .init(
            topologyToApply: topologyToApply,
            requestsGlobalFallback: requestsGlobalFallback
        )
    }
}

struct NativeSpaceInventoryStabilityObservation: Equatable, Sendable {
    let topologyToApply: NativeSpaceTopologySample?
    let authoritativeTopologyToApply: NativeSpaceTopologySample?
    let requestsGlobalFallback: Bool

    init(
        topologyToApply: NativeSpaceTopologySample? = nil,
        authoritativeTopologyToApply: NativeSpaceTopologySample? = nil,
        requestsGlobalFallback: Bool = false
    ) {
        self.topologyToApply = topologyToApply
        self.authoritativeTopologyToApply = authoritativeTopologyToApply
        self.requestsGlobalFallback = requestsGlobalFallback
    }
}

enum NativeSpaceWindowMembershipUpdate: Equatable, Sendable {
    case carryForwardKnown
    case query(preservesKnownOnMissing: Bool)
}

@MainActor
final class SpaceTracker {
    weak var controller: WMController?

    init(controller: WMController) {
        self.controller = controller
    }

    func start() {
        refresh()
    }

    @discardableResult
    func refresh() -> NativeSpaceTopologySample? {
        guard let sample = currentTopologySample() else { return nil }
        refresh(using: sample)
        return sample
    }

    func currentTopologySample() -> NativeSpaceTopologySample? {
        guard let controller else { return nil }
        let managed = SkyLight.shared.managedSpaces()
        guard !managed.isEmpty else { return nil }

        var topology = SpaceTopology()
        topology.displays = managed.map {
            SpaceTopology.DisplaySpaces(
                displayIdentifier: $0.displayIdentifier,
                spaceIds: $0.spaceIds,
                currentSpaceId: $0.currentSpaceId
            )
        }
        topology.fullscreenSpaceIds = managed.reduce(into: Set<UInt64>()) { $0.formUnion($1.fullscreenSpaceIds) }
        topology.activeSpaceId = SkyLight.shared.activeSpace() ?? 0
        guard let sample = NativeSpaceTopologySample(topology: topology) else { return nil }
        let monitors = controller.workspaceManager.monitors
        guard !monitors.isEmpty else { return nil }
        let displayUUIDs = Set(monitors.compactMap(\.displayUUID))
        let expectedDisplayUUIDs = displayUUIDs.count == monitors.count
            ? displayUUIDs
            : nil
        var displayUUIDAliases: [String: String] = [:]
        for monitor in monitors {
            guard let displayUUID = monitor.displayUUID else { continue }
            displayUUIDAliases[String(monitor.displayId)] = displayUUID
        }
        if let mainMonitor = monitors.first(where: \.isMain),
           let displayUUID = mainMonitor.displayUUID
        {
            displayUUIDAliases["Main"] = displayUUID
        }
        return sample.matchesExpectedDisplays(
            count: monitors.count,
            displayUUIDs: expectedDisplayUUIDs,
            displayUUIDAliases: displayUUIDAliases
        ) ? sample : nil
    }

    func refresh(
        using sample: NativeSpaceTopologySample,
        windowMembershipUpdate: NativeSpaceWindowMembershipUpdate = .query(
            preservesKnownOnMissing: false
        ),
        reconcilesNativeFullscreen: Bool = true,
        spaceIdsForWindow: (UInt32) -> [UInt64] = { SkyLight.shared.spacesForWindow($0) }
    ) {
        guard let controller else { return }
        var topology = sample.topology
        let previousWindowSpace = controller.workspaceManager.spaceTopology.windowSpace
        switch windowMembershipUpdate {
        case .carryForwardKnown:
            for entry in controller.workspaceManager.allEntries() {
                let windowId = entry.windowId
                guard windowId > 0,
                      let previousSpaceId = previousWindowSpace[windowId],
                      topology.isKnownSpace(previousSpaceId)
                else { continue }
                topology.windowSpace[windowId] = previousSpaceId
            }
        case let .query(preservesKnownOnMissing):
            for entry in controller.workspaceManager.allEntries() {
                let windowId = entry.windowId
                guard windowId > 0 else { continue }
                let candidates = spaceIdsForWindow(UInt32(windowId))
                if let spaceId = topology.selectWindowSpace(from: candidates) {
                    topology.windowSpace[windowId] = spaceId
                } else if preservesKnownOnMissing,
                          let previousSpaceId = previousWindowSpace[windowId],
                          topology.isKnownSpace(previousSpaceId)
                {
                    topology.windowSpace[windowId] = previousSpaceId
                }
            }
        }
        controller.workspaceManager.commitSpaceTopology(topology)
        if reconcilesNativeFullscreen {
            controller.workspaceManager.reconcileNativeFullscreenWithTopology()
        }
    }

    func noteWindowSpace(windowId: Int, spaceId: UInt64) {
        guard let controller, spaceId != 0 else { return }
        guard let entry = controller.workspaceManager.entry(forWindowId: windowId) else { return }
        var topology = controller.workspaceManager.spaceTopology
        if topology.activeSpaceId == 0 || !topology.isKnownSpace(spaceId) {
            topology = refreshedTopology(preserving: topology) ?? topology
        }
        topology.windowSpace[windowId] = spaceId
        controller.workspaceManager.commitSpaceTopology(topology)
        controller.workspaceManager.reconcileNativeFullscreenWithTopology(for: entry.token)
    }

    private func refreshedTopology(preserving topology: SpaceTopology) -> SpaceTopology? {
        let managed = SkyLight.shared.managedSpaces()
        guard !managed.isEmpty else { return nil }

        var refreshed = topology
        refreshed.displays = managed.map {
            SpaceTopology.DisplaySpaces(
                displayIdentifier: $0.displayIdentifier,
                spaceIds: $0.spaceIds,
                currentSpaceId: $0.currentSpaceId
            )
        }
        refreshed.fullscreenSpaceIds = managed.reduce(into: Set<UInt64>()) {
            $0.formUnion($1.fullscreenSpaceIds)
        }
        refreshed.activeSpaceId = SkyLight.shared.activeSpace() ?? topology.activeSpaceId
        return refreshed
    }
}
