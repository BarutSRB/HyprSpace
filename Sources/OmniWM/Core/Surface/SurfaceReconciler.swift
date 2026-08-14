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

struct ParkingEdgeMaskKey: Hashable {
    enum Side: String, Hashable {
        case left
        case right
    }

    let monitorId: Monitor.ID
    let side: Side
}

struct DesiredParkingEdgeMask: Equatable {
    let key: ParkingEdgeMaskKey
    let frame: CGRect
}

struct DesiredSurfaceScene: Equatable {
    var border: DesiredBorderSurface?
    var tabRails: [TabRailInfo] = []
    var placeholders: [NativeFullscreenPlaceholderUpdate] = []
    var bars: [DesiredBarSurface] = []
    var parkingEdgeMasks: [DesiredParkingEdgeMask] = []

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
            bars: world.barSurfaces(),
            parkingEdgeMasks: deriveParkingEdgeMasks(monitors: world.monitors)
        )
    }

    static func deriveParkingEdgeMasks(monitors: [Monitor]) -> [DesiredParkingEdgeMask] {
        let width: CGFloat = 1
        var masks: [DesiredParkingEdgeMask] = []
        masks.reserveCapacity(monitors.count * 2)

        for monitor in monitors {
            let frame = monitor.visibleFrame
            guard !frame.isNull,
                  !frame.isInfinite,
                  frame.width >= width * 2,
                  frame.height > 0
            else { continue }

            masks.append(
                DesiredParkingEdgeMask(
                    key: ParkingEdgeMaskKey(monitorId: monitor.id, side: .left),
                    frame: CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
                )
            )
            masks.append(
                DesiredParkingEdgeMask(
                    key: ParkingEdgeMaskKey(monitorId: monitor.id, side: .right),
                    frame: CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
                )
            )
        }

        return masks
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
        guard !world.hasPendingNativeFullscreenTransition(for: token) else { return nil }
        guard world.systemModalFocusToken != token else { return nil }

        if let entry = world.entry(for: token) {
            guard world.suppressedFocusToken != token,
                  !world.hasPendingNativeFullscreenTransition(in: entry.workspaceId),
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

private struct AcceptedNativeFullscreenSlotProjection {
    let displayId: CGDirectDisplayID
    let displayContext: NativeFullscreenCardDisplayContext
    let slots: [WindowToken: NativeFullscreenSlotProjection]
}

@MainActor
final class SurfaceReconciler {
    private weak var controller: WMController?
    private(set) var reconcileScheduled = false
    private(set) var forceOrderingOnNextReconcile = false
    private let borderApplier = BorderSurfaceApplier()
    private let parkingEdgeMaskManager = ParkingEdgeMaskManager()
    private var nativeFullscreenDescriptorsByOriginalToken: [
        WindowToken: NativeFullscreenPlaceholderUpdate
    ] = [:]
    private var nativeFullscreenSlotsByWorkspace: [
        WorkspaceDescriptor.ID: AcceptedNativeFullscreenSlotProjection
    ] = [:]
    private(set) var appliedScene = DesiredSurfaceScene.empty

    var nativeFullscreenProjectedWorkspaceIds: Set<WorkspaceDescriptor.ID> {
        Set(nativeFullscreenSlotsByWorkspace.keys)
    }

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

    func applyAcceptedNativeFullscreenSlots(
        _ slots: [WindowToken: NativeFullscreenSlotProjection],
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        displayContext: NativeFullscreenCardDisplayContext
    ) {
        guard let controller else { return }
        guard controller.hasStartedServices else {
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return
        }
        guard controller.workspaceManager.descriptor(for: workspaceId) != nil else {
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return
        }
        guard controller.workspaceManager.monitor(for: workspaceId)?.displayId == displayId else { return }

        nativeFullscreenSlotsByWorkspace[workspaceId] = AcceptedNativeFullscreenSlotProjection(
            displayId: displayId,
            displayContext: displayContext,
            slots: slots
        )

        var needsManagerApply = false
        for index in appliedScene.placeholders.indices {
            let previous = appliedScene.placeholders[index]
            guard previous.workspaceId == workspaceId,
                  let descriptor = nativeFullscreenDescriptorsByOriginalToken[previous.originalToken]
            else { continue }

            let next = resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
            guard next != previous else { continue }

            appliedScene.placeholders[index] = next
            if previous.visible,
               next.visible,
               (previous.frame != next.frame || previous.displayContext != next.displayContext)
            {
                controller.nativeFullscreenPlaceholderManager.moveForAnimation(next)
            } else if previous.visible != next.visible {
                needsManagerApply = true
            }
        }

        if needsManagerApply {
            controller.nativeFullscreenPlaceholderManager.apply(appliedScene.placeholders)
        }
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
        parkingEdgeMaskManager.removeAll()
        nativeFullscreenDescriptorsByOriginalToken.removeAll()
        nativeFullscreenSlotsByWorkspace.removeAll()
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
        if !world.hasStartedServices {
            nativeFullscreenSlotsByWorkspace.removeAll(keepingCapacity: true)
        } else {
            let staleWorkspaceIds = nativeFullscreenSlotsByWorkspace.keys.filter {
                controller.workspaceManager.descriptor(for: $0) == nil
            }
            for workspaceId in staleWorkspaceIds {
                nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            }
        }
        var desired = SurfaceDerivation.derive(world: world)
        nativeFullscreenDescriptorsByOriginalToken.removeAll(keepingCapacity: true)
        for descriptor in desired.placeholders {
            nativeFullscreenDescriptorsByOriginalToken[descriptor.originalToken] = descriptor
        }
        desired.placeholders = desired.placeholders.map { descriptor in
            let previous = appliedScene.placeholders.first {
                $0.originalToken == descriptor.originalToken
            }
            return resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
        }
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
        if desired.placeholders != appliedScene.placeholders || forceOrdering {
            controller.nativeFullscreenPlaceholderManager.apply(desired.placeholders, forceOrdering: forceOrdering)
        }
        parkingEdgeMaskManager.apply(desired.parkingEdgeMasks)
        appliedScene = desired
        if !borderOutcome.didApply {
            appliedScene.border = nil
        }
        return borderOutcome
    }

    private func resolvedNativeFullscreenPlaceholder(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        previous: NativeFullscreenPlaceholderUpdate?,
        controller: WMController
    ) -> NativeFullscreenPlaceholderUpdate {
        let workspaceManager = controller.workspaceManager
        guard let record = workspaceManager.nativeFullscreenRecord(originalToken: descriptor.originalToken),
              record.originalToken == descriptor.originalToken,
              record.workspaceId == descriptor.workspaceId
        else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: descriptor.currentToken,
                selected: descriptor.selected,
                previous: previous
            )
        }

        let currentToken = record.currentToken
        let selected = workspaceManager.focusedToken == currentToken
            || workspaceManager.pendingFocusedToken == currentToken
        guard record.transition == .suspended,
              workspaceManager.layoutReason(for: currentToken) == .nativeFullscreen
        else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        let descriptorIsCurrent = descriptor.currentToken == currentToken
        let lifecycleVisible = if descriptorIsCurrent {
            descriptor.visible
        } else {
            previous?.visible == true
        }

        guard lifecycleVisible else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }

        guard let projection = nativeFullscreenSlotsByWorkspace[descriptor.workspaceId] else {
            return retainedNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        guard workspaceManager.monitor(for: descriptor.workspaceId)?.displayId == projection.displayId else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        guard let slot = projection.slots[descriptor.originalToken] else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        guard slot.currentToken == currentToken else {
            return retainedNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }

        return NativeFullscreenPlaceholderUpdate(
            originalToken: descriptor.originalToken,
            currentToken: currentToken,
            workspaceId: descriptor.workspaceId,
            frame: slot.frame,
            displayContext: projection.displayContext,
            selected: selected,
            visible: slot.visible
        )
    }

    private func retainedNativeFullscreenPlaceholder(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        currentToken: WindowToken,
        selected: Bool,
        previous: NativeFullscreenPlaceholderUpdate?
    ) -> NativeFullscreenPlaceholderUpdate {
        guard let previous, previous.visible else {
            return hiddenNativeFullscreenPlaceholder(
                descriptor,
                currentToken: currentToken,
                selected: selected,
                previous: previous
            )
        }
        return NativeFullscreenPlaceholderUpdate(
            originalToken: descriptor.originalToken,
            currentToken: currentToken,
            workspaceId: descriptor.workspaceId,
            frame: previous.frame,
            displayContext: previous.displayContext,
            selected: selected,
            visible: true
        )
    }

    private func hiddenNativeFullscreenPlaceholder(
        _ descriptor: NativeFullscreenPlaceholderUpdate,
        currentToken: WindowToken,
        selected: Bool,
        previous: NativeFullscreenPlaceholderUpdate?
    ) -> NativeFullscreenPlaceholderUpdate {
        NativeFullscreenPlaceholderUpdate(
            originalToken: descriptor.originalToken,
            currentToken: currentToken,
            workspaceId: descriptor.workspaceId,
            frame: previous?.frame ?? .zero,
            displayContext: previous?.displayContext,
            selected: selected,
            visible: false
        )
    }
}
