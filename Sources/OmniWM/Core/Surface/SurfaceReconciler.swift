// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DesiredBorderSurface: Equatable {
    var token: WindowToken
    var frame: CGRect
    var config: BorderConfig

    var windowId: Int {
        token.windowId
    }
}

struct DesiredBarSurface: Equatable {
    var monitor: Monitor
    var visible: Bool
    var snapshot: WorkspaceBarSnapshot
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?
    var tabRails: [TabRailInfo] = []
    var placeholders: [NativeFullscreenPlaceholderUpdate] = []
    var bars: [DesiredBarSurface] = []

    static let empty = DesiredSurfaceScene()
}

enum SurfaceDerivation {
    private enum BorderFramePolicy {
        case complete
        case animation(previous: DesiredBorderSurface?)
    }

    @MainActor
    static func derive(world: WorldView) -> DesiredSurfaceScene {
        guard world.hasStartedServices else { return .empty }
        return DesiredSurfaceScene(
            border: deriveBorder(world: world),
            tabRails: world.tabRailInfos(),
            placeholders: world.nativeFullscreenPlaceholders(),
            bars: world.barSurfaces()
        )
    }

    @MainActor
    static func deriveBorder(world: WorldView) -> DesiredBorderSurface? {
        deriveBorder(world: world, framePolicy: .complete)
    }

    @MainActor
    static func deriveAnimationBorder(
        world: WorldView,
        previous: DesiredBorderSurface?
    ) -> DesiredBorderSurface? {
        deriveBorder(world: world, framePolicy: .animation(previous: previous))
    }

    @MainActor
    private static func deriveBorder(
        world: WorldView,
        framePolicy: BorderFramePolicy
    ) -> DesiredBorderSurface? {
        let config = world.borderConfig
        guard config.enabled else { return nil }
        guard let token = world.renderableFocusToken else { return nil }
        guard !world.isOwnedWindow(windowId: token.windowId) else { return nil }
        guard !world.hasPendingNativeFullscreenTransition else { return nil }
        guard world.systemModalFocusToken != token else { return nil }

        if let entry = world.entry(for: token) {
            guard world.suppressedFocusToken != token,
                  !world.isAppFullscreenActive,
                  !world.isWindowFullscreenInLayout(token),
                  world.isManagedWindowDisplayable(entry.token),
                  world.isWorkspaceVisible(entry.workspaceId),
                  entry.interactionPolicy.mayBorder
            else {
                return nil
            }
            guard let frame = borderFrame(
                for: token,
                entry: entry,
                world: world,
                policy: framePolicy
            ),
                frame.width > 0, frame.height > 0
            else {
                return nil
            }
            return DesiredBorderSurface(token: entry.token, frame: frame, config: config)
        }

        guard world.isNonManagedFocusActive else { return nil }
        guard let frame = borderFrame(
            for: token,
            entry: nil,
            world: world,
            policy: framePolicy
        ) else {
            return nil
        }
        return DesiredBorderSurface(token: token, frame: frame, config: config)
    }

    @MainActor
    private static func borderFrame(
        for token: WindowToken,
        entry: WindowState?,
        world: WorldView,
        policy: BorderFramePolicy
    ) -> CGRect? {
        switch policy {
        case .complete:
            if let entry {
                return world.borderFrame(for: entry)
            }
            return world.observedWindowBounds(windowId: token.windowId)
        case let .animation(previous):
            if let entry, let cached = world.cachedBorderFrame(for: entry) {
                return cached
            }
            guard previous?.token == token else { return nil }
            return previous?.frame
        }
    }
}

@MainActor
final class SurfaceReconciler {
    private weak var controller: WMController?
    private(set) var reconcileScheduled = false
    private(set) var forceOrderingOnNextReconcile = false
    private let borderApplier = BorderSurfaceApplier()
    private(set) var appliedScene = DesiredSurfaceScene.empty

    init(controller: WMController) {
        self.controller = controller
    }

    func noteWorldChanged() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.flushScheduledReconcile()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    func noteRestackOccurred() {
        forceOrderingOnNextReconcile = true
        noteWorldChanged()
    }

    func reconcileNow() {
        runFullReconcile()
    }

    func reconcileAnimationTick() {
        guard let controller else { return }
        let world = WorldView(controller: controller)
        let desiredBorder = world.hasStartedServices
            ? SurfaceDerivation.deriveAnimationBorder(world: world, previous: appliedScene.border)
            : nil
        let outcome = borderApplier.apply(
            desiredBorder,
            forceOrdering: false,
            refreshCornerRadii: false
        )
        appliedScene.border = outcome.didApply ? desiredBorder : nil
    }

    func handleVerifiedFrameApplySuccess(_ result: AXFrameApplyResult) {
        guard let controller else { return }
        let token = WindowToken(pid: result.pid, windowId: result.windowId)
        guard controller.workspaceManager.renderableFocusToken == token else { return }
        noteWorldChanged()
    }

    func cleanup() {
        reconcileScheduled = false
        forceOrderingOnNextReconcile = false
        borderApplier.cleanup()
        appliedScene = .empty
    }

    private func flushScheduledReconcile() {
        guard reconcileScheduled else { return }
        reconcileNow()
    }

    private func runFullReconcile() {
        reconcileScheduled = false
        let forceOrdering = forceOrderingOnNextReconcile
        forceOrderingOnNextReconcile = false
        guard let controller else { return }
        let world = WorldView(controller: controller)
        let desired = SurfaceDerivation.derive(world: world)
        let refreshCornerRadii = desired.border.map {
            !controller.axManager.hasPendingFrameWrite(for: $0.windowId)
        } ?? true
        let outcome = applyFull(
            desired,
            on: controller,
            forceOrdering: forceOrdering,
            refreshCornerRadii: refreshCornerRadii
        )
        if outcome.needsCornerRadiiRetry {
            noteWorldChanged()
        }
    }

    private func applyFull(
        _ desired: DesiredSurfaceScene,
        on controller: WMController,
        forceOrdering: Bool,
        refreshCornerRadii: Bool
    ) -> BorderSurfaceApplyResult {
        controller.workspaceBarManager.apply(desired.bars)
        if desired.bars != appliedScene.bars {
            controller.publishWorkspaceDataChanged()
        }
        let borderOutcome = borderApplier.apply(
            desired.border,
            forceOrdering: forceOrdering,
            refreshCornerRadii: refreshCornerRadii
        )
        if desired.tabRails != appliedScene.tabRails || forceOrdering {
            controller.tabRailManager.updateRails(desired.tabRails, forceOrdering: forceOrdering)
        }
        if desired.placeholders != appliedScene.placeholders {
            controller.nativeFullscreenPlaceholderManager.apply(desired.placeholders)
        }
        appliedScene = desired
        if !borderOutcome.didApply {
            appliedScene.border = nil
        }
        return borderOutcome
    }
}
