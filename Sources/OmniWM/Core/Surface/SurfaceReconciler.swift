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
    let displayContext: NativeFullscreenDisplayContext
    let slots: [WindowToken: NativeFullscreenSlotProjection]
}

private struct NativeFullscreenPlaceholderResolution {
    let update: NativeFullscreenPlaceholderUpdate
    let reason: NativeFullscreenPlaceholderTrace.Reason
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

    func nativeFullscreenDiagnosticsSnapshot() -> NativeFullscreenSurfaceDiagnosticsSnapshot {
        var acceptedSlots: [NativeFullscreenAcceptedSlotDiagnostics] = []
        acceptedSlots.reserveCapacity(nativeFullscreenSlotsByWorkspace.values.reduce(0) { $0 + $1.slots.count })
        for (workspaceId, projection) in nativeFullscreenSlotsByWorkspace {
            for (originalToken, slot) in projection.slots {
                acceptedSlots.append(
                    NativeFullscreenAcceptedSlotDiagnostics(
                        originalToken: originalToken,
                        currentToken: slot.currentToken,
                        workspaceId: workspaceId,
                        displayId: projection.displayId,
                        frame: slot.frame,
                        visible: slot.visible,
                        workingFrame: projection.displayContext.workingFrame,
                        scale: projection.displayContext.scale
                    )
                )
            }
        }
        let descriptors = nativeFullscreenDescriptorsByOriginalToken.values.sorted {
            ($0.originalToken.pid, $0.originalToken.windowId)
                < ($1.originalToken.pid, $1.originalToken.windowId)
        }
        var appliedCounts: [WindowToken: Int] = [:]
        for applied in appliedScene.placeholders {
            appliedCounts[applied.originalToken, default: 0] += 1
        }
        return NativeFullscreenSurfaceDiagnosticsSnapshot(
            descriptors: descriptors,
            acceptedProjections: nativeFullscreenSlotsByWorkspace.map { workspaceId, projection in
                NativeFullscreenAcceptedProjectionDiagnostics(
                    workspaceId: workspaceId,
                    displayId: projection.displayId,
                    workingFrame: projection.displayContext.workingFrame,
                    scale: projection.displayContext.scale,
                    slotCount: projection.slots.count
                )
            }
            .sorted { $0.workspaceId.uuidString < $1.workspaceId.uuidString },
            acceptedSlots: acceptedSlots.sorted {
                ($0.originalToken.pid, $0.originalToken.windowId, $0.workspaceId.uuidString)
                    < ($1.originalToken.pid, $1.originalToken.windowId, $1.workspaceId.uuidString)
            },
            applied: appliedScene.placeholders,
            resolutions: descriptors.map { descriptor in
                let previous = appliedScene.placeholders.first { $0.originalToken == descriptor.originalToken }
                return NativeFullscreenSurfaceResolutionDiagnostics(
                    originalToken: descriptor.originalToken,
                    reason: controller.map {
                        resolvedNativeFullscreenPlaceholder(
                            descriptor,
                            previous: previous,
                            controller: $0
                        ).reason
                    } ?? .controllerUnavailable
                )
            },
            appliedDuplicateOriginalTokens: appliedCounts.compactMap { $0.value > 1 ? $0.key : nil }
        )
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
        displayContext: NativeFullscreenDisplayContext
    ) {
        guard let controller else { return }
        guard controller.hasStartedServices else {
            traceIncomingProjectionDiscarded(
                slots,
                workspaceId: workspaceId,
                displayId: displayId,
                displayContext: displayContext,
                reason: .servicesStopped
            )
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return
        }
        guard controller.workspaceManager.descriptor(for: workspaceId) != nil else {
            traceIncomingProjectionDiscarded(
                slots,
                workspaceId: workspaceId,
                displayId: displayId,
                displayContext: displayContext,
                reason: .workspaceMissing
            )
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return
        }
        guard controller.workspaceManager.monitor(for: workspaceId)?.displayId == displayId else {
            traceIncomingProjectionDiscarded(
                slots,
                workspaceId: workspaceId,
                displayId: displayId,
                displayContext: displayContext,
                reason: .displayMismatch
            )
            return
        }
        if slots.isEmpty, !controller.workspaceManager.hasNativeFullscreenLifecycleContext {
            nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId)
            return
        }

        let traceIsActive = NativeFullscreenPlaceholderTrace.isActive
        let previousProjection = traceIsActive ? nativeFullscreenSlotsByWorkspace[workspaceId] : nil
        nativeFullscreenSlotsByWorkspace[workspaceId] = AcceptedNativeFullscreenSlotProjection(
            displayId: displayId,
            displayContext: displayContext,
            slots: slots
        )
        traceProjectionAcceptedIfSignificant(
            slots,
            previous: previousProjection,
            isActive: traceIsActive,
            workspaceId: workspaceId,
            displayId: displayId,
            displayContext: displayContext
        )

        var needsManagerApply = false
        for index in appliedScene.placeholders.indices {
            let previous = appliedScene.placeholders[index]
            guard previous.workspaceId == workspaceId,
                  let descriptor = nativeFullscreenDescriptorsByOriginalToken[previous.originalToken]
            else { continue }

            let resolution = resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
            let next = resolution.update
            guard next != previous else { continue }

            appliedScene.placeholders[index] = next
            traceSurfaceAppliedIfSignificant(
                next,
                previous: previous,
                reason: resolution.reason
            )
            if previous.originalToken == next.originalToken,
               previous.currentToken == next.currentToken,
               previous.workspaceId == next.workspaceId,
               previous.selected == next.selected,
               previous.visible == next.visible
            {
                controller.nativeFullscreenPlaceholderManager.moveForAnimation(next)
            } else {
                needsManagerApply = true
            }
        }

        if needsManagerApply {
            controller.nativeFullscreenPlaceholderManager.apply(appliedScene.placeholders)
        }
    }

    func applyAcceptedTabRailGeometry(
        _ commands: [TabRailGeometryCommand],
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID
    ) {
        guard !commands.isEmpty,
              let controller,
              controller.hasStartedServices,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              monitor.displayId == displayId,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else {
            return
        }
        controller.tabRailManager.applyAnimationGeometry(commands, in: workspaceId)
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
                if let removed = nativeFullscreenSlotsByWorkspace.removeValue(forKey: workspaceId) {
                    traceIncomingProjectionDiscarded(
                        removed.slots,
                        workspaceId: workspaceId,
                        displayId: removed.displayId,
                        displayContext: removed.displayContext,
                        reason: .workspaceMissing
                    )
                }
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
            let resolution = resolvedNativeFullscreenPlaceholder(
                descriptor,
                previous: previous,
                controller: controller
            )
            let resolved = resolution.update
            if resolved != previous {
                traceSurfaceAppliedIfSignificant(
                    resolved,
                    previous: previous,
                    reason: resolution.reason
                )
            }
            return resolved
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
    ) -> NativeFullscreenPlaceholderResolution {
        let workspaceManager = controller.workspaceManager
        guard let record = workspaceManager.nativeFullscreenRecord(originalToken: descriptor.originalToken) else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: descriptor.currentToken,
                    selected: descriptor.selected,
                    previous: previous
                ),
                reason: .recordMissing
            )
        }
        guard record.workspaceId == descriptor.workspaceId else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: record.currentToken,
                    selected: descriptor.selected,
                    previous: previous
                ),
                reason: .recordWorkspaceMismatch
            )
        }

        let currentToken = record.currentToken
        let selected = workspaceManager.focusedToken == currentToken
            || workspaceManager.pendingFocusedToken == currentToken
        guard record.transition == .suspended else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: .transitionPending
            )
        }
        guard workspaceManager.layoutReason(for: currentToken) == .nativeFullscreen else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: .layoutNotNativeFullscreen
            )
        }
        let descriptorIsCurrent = descriptor.currentToken == currentToken
        let lifecycleVisible = if descriptorIsCurrent {
            descriptor.visible
        } else {
            previous?.visible == true
        }

        guard lifecycleVisible else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: descriptorIsCurrent ? .descriptorHidden : .descriptorStale
            )
        }

        guard let projection = nativeFullscreenSlotsByWorkspace[descriptor.workspaceId] else {
            return NativeFullscreenPlaceholderResolution(
                update: retainedNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: previous?.visible == true ? .projectionMissingRetained : .projectionMissingHidden
            )
        }
        guard workspaceManager.monitor(for: descriptor.workspaceId)?.displayId == projection.displayId else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: .displayMismatch
            )
        }
        guard let slot = projection.slots[descriptor.originalToken] else {
            return NativeFullscreenPlaceholderResolution(
                update: hiddenNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: .slotMissing
            )
        }
        guard slot.currentToken == currentToken else {
            return NativeFullscreenPlaceholderResolution(
                update: retainedNativeFullscreenPlaceholder(
                    descriptor,
                    currentToken: currentToken,
                    selected: selected,
                    previous: previous
                ),
                reason: previous?.visible == true ? .slotTokenMismatchRetained : .slotTokenMismatchHidden
            )
        }

        return NativeFullscreenPlaceholderResolution(
            update: NativeFullscreenPlaceholderUpdate(
                originalToken: descriptor.originalToken,
                currentToken: currentToken,
                workspaceId: descriptor.workspaceId,
                frame: slot.frame,
                displayContext: projection.displayContext,
                selected: selected,
                visible: slot.visible
            ),
            reason: slot.visible ? .accepted : .slotHidden
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

    private func traceProjectionAcceptedIfSignificant(
        _ slots: [WindowToken: NativeFullscreenSlotProjection],
        previous: AcceptedNativeFullscreenSlotProjection?,
        isActive: Bool,
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        displayContext: NativeFullscreenDisplayContext
    ) {
        guard isActive else { return }
        if let previous,
           previous.displayId == displayId,
           previous.displayContext == displayContext,
           previous.slots.count == slots.count,
           slots.allSatisfy({ originalToken, slot in
               guard let prior = previous.slots[originalToken] else { return false }
               return prior.currentToken == slot.currentToken && prior.visible == slot.visible
           })
        {
            return
        }
        guard !slots.isEmpty else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionAccepted,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    reason: .accepted
                )
            )
            return
        }
        for (originalToken, slot) in slots {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionAccepted,
                    originalToken: originalToken,
                    currentToken: slot.currentToken,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    slotFrame: slot.frame,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    visible: slot.visible,
                    reason: .accepted
                )
            )
        }
    }

    private func traceIncomingProjectionDiscarded(
        _ slots: [WindowToken: NativeFullscreenSlotProjection],
        workspaceId: WorkspaceDescriptor.ID,
        displayId: CGDirectDisplayID,
        displayContext: NativeFullscreenDisplayContext,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        guard NativeFullscreenPlaceholderTrace.isActive else { return }
        guard !slots.isEmpty else {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionDiscarded,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    reason: reason
                )
            )
            return
        }
        for (originalToken, slot) in slots {
            NativeFullscreenPlaceholderTrace.record(
                NativeFullscreenPlaceholderTrace.makeRecord(
                    .projectionDiscarded,
                    originalToken: originalToken,
                    currentToken: slot.currentToken,
                    workspaceId: workspaceId,
                    displayId: displayId,
                    slotFrame: slot.frame,
                    workingFrame: displayContext.workingFrame,
                    scale: displayContext.scale,
                    visible: slot.visible,
                    reason: reason
                )
            )
        }
    }

    private func traceSurfaceAppliedIfSignificant(
        _ applied: NativeFullscreenPlaceholderUpdate,
        previous: NativeFullscreenPlaceholderUpdate?,
        reason: NativeFullscreenPlaceholderTrace.Reason
    ) {
        guard NativeFullscreenPlaceholderTrace.isActive else { return }
        if let previous,
           previous.currentToken == applied.currentToken,
           previous.workspaceId == applied.workspaceId,
           previous.selected == applied.selected,
           previous.visible == applied.visible
        {
            return
        }
        NativeFullscreenPlaceholderTrace.record(
            NativeFullscreenPlaceholderTrace.makeRecord(
                .surfaceApplied,
                originalToken: applied.originalToken,
                currentToken: applied.currentToken,
                workspaceId: applied.workspaceId,
                slotFrame: applied.frame,
                visible: applied.visible,
                selected: applied.selected,
                reason: reason
            )
        )
    }
}
