// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

enum SurfaceKind: String, CaseIterable, Hashable, Sendable {
    case border
    case parkingEdgeMask
    case workspaceBar
    case overview
    case nativeFullscreenPlaceholder
    case tabRail
    case dragGhost
    case utility
    case quake
    case launchOverlay
    case secureInputIndicator
    case systemStats
    case hiddenBarPanel
    case statusPanel
}

enum HitTestPolicy: Equatable {
    case interactive
    case frontmostInteractive
    case passthrough
}

enum CapturePolicy: Equatable {
    case included
    case excluded
}

struct SurfaceFrontmostInteractiveResolver {
    static let appKit = SurfaceFrontmostInteractiveResolver { window in
        guard let app = NSApp else { return false }
        return window.isKeyWindow
            || window.isMainWindow
            || app.keyWindow === window
            || app.mainWindow === window
    }

    let isFrontmost: @MainActor (NSWindow) -> Bool

    init(_ isFrontmost: @escaping @MainActor (NSWindow) -> Bool) {
        self.isFrontmost = isFrontmost
    }
}

struct SurfacePolicy: Equatable {
    let kind: SurfaceKind
    let hitTestPolicy: HitTestPolicy
    let capturePolicy: CapturePolicy
    let suppressesManagedFocusRecovery: Bool
}

struct SurfaceSceneRuntimeSnapshot: Equatable, Sendable {
    var total = 0
    var live = 0
    var dead = 0
    var numberBacked = 0
    var reverseEntries = 0
    var orphanReverseEntries = 0
    var highWater = 0
    var byKind: [SurfaceKind: Int] = [:]
}

@MainActor
final class SurfaceScene {
    struct SurfaceNode {
        let id: String
        let policy: SurfacePolicy
        weak var window: NSWindow?
        var windowObjectIdentifier: ObjectIdentifier?
        var windowNumber: Int?
        var frameProvider: (@MainActor () -> CGRect?)?
        var visibilityProvider: (@MainActor () -> Bool)?
    }

    private var nodesByID: [String: SurfaceNode] = [:]
    private var windowIDByObject: [ObjectIdentifier: String] = [:]
    private var surfaceIDsByWindowNumber: [Int: Set<String>] = [:]
    private let frontmostInteractiveResolver: SurfaceFrontmostInteractiveResolver
    private var runtimeMetricsActive = false
    private var runtimeHighWater = 0

    init(frontmostInteractiveResolver: SurfaceFrontmostInteractiveResolver = .appKit) {
        self.frontmostInteractiveResolver = frontmostInteractiveResolver
    }

    func register(window: NSWindow, node: SurfaceNode) {
        let objectIdentifier = ObjectIdentifier(window)
        if let existingId = windowIDByObject[objectIdentifier], existingId != node.id {
            unregister(id: existingId)
        }
        unregister(id: node.id)

        var node = node
        node.window = window
        node.windowObjectIdentifier = objectIdentifier
        if window.windowNumber > 0 {
            node.windowNumber = window.windowNumber
        }
        nodesByID[node.id] = node
        windowIDByObject[objectIdentifier] = node.id
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            surfaceIDsByWindowNumber[windowNumber, default: []].insert(node.id)
        }
        recordRuntimeHighWater()
    }

    func registerWindowNumber(node: SurfaceNode) {
        unregister(id: node.id)
        var node = node
        node.windowObjectIdentifier = nil
        nodesByID[node.id] = node
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            surfaceIDsByWindowNumber[windowNumber, default: []].insert(node.id)
        }
        recordRuntimeHighWater()
    }

    func unregister(window: NSWindow) {
        unregister(id: windowIDByObject[ObjectIdentifier(window)])
    }

    func unregister(id: String?) {
        guard let id, let node = nodesByID.removeValue(forKey: id) else { return }
        if let objectIdentifier = node.windowObjectIdentifier,
           windowIDByObject[objectIdentifier] == id
        {
            windowIDByObject.removeValue(forKey: objectIdentifier)
        }
        if let windowNumber = node.windowNumber, windowNumber > 0 {
            var ids = surfaceIDsByWindowNumber[windowNumber] ?? []
            ids.remove(id)
            if ids.isEmpty {
                surfaceIDsByWindowNumber.removeValue(forKey: windowNumber)
            } else {
                surfaceIDsByWindowNumber[windowNumber] = ids
            }
        }
    }

    func beginRuntimeCapture() {
        runtimeHighWater = nodesByID.count
        runtimeMetricsActive = true
    }

    func endRuntimeCapture() {
        runtimeMetricsActive = false
    }

    func runtimeSnapshot() -> SurfaceSceneRuntimeSnapshot {
        let nodeIds = Set(nodesByID.keys)
        let numberReverseEntries = surfaceIDsByWindowNumber.values.reduce(0) { $0 + $1.count }
        let live = nodesByID.values.count(where: {
            $0.window != nil && $0.windowObjectIdentifier != nil
        })
        let dead = nodesByID.values.count(where: {
            $0.window == nil && $0.windowObjectIdentifier != nil
        })
        let numberBacked = nodesByID.values.count(where: {
            $0.windowObjectIdentifier == nil
        })
        var byKind: [SurfaceKind: Int] = [:]
        for node in nodesByID.values {
            byKind[node.policy.kind, default: 0] += 1
        }
        let orphanObjectEntries = windowIDByObject.values.count(where: { !nodeIds.contains($0) })
        let orphanNumberEntries = surfaceIDsByWindowNumber.values.reduce(0) { count, ids in
            count + ids.count(where: { !nodeIds.contains($0) })
        }
        return SurfaceSceneRuntimeSnapshot(
            total: nodesByID.count,
            live: live,
            dead: dead,
            numberBacked: numberBacked,
            reverseEntries: windowIDByObject.count + numberReverseEntries,
            orphanReverseEntries: orphanObjectEntries + orphanNumberEntries,
            highWater: max(runtimeHighWater, nodesByID.count),
            byKind: byKind
        )
    }

    private func recordRuntimeHighWater() {
        guard runtimeMetricsActive else { return }
        runtimeHighWater = max(runtimeHighWater, nodesByID.count)
    }

    func contains(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windowIDByObject[ObjectIdentifier(window)] != nil
    }

    func contains(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        if let ids = surfaceIDsByWindowNumber[windowNumber] {
            var containsLiveNode = false
            for id in ids {
                guard let node = nodesByID[id] else { continue }
                if node.windowObjectIdentifier == nil || node.window != nil {
                    containsLiveNode = true
                } else {
                    unregister(id: id)
                }
            }
            if containsLiveNode {
                return true
            }
        }

        let matchingIDs = nodesByID.compactMap { id, node -> String? in
            guard node.window?.windowNumber == windowNumber else { return nil }
            return id
        }
        guard !matchingIDs.isEmpty else { return false }

        for id in matchingIDs {
            guard var node = nodesByID[id] else { continue }
            node.windowNumber = windowNumber
            nodesByID[id] = node
            surfaceIDsByWindowNumber[windowNumber, default: []].insert(id)
        }
        return true
    }

    func containsInteractive(point: CGPoint) -> Bool {
        nodesByID.values.contains { node in
            guard node.policy.hitTestPolicy != .passthrough,
                  isVisible(node)
            else {
                return false
            }
            switch node.policy.hitTestPolicy {
            case .interactive:
                break
            case .frontmostInteractive:
                guard let window = node.window,
                      isFrontmostInteractiveWindow(window)
                else {
                    return false
                }
            case .passthrough:
                break
            }
            return resolvedFrame(for: node)?.contains(point) == true
        }
    }

    var hasFrontmostSuppressingWindow: Bool {
        guard let app = NSApp else { return false }
        let frontmostWindows = [app.keyWindow, app.mainWindow].compactMap { $0 }
        return frontmostWindows.contains { window in
            guard let node = node(for: window) else { return false }
            return node.policy.suppressesManagedFocusRecovery && isVisible(node)
        }
    }

    var hasVisibleSuppressingWindow: Bool {
        containsVisibleNode { $0.policy.suppressesManagedFocusRecovery }
    }

    func isCaptureEligible(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        guard let ids = surfaceIDsByWindowNumber[windowNumber], !ids.isEmpty else { return true }
        return !ids.compactMap({ nodesByID[$0] }).contains {
            ($0.windowObjectIdentifier == nil || $0.window != nil)
                && $0.policy.capturePolicy == .excluded
        }
    }

    func visibleSurfaceIDs(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [String] {
        matchingVisibleNodes(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
        .map(\.id)
        .sorted()
    }

    func visibleWindows(
        kind: SurfaceKind? = nil,
        capturePolicy: CapturePolicy? = nil,
        suppressesManagedFocusRecovery: Bool? = nil
    ) -> [NSWindow] {
        matchingVisibleNodes(
            kind: kind,
            capturePolicy: capturePolicy,
            suppressesManagedFocusRecovery: suppressesManagedFocusRecovery
        )
        .compactMap(\.window)
        .sorted { lhs, rhs in
            lhs.windowNumber < rhs.windowNumber
        }
    }

    func reset() {
        nodesByID.removeAll()
        windowIDByObject.removeAll()
        surfaceIDsByWindowNumber.removeAll()
    }

    private func node(for window: NSWindow) -> SurfaceNode? {
        guard let id = windowIDByObject[ObjectIdentifier(window)] else { return nil }
        return nodesByID[id]
    }

    private func isFrontmostInteractiveWindow(_ window: NSWindow) -> Bool {
        frontmostInteractiveResolver.isFrontmost(window)
    }

    private func containsVisibleNode(where predicate: (SurfaceNode) -> Bool) -> Bool {
        nodesByID.values.contains { isVisible($0) && predicate($0) }
    }

    private var visibleNodes: [SurfaceNode] {
        nodesByID.values.filter(isVisible)
    }

    private func matchingVisibleNodes(
        kind: SurfaceKind?,
        capturePolicy: CapturePolicy?,
        suppressesManagedFocusRecovery: Bool?
    ) -> [SurfaceNode] {
        visibleNodes.filter { node in
            guard kind.map({ $0 == node.policy.kind }) ?? true else { return false }
            guard capturePolicy.map({ $0 == node.policy.capturePolicy }) ?? true else { return false }
            guard suppressesManagedFocusRecovery.map({ $0 == node.policy.suppressesManagedFocusRecovery }) ?? true
            else {
                return false
            }
            return true
        }
    }

    private func isVisible(_ node: SurfaceNode) -> Bool {
        if let visibilityProvider = node.visibilityProvider {
            return visibilityProvider()
        }
        if let window = node.window {
            return window.isVisible
        }
        if node.windowObjectIdentifier != nil {
            return false
        }
        return node.windowNumber != nil
    }

    private func resolvedFrame(for node: SurfaceNode) -> CGRect? {
        if let frameProvider = node.frameProvider {
            return frameProvider()
        }
        return node.window?.frame
    }

    struct VisibleSurfaceInfo {
        let id: String
        let kind: SurfaceKind
        let hitTestPolicy: HitTestPolicy
        let capturePolicy: CapturePolicy
        let suppressesManagedFocusRecovery: Bool
        let frame: CGRect?
        let window: NSWindow?
    }

    func visibleSurfaceInfos() -> [VisibleSurfaceInfo] {
        visibleNodes.map { node in
            VisibleSurfaceInfo(
                id: node.id,
                kind: node.policy.kind,
                hitTestPolicy: node.policy.hitTestPolicy,
                capturePolicy: node.policy.capturePolicy,
                suppressesManagedFocusRecovery: node.policy.suppressesManagedFocusRecovery,
                frame: resolvedFrame(for: node),
                window: node.window
            )
        }
    }

    func containsGeometric(point: CGPoint) -> Bool {
        nodesByID.values.contains { node in
            guard node.policy.hitTestPolicy != .passthrough,
                  isVisible(node)
            else {
                return false
            }
            return resolvedFrame(for: node)?.contains(point) == true
        }
    }
}
