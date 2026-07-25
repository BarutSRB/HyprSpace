// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import ScreenCaptureKit

enum OverviewHotkeyDisposition: Equatable {
    case inactive
    case handled
    case blocked
}

enum OverviewPhysicalHotkeyAction: Equatable {
    case dismissSelection
    case closeSelection
}

@MainActor
struct OverviewEnvironment {
    var frontmostApplicationPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var currentProcessID: () -> pid_t = { getpid() }
    var activateOmniWM: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var activateApplication: (pid_t) -> Void = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    var addLocalEventMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> NSEvent?
    ) -> Any? = { mask, handler in
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    var removeEventMonitor: (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
    }

    var notificationCenter: NotificationCenter = .default
    var selectionDismissDelayNanoseconds: UInt64 = 50_000_000
    var windowTitle: (WindowState) -> String? = { entry in
        AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
    }

    var windowFrame: (WindowState) -> CGRect? = { entry in
        AXWindowService.framePreferFast(entry.axRef)
    }

    var onThumbnailCaptureStarted: () -> Void = {}
    var onCachedProjectionRefreshed: (Set<WorkspaceDescriptor.ID>) -> Void = { _ in }
}

struct DwindleOverviewWorkspaceProjection {
    let inactiveTokens: Set<WindowToken>
    let frames: [WindowToken: CGRect]
    let groupCountByToken: [WindowToken: Int]

    init(engine: DwindleLayoutEngine, workspaceId: WorkspaceDescriptor.ID) {
        inactiveTokens = engine.inactiveGroupTokens(in: workspaceId)
        frames = engine.currentFrames(in: workspaceId)

        var groupCounts: [WindowToken: Int] = [:]
        for snapshot in engine.groupedTileSnapshots(in: workspaceId) {
            groupCounts[snapshot.activeToken] = snapshot.members.count
        }
        groupCountByToken = groupCounts
    }

    func includes(_ token: WindowToken) -> Bool {
        !inactiveTokens.contains(token)
    }
}

@MainActor
final class OverviewController {
    private enum ScrollTuning {
        static let preciseScrollMultiplier: CGFloat = 3.5
        static let nonPreciseScrollMultiplier: CGFloat = 2.0
        static let zoomStep: CGFloat = 0.05
        static let zoomEpsilon: CGFloat = 0.0001
    }

    enum OverviewDismissReason {
        case cancel
        case selection
        case externalDeactivation

        var shouldRestorePreviousApplication: Bool {
            switch self {
            case .cancel:
                true
            case .selection,
                 .externalDeactivation:
                false
            }
        }
    }

    private struct OverviewSnapshot {
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        var groupCountByHandle: [WindowHandle: Int] = [:]

        var windowIds: [Int] {
            windows.values.map(\.token.windowId).sorted()
        }
    }

    private struct OverviewAppearance: Equatable {
        let backdrop: SettingsColor
        let normalBorder: SettingsColor
        let hoveredBorder: SettingsColor
        let selectedBorder: SettingsColor

        @MainActor
        init(settings: SettingsStore) {
            backdrop = settings.overviewBackdropColor
            normalBorder = settings.overviewNormalBorderColor
            hoveredBorder = settings.overviewHoveredBorderColor
            selectedBorder = settings.overviewSelectedBorderColor
        }

        var renderPalette: OverviewRenderPalette {
            OverviewRenderPalette(
                backdropColor: backdrop,
                normalBorderColor: normalBorder,
                hoveredBorderColor: hoveredBorder,
                selectedBorderColor: selectedBorder
            )
        }
    }

    private weak var wmController: WMController?
    private let motionPolicy: MotionPolicy
    private let environment: OverviewEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry

    private(set) var state: OverviewState = .closed
    private var overviewSnapshot = OverviewSnapshot()
    private var layoutsByMonitor: [Monitor.ID: OverviewLayout] = [:]
    private var searchQuery: String = ""
    private var scale: CGFloat = 1.0
    private var configuredScale: CGFloat = 1.0
    private var appearance: OverviewAppearance
    private var renderPalette: OverviewRenderPalette
    private(set) var selectedWindowHandle: WindowHandle?
    private(set) var activeInteractionMonitorId: Monitor.ID?

    private var windows: [OverviewWindow] = []
    private var animator: OverviewAnimator?
    private var thumbnailCache: [Int: CGImage] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?
    private static let maxConcurrentThumbnailCaptures = 4

    private struct ThumbnailCaptureItem: @unchecked Sendable {
        let request: OverviewThumbnailCaptureRequest
        let scWindow: SCWindow
    }

    private var keyEventMonitor: Any?
    private var flagsEventMonitor: Any?
    private var applicationDidResignObserver: NSObjectProtocol?
    private var previousFrontmostApplicationPID: pid_t?
    private var pendingDismissReason: OverviewDismissReason = .cancel
    private var pendingFocusTargetWindow: WindowHandle?

    private var inputHandler: OverviewInputHandler?
    private var dragGhostController: DragGhostController?
    private var dragSession: DragSession?
    private var structuralTransferGeneration: UInt64 = 0
    private var activeStructuralTransferGeneration: UInt64?
    private var projectionMutationGeneration: UInt64 = 0
    private var pendingProjectionWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

    var onActivateWindow: ((WindowHandle, WorkspaceDescriptor.ID) -> Void)?
    var onCloseWindow: ((WindowHandle) -> Bool)?
    var isOpen: Bool {
        state.isOpen
    }

    init(
        wmController: WMController,
        motionPolicy: MotionPolicy,
        environment: OverviewEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        let appearance = OverviewAppearance(settings: wmController.settings)
        let configuredScale = OverviewLayoutCalculator.clampedScale(CGFloat(wmController.settings.overviewZoom))
        self.wmController = wmController
        self.motionPolicy = motionPolicy
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        self.configuredScale = configuredScale
        scale = configuredScale
        self.appearance = appearance
        renderPalette = appearance.renderPalette
        animator = OverviewAnimator(controller: self)
        inputHandler = OverviewInputHandler(controller: self)
    }

    func toggle() {
        switch state {
        case .closed:
            open()
        case .opening,
             .open:
            dismissToSelection(animated: true)
        case .closing:
            break
        }
    }

    func handleHotkeyInvocation(_ invocation: HotkeyInvocation) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }
        if let trigger = invocation.trigger,
           let action = Self.physicalHotkeyAction(for: trigger)
        {
            guard !trigger.isRepeat else { return .handled }
            switch action {
            case .dismissSelection:
                dismissToSelection(animated: true)
            case .closeSelection:
                closeSelectedWindow()
            }
            return .handled
        }
        return handleHotkeyCommand(invocation.command)
    }

    static func physicalHotkeyAction(for trigger: PhysicalHotkeyTrigger) -> OverviewPhysicalHotkeyAction? {
        let relevantModifiers = trigger.modifiers
            & UInt32(controlKey | optionKey | shiftKey | cmdKey)
        switch trigger.keyCode {
        case UInt32(kVK_Escape):
            return .dismissSelection
        case UInt32(kVK_Return),
             UInt32(kVK_ANSI_KeypadEnter):
            return relevantModifiers == 0 ? .dismissSelection : nil
        case UInt32(kVK_ANSI_W):
            return relevantModifiers == UInt32(cmdKey) ? .closeSelection : nil
        default:
            return nil
        }
    }

    func handleHotkeyCommand(_ command: HotkeyCommand) -> OverviewHotkeyDisposition {
        guard state.isOpen else { return .inactive }

        switch command {
        case .toggleOverview:
            switch state {
            case .opening,
                 .open:
                dismissToSelection(animated: true)
            case .closed,
                 .closing:
                break
            }
            return .handled
        case let .focus(direction):
            guard case .open = state, dragSession == nil else { return .handled }
            navigateSelection(direction)
            return .handled
        default:
            guard isStructuralHotkey(command) else { return .blocked }
            guard case .open = state,
                  dragSession == nil,
                  activeStructuralTransferGeneration == nil
            else {
                return .handled
            }
            guard let selectedWindowHandle else { return .handled }
            executeStructuralHotkey(command, selectedHandle: selectedWindowHandle)
            return .handled
        }
    }

    @discardableResult
    func executeStructuralHotkey(
        _ command: HotkeyCommand,
        selectedHandle: WindowHandle
    ) -> StructuralMutationOutcome? {
        guard activeStructuralTransferGeneration == nil else { return .unchanged }
        let outcome = performStructuralHotkey(command, selectedHandle: selectedHandle)
        if let outcome, case let .changed(mutation) = outcome {
            completeStructuralMutation(mutation)
        }
        return outcome
    }

    func performStructuralHotkey(
        _ command: HotkeyCommand,
        selectedHandle: WindowHandle
    ) -> StructuralMutationOutcome? {
        guard let wmController,
              let workspaceId = wmController.workspaceManager.workspace(for: selectedHandle.id)
        else {
            return .unchanged
        }
        let isNiri = wmController.workspaceManager.activeLayoutKind(for: workspaceId) == .niri

        switch command {
        case let .move(direction):
            guard isNiri else { return .unchanged }
            let outcome = wmController.niriLayoutHandler.moveWindow(
                handle: selectedHandle,
                direction: direction
            )
            if case .atWorkspaceEdge = outcome,
               wmController.settings.moveCrossesMonitorAtEdge
            {
                return wmController.workspaceNavigationHandler.moveWindowToMonitor(
                    handle: selectedHandle,
                    direction: direction
                )
            }
            return outcome
        case .moveWindowDown:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowWithinContainer(
                handle: selectedHandle,
                direction: .down
            )
        case .moveWindowUp:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowWithinContainer(
                handle: selectedHandle,
                direction: .up
            )
        case .moveWindowDownOrToWorkspaceDown:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .down
            )
        case .moveWindowUpOrToWorkspaceUp:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .up
            )
        case .consumeOrExpelWindowLeft:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.consumeOrExpelWindow(
                handle: selectedHandle,
                direction: .left
            )
        case .consumeOrExpelWindowRight:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.consumeOrExpelWindow(
                handle: selectedHandle,
                direction: .right
            )
        case .consumeWindowIntoColumn:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.consumeWindowIntoColumn(containing: selectedHandle)
        case .expelWindowFromColumn:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.expelWindowFromColumn(containing: selectedHandle)
        case let .moveColumn(direction):
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumn(
                containing: selectedHandle,
                direction: direction
            )
        case .moveColumnToFirst:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumnToFirst(containing: selectedHandle)
        case .moveColumnToLast:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumnToLast(containing: selectedHandle)
        case let .moveColumnToIndex(index):
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumn(
                containing: selectedHandle,
                toOneBasedIndex: index
            )
        case let .moveToWorkspace(index):
            return wmController.workspaceNavigationHandler.moveWindow(
                handle: selectedHandle,
                toWorkspaceIndex: index
            )
        case .moveWindowToWorkspaceUp:
            return wmController.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .up
            )
        case .moveWindowToWorkspaceDown:
            return wmController.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .down
            )
        case let .moveColumnToWorkspace(index):
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumn(
                containing: selectedHandle,
                toWorkspaceIndex: index
            )
        case .moveColumnToWorkspaceUp:
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(
                containing: selectedHandle,
                direction: .up
            )
        case .moveColumnToWorkspaceDown:
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(
                containing: selectedHandle,
                direction: .down
            )
        case let .moveWindowToWorkspaceOnMonitor(workspaceIndex, monitorDirection):
            return wmController.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
                handle: selectedHandle,
                workspaceIndex: workspaceIndex,
                monitorDirection: monitorDirection
            )
        default:
            return nil
        }
    }

    private func isStructuralHotkey(_ command: HotkeyCommand) -> Bool {
        switch command {
        case .move,
             .moveWindowDown,
             .moveWindowUp,
             .moveWindowDownOrToWorkspaceDown,
             .moveWindowUpOrToWorkspaceUp,
             .consumeOrExpelWindowLeft,
             .consumeOrExpelWindowRight,
             .consumeWindowIntoColumn,
             .expelWindowFromColumn,
             .moveColumn,
             .moveColumnToFirst,
             .moveColumnToLast,
             .moveColumnToIndex,
             .moveToWorkspace,
             .moveWindowToWorkspaceUp,
             .moveWindowToWorkspaceDown,
             .moveColumnToWorkspace,
             .moveColumnToWorkspaceUp,
             .moveColumnToWorkspaceDown,
             .moveWindowToWorkspaceOnMonitor:
            true
        default:
            false
        }
    }

    private func completeStructuralMutation(_ mutation: StructuralMutation) {
        guard let wmController, activateStructuralDestination(mutation) else { return }
        let transferGeneration = serializesTransfer(mutation) ? beginStructuralTransfer() : nil
        let projectionGeneration = beginProjectionMutation(
            affectedWorkspaceIds: projectionWorkspaceIds(for: mutation)
        )

        wmController.layoutRefreshController.requestImmediateRelayout(
            reason: .overviewMutation,
            affectedWorkspaceIds: mutation.affectedWorkspaceIds,
            postLayout: { [weak self] in
                self?.finishStructuralMutation(
                    mutation,
                    projectionGeneration: projectionGeneration,
                    transferGeneration: transferGeneration
                )
            },
            postLayoutInvalidated: { [weak self] in
                self?.finishStructuralMutation(
                    mutation,
                    projectionGeneration: projectionGeneration,
                    transferGeneration: transferGeneration
                )
            }
        )
        if let scrollWorkspaceId = mutation.scrollWorkspaceId {
            wmController.layoutRefreshController.startScrollAnimation(for: scrollWorkspaceId)
        }
    }

    private func beginProjectionMutation(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> UInt64 {
        pendingProjectionWorkspaceIds.formUnion(affectedWorkspaceIds)
        projectionMutationGeneration &+= 1
        return projectionMutationGeneration
    }

    private func finishStructuralMutation(
        _ mutation: StructuralMutation,
        projectionGeneration: UInt64,
        transferGeneration: UInt64?
    ) {
        defer { finishStructuralTransfer(transferGeneration) }
        guard projectionMutationGeneration == projectionGeneration else { return }
        synchronizeStructuralSelection(mutation)
        pendingProjectionWorkspaceIds.formUnion(projectionWorkspaceIds(for: mutation))
        let affectedWorkspaceIds = pendingProjectionWorkspaceIds
        pendingProjectionWorkspaceIds.removeAll(keepingCapacity: true)
        refreshCachedOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )
    }

    private func projectionWorkspaceIds(
        for mutation: StructuralMutation
    ) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds = mutation.affectedWorkspaceIds
        if let workspaceId = wmController?.workspaceManager.workspace(for: mutation.selectedHandle.id) {
            workspaceIds.insert(workspaceId)
        }
        return workspaceIds
    }

    private func activateStructuralDestination(_ mutation: StructuralMutation) -> Bool {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitorForWorkspace(mutation.destinationWorkspaceId)
        else {
            return false
        }
        guard wmController.workspaceManager.setActiveWorkspace(
            mutation.destinationWorkspaceId,
            on: monitor.id
        ) else {
            return false
        }
        _ = wmController.workspaceManager.setInteractionMonitor(monitor.id)
        synchronizeStructuralSelection(mutation)
        activeInteractionMonitorId = monitor.id
        setSelectedWindowHandle(mutation.selectedHandle)
        return true
    }

    private func synchronizeStructuralSelection(_ mutation: StructuralMutation) {
        guard let wmController,
              wmController.workspaceManager.workspace(for: mutation.selectedHandle.id)
              == mutation.destinationWorkspaceId,
              let monitor = wmController.workspaceManager.monitorForWorkspace(mutation.destinationWorkspaceId)
        else {
            return
        }

        let nodeId = wmController.niriEngine?
            .findNode(for: mutation.selectedHandle, in: mutation.destinationWorkspaceId)?.id
        _ = wmController.workspaceManager.commitWorkspaceSelection(
            nodeId: nodeId,
            focusedToken: mutation.selectedHandle.id,
            in: mutation.destinationWorkspaceId,
            onMonitor: monitor.id
        )
        if wmController.workspaceManager.activeLayoutKind(for: mutation.destinationWorkspaceId) == .dwindle,
           let engine = wmController.dwindleEngine,
           let node = engine.findNode(for: mutation.selectedHandle.id, in: mutation.destinationWorkspaceId)
        {
            wmController.workspaceManager.withEngineMutationScope(in: mutation.destinationWorkspaceId) {
                engine.setSelectedNode(node, in: mutation.destinationWorkspaceId)
            }
        }
    }

    private func serializesTransfer(_ mutation: StructuralMutation) -> Bool {
        guard mutation.sourceWorkspaceId != mutation.destinationWorkspaceId,
              let wmController
        else {
            return false
        }
        return wmController.workspaceManager.activeLayoutKind(for: mutation.sourceWorkspaceId)
            != wmController.workspaceManager.activeLayoutKind(for: mutation.destinationWorkspaceId)
    }

    private func beginStructuralTransfer() -> UInt64? {
        guard activeStructuralTransferGeneration == nil else { return nil }
        structuralTransferGeneration &+= 1
        activeStructuralTransferGeneration = structuralTransferGeneration
        return structuralTransferGeneration
    }

    private func finishStructuralTransfer(_ generation: UInt64?) {
        guard let generation, activeStructuralTransferGeneration == generation else { return }
        activeStructuralTransferGeneration = nil
    }

    func open() {
        guard case .closed = state else { return }
        guard wmController != nil else { return }

        prepareOpenState()
        createWindows()
        beginOwnedSession()
        startThumbnailCapture()

        let monitor = animationMonitor()
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        if motionPolicy.animationsEnabled {
            state = .opening(progress: 0)
            animator?.startOpenAnimation(displayId: displayId, refreshRate: refreshRate)
        } else {
            state = .open
            animator?.cancelAnimation()
        }

        updateWindowDisplays()
        showWindows()
        activateOwnedSession()
        primaryOverviewWindow()?.show(asKeyWindow: true)
    }

    func prepareOpenState() {
        guard let wmController else { return }

        activeInteractionMonitorId = wmController.monitorForInteraction()?.id
        configuredScale = OverviewLayoutCalculator.clampedScale(CGFloat(wmController.settings.overviewZoom))
        scale = configuredScale
        appearance = OverviewAppearance(settings: wmController.settings)
        renderPalette = appearance.renderPalette
        buildOverviewSnapshot()

        if let focusedHandle = wmController.workspaceManager.focusedHandle,
           overviewSnapshot.windows[focusedHandle] != nil
        {
            selectedWindowHandle = focusedHandle
        }

        rebuildProjectedLayouts()
    }

    func updateSettings() {
        guard let wmController else { return }

        let nextConfiguredScale = OverviewLayoutCalculator.clampedScale(CGFloat(wmController.settings.overviewZoom))
        let nextAppearance = OverviewAppearance(settings: wmController.settings)
        let scaleChanged = abs(nextConfiguredScale - configuredScale) > ScrollTuning.zoomEpsilon
        let appearanceChanged = nextAppearance != appearance

        configuredScale = nextConfiguredScale
        if appearanceChanged {
            appearance = nextAppearance
            renderPalette = nextAppearance.renderPalette
        }

        guard state.isOpen else {
            scale = nextConfiguredScale
            return
        }
        guard scaleChanged || appearanceChanged else { return }

        if scaleChanged {
            let anchors = captureSelectedViewportAnchors()
            scale = nextConfiguredScale
            rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
            updateWindowDisplays(palette: appearanceChanged ? renderPalette : nil)
        } else {
            for window in windows {
                window.updatePalette(renderPalette)
            }
        }
    }

    func dismiss(
        reason: OverviewDismissReason = .cancel,
        targetWindow: WindowHandle? = nil,
        animated: Bool
    ) {
        switch state {
        case .closed:
            return
        case .closing:
            if reason == .externalDeactivation {
                pendingDismissReason = .externalDeactivation
                pendingFocusTargetWindow = nil
            }
            return
        case .opening,
             .open:
            break
        }

        if hasActiveDragSession {
            cancelDrag()
        }

        let resolvedTargetWindow = reason == .selection ? targetWindow : nil
        pendingDismissReason = reason
        pendingFocusTargetWindow = resolvedTargetWindow

        let monitor = animationMonitor()
        let displayId = monitor?.displayId ?? CGMainDisplayID()
        let refreshRate = detectRefreshRate(for: displayId)

        state = .closing(targetWindow: resolvedTargetWindow, progress: 0)

        if animated && motionPolicy.animationsEnabled {
            animator?.startCloseAnimation(
                targetWindow: resolvedTargetWindow,
                displayId: displayId,
                refreshRate: refreshRate
            )
        } else {
            completeCloseTransition(targetWindow: resolvedTargetWindow)
        }
    }

    private func buildOverviewState() {
        buildOverviewSnapshot()
        rebuildProjectedLayouts()
    }

    private func buildOverviewSnapshot() {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager

        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]
        var groupCountByHandle: [WindowHandle: Int] = [:]

        for monitor in workspaceManager.monitors {
            let activeWs = workspaceManager.activeWorkspace(on: monitor.id)

            for ws in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append((
                    id: ws.id,
                    name: wmController.settings.displayName(for: ws.name),
                    isActive: ws.id == activeWs?.id
                ))

                let dwindleProjection = dwindleOverviewProjection(for: ws.id)

                for entry in workspaceManager.entries(in: ws.id) {
                    guard entry.layoutReason == .standard,
                          dwindleProjection?.includes(entry.token) != false,
                          let handle = workspaceManager.handle(for: entry.token)
                    else {
                        continue
                    }

                    windowData[handle] = makeOverviewWindowData(
                        for: entry,
                        preferredFrame: dwindleProjection?.frames[entry.token],
                        appInfoCache: wmController.appInfoCache
                    )
                    if let count = dwindleProjection?.groupCountByToken[entry.token], count > 1 {
                        groupCountByHandle[handle] = count
                    }
                }
            }
        }

        overviewSnapshot = OverviewSnapshot(
            workspaces: workspaces,
            windows: windowData,
            groupCountByHandle: groupCountByHandle
        )
        overviewSnapshot.niriSnapshotsByWorkspace = buildNiriOverviewSnapshots()
    }

    func refreshCachedOverviewProjection(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        selectedHandle: WindowHandle? = nil
    ) {
        guard state.isOpen, let wmController else { return }
        environment.onCachedProjectionRefreshed(affectedWorkspaceIds)
        let anchors = captureSelectedViewportAnchors()
        let workspaceManager = wmController.workspaceManager
        let previousWindowIds = Set(overviewSnapshot.windowIds)

        var workspaces: [OverviewWorkspaceLayoutItem] = []
        for monitor in workspaceManager.monitors {
            let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
            for workspace in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append((
                    id: workspace.id,
                    name: wmController.settings.displayName(for: workspace.name),
                    isActive: workspace.id == activeWorkspaceId
                ))
            }
        }
        overviewSnapshot.workspaces = workspaces

        let staleGroupHandles = overviewSnapshot.groupCountByHandle.keys.filter { handle in
            overviewSnapshot.windows[handle].map { affectedWorkspaceIds.contains($0.workspaceId) } == true
        }
        for handle in staleGroupHandles {
            overviewSnapshot.groupCountByHandle.removeValue(forKey: handle)
        }

        var engineFrames: [WindowToken: CGRect] = [:]
        var dwindleProjections: [WorkspaceDescriptor.ID: DwindleOverviewWorkspaceProjection] = [:]
        for workspaceId in affectedWorkspaceIds {
            switch workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                if let frames = wmController.niriEngine?.captureWindowFrames(in: workspaceId) {
                    engineFrames.merge(frames) { _, new in new }
                }
                if let snapshot = wmController.niriEngine?.overviewSnapshot(for: workspaceId),
                   let filteredSnapshot = cachedNiriSnapshot(snapshot)
                {
                    overviewSnapshot.niriSnapshotsByWorkspace[workspaceId] = filteredSnapshot
                } else {
                    overviewSnapshot.niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
                }
            case .dwindle:
                if let engine = wmController.dwindleEngine {
                    let projection = DwindleOverviewWorkspaceProjection(
                        engine: engine,
                        workspaceId: workspaceId
                    )
                    dwindleProjections[workspaceId] = projection
                    engineFrames.merge(projection.frames) { _, new in new }
                }
                overviewSnapshot.niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
            }
        }

        for (handle, data) in overviewSnapshot.windows {
            guard let entry = workspaceManager.entry(for: handle) else { continue }
            let frame = engineFrames[entry.token] ?? data.frame
            if entry.token != data.token || entry.workspaceId != data.workspaceId || frame != data.frame {
                overviewSnapshot.windows[handle] = (
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: frame
                )
            }
        }

        for (workspaceId, projection) in dwindleProjections {
            reconcileDwindleOverviewProjection(
                projection,
                workspaceId: workspaceId
            )
        }

        overviewSnapshot.groupCountByHandle = overviewSnapshot.groupCountByHandle.filter {
            overviewSnapshot.windows[$0.key] != nil
        }

        if let selectedHandle,
           overviewSnapshot.windows[selectedHandle] != nil,
           workspaceManager.entry(for: selectedHandle) != nil
        {
            selectedWindowHandle = selectedHandle
        }
        rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
        updateWindowDisplays()

        let addedWindowIds = Set(overviewSnapshot.windowIds).subtracting(previousWindowIds)
        let uncachedAddedWindowIds = addedWindowIds.filter { thumbnailCache[$0] == nil }
        if !uncachedAddedWindowIds.isEmpty {
            let uncachedWindowIds = Set(overviewSnapshot.windowIds.filter { thumbnailCache[$0] == nil })
            startThumbnailCapture(windowIds: uncachedWindowIds)
        }
    }

    private func dwindleOverviewProjection(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleOverviewWorkspaceProjection? {
        guard let wmController,
              wmController.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let engine = wmController.dwindleEngine
        else {
            return nil
        }
        return DwindleOverviewWorkspaceProjection(engine: engine, workspaceId: workspaceId)
    }

    private func reconcileDwindleOverviewProjection(
        _ projection: DwindleOverviewWorkspaceProjection,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        var desiredHandles: Set<WindowHandle> = []

        for entry in workspaceManager.entries(in: workspaceId) {
            guard entry.layoutReason == .standard,
                  projection.includes(entry.token),
                  let handle = workspaceManager.handle(for: entry.token)
            else {
                continue
            }

            desiredHandles.insert(handle)
            let frame = projection.frames[entry.token]
                ?? overviewSnapshot.windows[handle]?.frame
                ?? environment.windowFrame(entry)
                ?? .zero
            if let data = overviewSnapshot.windows[handle] {
                if data.token != entry.token || data.workspaceId != workspaceId || data.frame != frame {
                    overviewSnapshot.windows[handle] = (
                        token: entry.token,
                        workspaceId: workspaceId,
                        title: data.title,
                        appName: data.appName,
                        appIcon: data.appIcon,
                        frame: frame
                    )
                }
            } else {
                overviewSnapshot.windows[handle] = makeOverviewWindowData(
                    for: entry,
                    preferredFrame: frame,
                    appInfoCache: wmController.appInfoCache
                )
            }

            if let count = projection.groupCountByToken[entry.token], count > 1 {
                overviewSnapshot.groupCountByHandle[handle] = count
            }
        }

        let staleHandles = overviewSnapshot.windows.compactMap { handle, data in
            data.workspaceId == workspaceId && !desiredHandles.contains(handle) ? handle : nil
        }
        for handle in staleHandles {
            overviewSnapshot.windows.removeValue(forKey: handle)
            overviewSnapshot.groupCountByHandle.removeValue(forKey: handle)
        }
    }

    private func makeOverviewWindowData(
        for entry: WindowState,
        preferredFrame: CGRect?,
        appInfoCache: AppInfoCache
    ) -> OverviewWindowLayoutData {
        let title = environment.windowTitle(entry) ?? ""
        let appInfo = appInfoCache.info(for: entry.pid)
        return (
            token: entry.token,
            workspaceId: entry.workspaceId,
            title: title.isEmpty ? (appInfo?.name ?? "Window") : title,
            appName: appInfo?.name ?? "Unknown",
            appIcon: appInfo?.icon,
            frame: preferredFrame ?? environment.windowFrame(entry) ?? .zero
        )
    }

    private func cachedNiriSnapshot(
        _ snapshot: NiriOverviewWorkspaceSnapshot
    ) -> NiriOverviewWorkspaceSnapshot? {
        let columns = snapshot.columns.compactMap { column -> NiriOverviewColumnSnapshot? in
            let tiles = column.tiles.filter { tile in
                wmController?.workspaceManager.workspace(for: tile.token) == snapshot.workspaceId
            }
            guard !tiles.isEmpty else { return nil }
            return NiriOverviewColumnSnapshot(
                index: 0,
                widthWeight: column.widthWeight,
                preferredWidth: column.preferredWidth,
                tiles: tiles
            )
        }.enumerated().map { index, column in
            NiriOverviewColumnSnapshot(
                index: index,
                widthWeight: column.widthWeight,
                preferredWidth: column.preferredWidth,
                tiles: column.tiles
            )
        }
        guard !columns.isEmpty else { return nil }
        return NiriOverviewWorkspaceSnapshot(workspaceId: snapshot.workspaceId, columns: columns)
    }

    private struct SelectedViewportAnchor {
        let handle: WindowHandle
        let midpointY: CGFloat
    }

    private func rebuildProjectedLayouts(
        preservingSelectedAnchors anchors: [Monitor.ID: SelectedViewportAnchor] = [:]
    ) {
        guard let wmController else { return }

        let previousLayouts = layoutsByMonitor
        let monitors = wmController.workspaceManager.monitors

        if let selectedWindowHandle,
           overviewSnapshot.windows[selectedWindowHandle] == nil
        {
            self.selectedWindowHandle = nil
        }

        layoutsByMonitor = [:]
        for monitor in monitors {
            var layout = projectedLayout(
                for: monitor,
                niriSnapshotsByWorkspace: overviewSnapshot.niriSnapshotsByWorkspace
            )
            let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
            let previousOffset = previousLayouts[monitor.id]?.scrollOffset ?? 0
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                previousOffset,
                layout: layout,
                screenFrame: viewportFrame
            )
            layout.dragTarget = previousLayouts[monitor.id]?.dragTarget
            layoutsByMonitor[monitor.id] = layout
        }

        reconcileSelectedWindowHandle()
        applySelectedWindowHandleToLayouts()

        if let activeInteractionMonitorId,
           layoutsByMonitor[activeInteractionMonitorId] == nil
        {
            self.activeInteractionMonitorId = nil
        }

        if activeInteractionMonitorId == nil {
            activeInteractionMonitorId = monitors.first?.id
        }

        restoreSelectedViewportAnchors(anchors)
        revealSelectedWindow(on: activeInteractionMonitorId)
    }

    private func projectedLayout(
        for monitor: Monitor,
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot]
    ) -> OverviewLayout {
        let localizedWindowData = overviewSnapshot.windows.mapValues { windowData in
            (
                token: windowData.token,
                workspaceId: windowData.workspaceId,
                title: windowData.title,
                appName: windowData.appName,
                appIcon: windowData.appIcon,
                frame: OverviewLayoutCalculator.localizedFrame(windowData.frame, to: monitor.frame)
            )
        }

        let viewportFrame = OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
        var layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: overviewSnapshot.workspaces,
            windows: localizedWindowData,
            niriSnapshotsByWorkspace: niriSnapshotsByWorkspace,
            screenFrame: viewportFrame,
            searchQuery: searchQuery,
            scale: scale
        )
        var sections = layout.workspaceSections
        for sectionIndex in sections.indices {
            for windowIndex in sections[sectionIndex].windows.indices {
                let handle = sections[sectionIndex].windows[windowIndex].handle
                sections[sectionIndex].windows[windowIndex].groupCount =
                    overviewSnapshot.groupCountByHandle[handle] ?? 1
            }
        }
        layout.workspaceSections = sections
        return layout
    }

    private func buildNiriOverviewSnapshots() -> [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] {
        guard let engine = wmController?.niriEngine else { return [:] }

        var snapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        snapshots.reserveCapacity(overviewSnapshot.workspaces.count)

        for workspace in overviewSnapshot.workspaces {
            guard isNiriLayout(workspaceId: workspace.id),
                  let snapshot = engine.overviewSnapshot(for: workspace.id)
            else {
                continue
            }
            snapshots[workspace.id] = snapshot
        }

        return snapshots
    }

    private func createWindows() {
        closeWindows()

        guard let wmController else { return }

        for monitor in wmController.workspaceManager.monitors {
            let window = OverviewWindow(monitor: monitor, palette: renderPalette)

            window.onWindowSelected = { [weak self] monitorId, handle in
                self?.activeInteractionMonitorId = monitorId
                self?.selectAndActivateWindow(handle)
            }
            window.onWindowClosed = { [weak self] monitorId, handle in
                self?.activeInteractionMonitorId = monitorId
                self?.closeWindow(handle)
            }
            window.onDismiss = { [weak self] monitorId in
                self?.activeInteractionMonitorId = monitorId
                self?.dismissToSelection(animated: true)
            }
            window.onScroll = { [weak self] monitorId, delta in
                self?.adjustScrollOffset(by: delta, on: monitorId)
            }
            window.onScrollWithModifiers = { [weak self] monitorId, delta, modifiers, isPrecise in
                self?.handleScroll(
                    delta: delta,
                    modifiers: modifiers,
                    isPrecise: isPrecise,
                    on: monitorId
                )
            }
            window.onDragBegin = { [weak self] monitorId, handle, start in
                self?.beginDrag(on: monitorId, handle: handle, startPoint: start)
            }
            window.onDragUpdate = { [weak self] monitorId, point in
                self?.updateDrag(on: monitorId, at: point)
            }
            window.onDragEnd = { [weak self] monitorId, point in
                self?.endDrag(on: monitorId, at: point)
            }
            window.onDragCancel = { [weak self] in
                self?.cancelDrag()
            }

            windows.append(window)
        }
    }

    private func showWindows() {
        let primaryWindow = primaryOverviewWindow()

        if let primaryWindow {
            primaryWindow.show(asKeyWindow: true)
            ownedWindowRegistry.register(
                primaryWindow,
                surfaceId: "overview-\(String(describing: primaryWindow.monitorId))",
                policy: SurfacePolicy(
                    kind: .overview,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                )
            )
        }

        for window in windows where primaryWindow == nil || window !== primaryWindow {
            window.show(asKeyWindow: false)
            ownedWindowRegistry.register(
                window,
                surfaceId: "overview-\(String(describing: window.monitorId))",
                policy: SurfacePolicy(
                    kind: .overview,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                )
            )
        }
    }

    private func primaryOverviewWindow() -> OverviewWindow? {
        guard let primaryMonitorId = activeInteractionMonitorId ?? windows.first?.monitorId else { return nil }
        return windows.first(where: { $0.monitorId == primaryMonitorId })
    }

    private func closeWindows() {
        for window in windows {
            ownedWindowRegistry.unregister(surfaceId: "overview-\(String(describing: window.monitorId))")
            window.hide()
            window.close()
        }
        windows.removeAll()
    }

    func isPointInside(_ point: CGPoint) -> Bool {
        guard state.isOpen else { return false }
        for window in windows {
            if window.frame.contains(point) {
                return true
            }
        }
        return false
    }

    private func updateWindowDisplays(
        palette: OverviewRenderPalette? = nil,
        thumbnails: [Int: CGImage]? = nil
    ) {
        for window in windows {
            let layout = layoutsByMonitor[window.monitorId] ?? .init()
            window.updateLayout(
                layout,
                state: state,
                searchQuery: searchQuery,
                palette: palette,
                thumbnails: thumbnails
            )
        }
    }

    private func updateWindowThumbnails() {
        for window in windows {
            window.updateThumbnails(thumbnailCache)
        }
    }

    private func startThumbnailCapture(windowIds: Set<Int>? = nil) {
        thumbnailCaptureTask?.cancel()
        environment.onThumbnailCaptureStarted()
        thumbnailCaptureTask = Task { [weak self] in
            await self?.captureThumbnails(windowIds: windowIds)
        }
    }

    private func captureThumbnails(windowIds: Set<Int>?) async {
        let requests = thumbnailCaptureRequests(windowIds: windowIds)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let eligibleWindows = content.windows.compactMap { scWindow -> (CGWindowID, SCWindow)? in
                let windowNumber = Int(scWindow.windowID)
                guard ownedWindowRegistry.isCaptureEligible(windowNumber: windowNumber) else { return nil }
                return (scWindow.windowID, scWindow)
            }
            let windowMap = Dictionary(uniqueKeysWithValues: eligibleWindows)
            let captures = requests.compactMap { request -> ThumbnailCaptureItem? in
                guard let scWindow = windowMap[CGWindowID(request.windowId)] else { return nil }
                return ThumbnailCaptureItem(request: request, scWindow: scWindow)
            }

            await withTaskGroup(of: (windowId: Int, thumbnail: CGImage?).self) { group in
                var nextIndex = 0
                func addNextCapture() {
                    guard nextIndex < captures.count, !Task.isCancelled else { return }
                    let item = captures[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (item.request.windowId, nil) }
                        return (
                            item.request.windowId,
                            await Self.captureWindowThumbnail(scWindow: item.scWindow, request: item.request)
                        )
                    }
                }

                for _ in 0 ..< min(Self.maxConcurrentThumbnailCaptures, captures.count) {
                    addNextCapture()
                }
                while let result = await group.next() {
                    if let thumbnail = result.thumbnail {
                        thumbnailCache[result.windowId] = thumbnail
                    }
                    addNextCapture()
                }
            }

            guard !Task.isCancelled else { return }
            updateWindowThumbnails()
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "overviewContentException")
            return
        }
    }

    private func thumbnailCaptureRequests(windowIds: Set<Int>? = nil) -> [OverviewThumbnailCaptureRequest] {
        guard let wmController else { return [] }

        let scaleByMonitorId = wmController.workspaceManager.monitors
            .reduce(into: [Monitor.ID: CGFloat]()) { scales, monitor in
                scales[monitor.id] = monitorBackingScaleFactor(for: monitor.displayId)
            }

        var projections: [OverviewThumbnailProjection] = []
        projections.reserveCapacity(layoutsByMonitor.values.reduce(0) { partialResult, layout in
            partialResult + layout.allWindows.count
        })

        for (monitorId, layout) in layoutsByMonitor {
            let scaleFactor = scaleByMonitorId[monitorId] ?? 1.0
            for window in layout.allWindows {
                projections.append(
                    OverviewThumbnailProjection(
                        windowId: window.windowId,
                        overviewFrame: window.overviewFrame,
                        backingScaleFactor: scaleFactor
                    )
                )
            }
        }

        return OverviewThumbnailSizing.captureRequests(
            windowIds: windowIds.map { Array($0).sorted() } ?? overviewSnapshot.windowIds,
            projections: projections
        )
    }

    private nonisolated static func captureWindowThumbnail(
        scWindow: SCWindow,
        request: OverviewThumbnailCaptureRequest
    ) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        config.width = request.pixelWidth
        config.height = request.pixelHeight
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            FallbackFiringRecorder.shared.note(.capture, "screenshotException")
            return nil
        }
    }

    private func monitorBackingScaleFactor(for displayId: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == displayId })?.backingScaleFactor ?? 1.0
    }

    func updateAnimationProgress(_ progress: Double, state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func onAnimationComplete(state: OverviewState) {
        self.state = state
        updateWindowDisplays()
    }

    func completeCloseTransition(targetWindow: WindowHandle?) {
        let dismissReason = pendingDismissReason
        let previousFrontmostApplicationPID = previousFrontmostApplicationPID
        let requestedTargetWindow = pendingFocusTargetWindow ?? targetWindow
        let resolvedTargetWindow = requestedTargetWindow.flatMap { handle in
            wmController?.workspaceManager.entry(for: handle) == nil ? nil : handle
        }

        animator?.cancelAnimation()
        state = .closed
        cleanup()
        endOwnedSession()

        if (dismissReason
            .shouldRestorePreviousApplication || dismissReason == .selection && resolvedTargetWindow == nil),
            let previousFrontmostApplicationPID
        {
            environment.activateApplication(previousFrontmostApplicationPID)
        } else if dismissReason == .selection,
                  let resolvedTargetWindow
        {
            focusTargetWindow(resolvedTargetWindow)
        }

        updateWindowDisplays()
    }

    func focusTargetWindow(_ handle: WindowHandle) {
        guard let wmController else { return }
        guard let entry = wmController.workspaceManager.entry(for: handle) else { return }

        onActivateWindow?(handle, entry.workspaceId)
    }

    func selectAndActivateWindow(_ handle: WindowHandle) {
        guard case .open = state else { return }
        setSelectedWindowHandle(handle)
        updateWindowDisplays()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: self.environment.selectionDismissDelayNanoseconds)
            guard self.state.isOpen else { return }
            self.dismissToSelection(animated: true)
        }
    }

    @discardableResult
    func closeWindow(_ handle: WindowHandle) -> Bool {
        guard case .open = state else { return false }
        return onCloseWindow?(handle) == true
    }

    func handleManagedWindowRemoved(_ entry: WindowState) {
        guard state.isOpen else { return }
        thumbnailCache.removeValue(forKey: entry.windowId)
        guard let removedHandle = overviewSnapshot.windows.first(where: { $0.value.token == entry.token })?.key else {
            return
        }
        let visibleOrder = canonicalLayout()?.allWindows
            .filter(\.matchesSearch)
            .map(\.handle) ?? []
        guard overviewSnapshot.windows.removeValue(forKey: removedHandle) != nil else { return }

        var nextSelection = selectedWindowHandle
        if selectedWindowHandle == removedHandle {
            nextSelection = Self.selectionAfterRemoving(
                removedHandle,
                from: visibleOrder,
                availableHandles: Set(overviewSnapshot.windows.keys)
            )
            selectedWindowHandle = nextSelection
        }
        if pendingFocusTargetWindow == removedHandle {
            pendingFocusTargetWindow = nextSelection
        }

        refreshCachedOverviewProjection(
            affectedWorkspaceIds: [entry.workspaceId],
            selectedHandle: nextSelection
        )
    }

    static func selectionAfterRemoving(
        _ removedHandle: WindowHandle,
        from visibleOrder: [WindowHandle],
        availableHandles: Set<WindowHandle>
    ) -> WindowHandle? {
        guard let removedIndex = visibleOrder.firstIndex(of: removedHandle) else {
            return visibleOrder.first { availableHandles.contains($0) }
        }
        if removedIndex + 1 < visibleOrder.count,
           let next = visibleOrder[(removedIndex + 1)...].first(where: { availableHandles.contains($0) })
        {
            return next
        }
        return visibleOrder[..<removedIndex].reversed().first { availableHandles.contains($0) }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        inputHandler?.searchQuery = query
        rebuildProjectedLayouts()
        updateWindowDisplays()
    }

    func navigateSelection(_ direction: Direction, on monitorId: Monitor.ID? = nil) {
        guard case .open = state else { return }
        let targetMonitorId = monitorId ?? activeInteractionMonitorId
        if let targetMonitorId {
            activeInteractionMonitorId = targetMonitorId
        }

        guard let layout = canonicalLayout(preferredMonitorId: targetMonitorId) else { return }
        if let nextHandle = OverviewLayoutCalculator.findNextWindow(
            in: layout,
            from: selectedWindowHandle,
            direction: direction
        ) {
            setSelectedWindowHandle(nextHandle)
            revealSelectedWindow(on: targetMonitorId)
            updateWindowDisplays()
        }
    }

    func activateSelectedWindow() {
        guard let selectedWindowHandle else { return }
        selectAndActivateWindow(selectedWindowHandle)
    }

    func dismissToSelection(animated: Bool) {
        guard let selectedWindowHandle,
              overviewSnapshot.windows[selectedWindowHandle] != nil
        else {
            dismiss(reason: .cancel, animated: animated)
            return
        }
        dismiss(reason: .selection, targetWindow: selectedWindowHandle, animated: animated)
    }

    func closeSelectedWindow() {
        guard case .open = state, let selectedWindowHandle else { return }
        closeWindow(selectedWindowHandle)
    }

    func adjustScrollOffset(by delta: CGFloat) {
        guard let monitorId = activeInteractionMonitorId
            ?? wmController?.workspaceManager.monitors.first?.id
        else {
            return
        }
        adjustScrollOffset(by: delta, on: monitorId)
    }

    func adjustScrollOffset(by delta: CGFloat, on monitorId: Monitor.ID) {
        activeInteractionMonitorId = monitorId
        mutateLayout(for: monitorId) { layout in
            let screenFrame = viewportFrame(for: monitorId)
            let nextOffset = layout.scrollOffset + delta
            layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                nextOffset,
                layout: layout,
                screenFrame: screenFrame
            )
        }
        updateWindowDisplays()
    }

    func handleScroll(
        delta: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        isPrecise: Bool,
        on monitorId: Monitor.ID
    ) {
        activeInteractionMonitorId = monitorId

        if modifiers.contains([.option, .shift]) {
            guard abs(delta) > ScrollTuning.zoomEpsilon else { return }
            let step: CGFloat = delta > 0 ? ScrollTuning.zoomStep : -ScrollTuning.zoomStep
            let nextScale = (scale + step).clamped(to: 0.5 ... 1.5)
            guard abs(nextScale - scale) > ScrollTuning.zoomEpsilon else { return }
            let anchors = captureSelectedViewportAnchors()
            scale = nextScale
            rebuildProjectedLayouts(preservingSelectedAnchors: anchors)
            updateWindowDisplays()
            return
        }

        let multiplier = isPrecise
            ? ScrollTuning.preciseScrollMultiplier
            : ScrollTuning.nonPreciseScrollMultiplier
        adjustScrollOffset(by: delta * multiplier, on: monitorId)
    }

    func beginOwnedSession() {
        capturePreviousFrontmostApplication()
        installEventMonitors()
        installApplicationDidResignObserver()
        pendingDismissReason = .cancel
        pendingFocusTargetWindow = nil
    }

    func activateOwnedSession() {
        environment.activateOmniWM()
    }

    func handleApplicationDidResignActive() {
        guard state.isOpen else { return }
        dismiss(reason: .externalDeactivation, animated: true)
    }

    private func cleanup() {
        thumbnailCaptureTask?.cancel()
        thumbnailCaptureTask = nil
        thumbnailCache.removeAll()
        inputHandler?.reset()
        searchQuery = ""
        scale = 1.0
        selectedWindowHandle = nil
        activeInteractionMonitorId = nil
        overviewSnapshot = .init()
        layoutsByMonitor = [:]
        dragGhostController?.endDrag()
        dragGhostController = nil
        dragSession = nil
        activeStructuralTransferGeneration = nil
        projectionMutationGeneration &+= 1
        pendingProjectionWorkspaceIds.removeAll(keepingCapacity: true)
        closeWindows()
    }

    private func capturePreviousFrontmostApplication() {
        guard let frontmostPID = environment.frontmostApplicationPID(),
              frontmostPID != environment.currentProcessID()
        else {
            previousFrontmostApplicationPID = nil
            return
        }

        previousFrontmostApplicationPID = frontmostPID
    }

    private func installEventMonitors() {
        removeEventMonitors()
        keyEventMonitor = environment.addLocalEventMonitor([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.inputHandler?.handleKeyDown(event) == true ? nil : event
        }
        flagsEventMonitor = environment.addLocalEventMonitor([.flagsChanged]) { [weak self] event in
            self?.handleModifierFlagsChanged(event.modifierFlags)
            return event
        }
    }

    private func removeEventMonitors() {
        if let keyEventMonitor {
            environment.removeEventMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        if let flagsEventMonitor {
            environment.removeEventMonitor(flagsEventMonitor)
            self.flagsEventMonitor = nil
        }
    }

    private func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        guard state.isOpen else { return }
        let optionPressed = modifierFlags.contains(.option)
        for window in windows {
            window.cancelPendingDragIfNeeded(optionPressed: optionPressed)
        }
    }

    private func installApplicationDidResignObserver() {
        removeApplicationDidResignObserver()
        applicationDidResignObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationDidResignActive()
            }
        }
    }

    private func removeApplicationDidResignObserver() {
        if let applicationDidResignObserver {
            environment.notificationCenter.removeObserver(applicationDidResignObserver)
            self.applicationDidResignObserver = nil
        }
    }

    private func endOwnedSession() {
        removeEventMonitors()
        removeApplicationDidResignObserver()
        previousFrontmostApplicationPID = nil
        pendingDismissReason = .cancel
        pendingFocusTargetWindow = nil
    }

    private func detectRefreshRate(for displayId: CGDirectDisplayID) -> Double {
        if let mode = CGDisplayCopyDisplayMode(displayId) {
            return mode.refreshRate > 0 ? mode.refreshRate : 60.0
        }
        return 60.0
    }

    private func animationMonitor() -> Monitor? {
        guard let wmController else { return nil }
        if let activeInteractionMonitorId,
           let monitor = wmController.workspaceManager.monitor(byId: activeInteractionMonitorId)
        {
            return monitor
        }
        return wmController.workspaceManager.monitors.first
    }

    private func canonicalLayout(preferredMonitorId: Monitor.ID? = nil) -> OverviewLayout? {
        let monitorId = preferredMonitorId
            ?? activeInteractionMonitorId
            ?? wmController?.workspaceManager.monitors.first?.id
        if let monitorId,
           let layout = layoutsByMonitor[monitorId]
        {
            return layout
        }
        return layoutsByMonitor.values.first
    }

    private func captureSelectedViewportAnchors() -> [Monitor.ID: SelectedViewportAnchor] {
        guard let selectedWindowHandle else { return [:] }

        var anchors: [Monitor.ID: SelectedViewportAnchor] = [:]
        anchors.reserveCapacity(layoutsByMonitor.count)
        for (monitorId, layout) in layoutsByMonitor {
            guard let window = layout.window(for: selectedWindowHandle), window.matchesSearch else { continue }
            anchors[monitorId] = SelectedViewportAnchor(
                handle: selectedWindowHandle,
                midpointY: window.overviewFrame.midY - layout.scrollOffset
            )
        }
        return anchors
    }

    private func restoreSelectedViewportAnchors(_ anchors: [Monitor.ID: SelectedViewportAnchor]) {
        guard let selectedWindowHandle else { return }

        for (monitorId, anchor) in anchors where anchor.handle == selectedWindowHandle {
            mutateLayout(for: monitorId) { layout in
                guard let window = layout.window(for: selectedWindowHandle), window.matchesSearch else { return }
                let screenFrame = viewportFrame(for: monitorId)
                layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
                    window.overviewFrame.midY - anchor.midpointY,
                    layout: layout,
                    screenFrame: screenFrame
                )
            }
        }
    }

    private func revealSelectedWindow(on monitorId: Monitor.ID?) {
        guard let monitorId, let selectedWindowHandle else { return }

        mutateLayout(for: monitorId) { layout in
            guard let window = layout.window(for: selectedWindowHandle), window.matchesSearch else { return }
            layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
                targetFrame: window.overviewFrame,
                currentOffset: layout.scrollOffset,
                layout: layout,
                screenFrame: viewportFrame(for: monitorId)
            )
        }
    }

    private func setSelectedWindowHandle(_ handle: WindowHandle?) {
        selectedWindowHandle = handle
        applySelectedWindowHandleToLayouts()
    }

    private func reconcileSelectedWindowHandle() {
        guard let layout = canonicalLayout(preferredMonitorId: activeInteractionMonitorId) else {
            selectedWindowHandle = nil
            return
        }

        if let selectedWindowHandle,
           let selectedWindow = layout.window(for: selectedWindowHandle),
           selectedWindow.matchesSearch
        {
            return
        }

        selectedWindowHandle = OverviewSearchFilter.firstMatchingWindow(in: layout)?.handle
    }

    private func applySelectedWindowHandleToLayouts() {
        for monitorId in layoutsByMonitor.keys {
            mutateLayout(for: monitorId) { layout in
                layout.setSelected(handle: selectedWindowHandle)
            }
        }
    }

    private func mutateLayout(
        for monitorId: Monitor.ID,
        _ mutate: (inout OverviewLayout) -> Void
    ) {
        guard var layout = layoutsByMonitor[monitorId] else { return }
        mutate(&layout)
        layoutsByMonitor[monitorId] = layout
    }

    private func setDragTarget(_ target: OverviewDragTarget?, for monitorId: Monitor.ID) {
        for id in layoutsByMonitor.keys {
            mutateLayout(for: id) { layout in
                layout.dragTarget = id == monitorId ? target : nil
            }
        }
    }

    private func clearDragTargets() {
        for monitorId in layoutsByMonitor.keys {
            mutateLayout(for: monitorId) { layout in
                layout.dragTarget = nil
            }
        }
    }

    private func viewportFrame(for monitorId: Monitor.ID) -> CGRect {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return .zero
        }
        return OverviewLayoutCalculator.viewportFrame(for: monitor.frame)
    }

    private func globalPoint(from localPoint: CGPoint, on monitorId: Monitor.ID) -> CGPoint {
        guard let wmController,
              let monitor = wmController.workspaceManager.monitor(byId: monitorId)
        else {
            return localPoint
        }
        return CGPoint(
            x: monitor.frame.minX + localPoint.x,
            y: monitor.frame.minY + localPoint.y
        )
    }

    var hasActiveDragSession: Bool {
        dragSession != nil
    }

    deinit {
        MainActor.assumeIsolated {
            endOwnedSession()
            cleanup()
        }
    }
}

private extension OverviewController {
    enum DragMutationOutcome {
        case changed(StructuralMutation)
        case awaitingAdmission(StructuralMutation, OverviewDragTarget)
        case unchanged
    }

    struct DragSession {
        let handle: WindowHandle
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let startPoint: CGPoint
    }
}

extension OverviewController {
    func beginDrag(on monitorId: Monitor.ID, handle: WindowHandle, startPoint: CGPoint) {
        guard case .open = state,
              activeStructuralTransferGeneration == nil,
              let wmController
        else {
            return
        }
        guard let entry = wmController.workspaceManager.entry(for: handle) else { return }

        activeInteractionMonitorId = monitorId
        dragSession = DragSession(
            handle: handle,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            monitorId: monitorId,
            startPoint: startPoint
        )

        if let frame = overviewSnapshot.windows[handle]?.frame {
            if dragGhostController == nil {
                dragGhostController = DragGhostController()
            }
            dragGhostController?.beginDrag(
                windowId: entry.windowId,
                originalFrame: frame,
                cursorLocation: globalPoint(from: startPoint, on: monitorId)
            )
        }
    }

    func updateDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard dragSession != nil else { return }
        activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: globalPoint(from: point, on: monitorId))

        let target = resolveDragTarget(at: point, on: monitorId)
        let currentTarget = layoutsByMonitor[monitorId]?.dragTarget
        if target != currentTarget {
            setDragTarget(target, for: monitorId)
            updateWindowDisplays()
        }
    }

    func endDrag(on monitorId: Monitor.ID, at point: CGPoint) {
        guard case .open = state else {
            cancelDrag()
            return
        }
        guard let session = dragSession else { return }
        activeInteractionMonitorId = monitorId
        dragGhostController?.updatePosition(cursorLocation: globalPoint(from: point, on: monitorId))

        let target = layoutsByMonitor[monitorId]?.dragTarget
        clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil

        guard let target else {
            updateWindowDisplays()
            return
        }

        let outcome = performDragAction(
            session: session,
            target: target
        )
        switch outcome {
        case let .changed(mutation):
            completeStructuralMutation(mutation)
        case let .awaitingAdmission(mutation, deferredTarget):
            completeDeferredDragMutation(mutation, target: deferredTarget)
        case .unchanged:
            updateWindowDisplays()
        }
    }

    static func deferredColumnInsertIndex(
        requestedIndex: Int,
        admittedColumnIndex: Int?
    ) -> Int {
        if let admittedColumnIndex, admittedColumnIndex < requestedIndex {
            return requestedIndex + 1
        }
        return requestedIndex
    }
}

private extension OverviewController {
    func cancelDrag() {
        clearDragTargets()
        dragGhostController?.endDrag()
        dragSession = nil
        updateWindowDisplays()
    }

    func resolveDragTarget(at point: CGPoint, on monitorId: Monitor.ID) -> OverviewDragTarget? {
        guard let layout = layoutsByMonitor[monitorId] else { return nil }
        return layout.resolveDragTarget(at: point, draggedHandle: dragSession?.handle)
    }

    func performDragAction(session: DragSession, target: OverviewDragTarget) -> DragMutationOutcome {
        guard let wmController else { return .unchanged }

        switch target {
        case let .workspaceMove(targetWsId):
            guard targetWsId != session.workspaceId else { return .unchanged }
            guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                handle: session.handle,
                toWorkspaceId: targetWsId
            ) else { return .unchanged }
            return .changed(mutation)

        case let .niriWindowInsert(targetWsId, targetHandle, position):
            guard isNiriLayout(workspaceId: targetWsId) else { return .unchanged }
            var transferMutation: StructuralMutation?
            if targetWsId != session.workspaceId {
                guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                    handle: session.handle,
                    toWorkspaceId: targetWsId
                ) else { return .unchanged }
                transferMutation = mutation
                if !isNiriLayout(workspaceId: session.workspaceId) {
                    return .awaitingAdmission(mutation, target)
                }
            }
            let niriPosition = overviewInsertPositionToNiri(position)
            guard wmController.niriLayoutHandler.insertWindow(
                handle: session.handle,
                targetHandle: targetHandle,
                position: niriPosition,
                in: targetWsId,
                source: .mouse
            ) else {
                return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
            }
            return .changed(
                StructuralMutation(
                    sourceWorkspaceId: session.workspaceId,
                    destinationWorkspaceId: targetWsId,
                    selectedHandle: session.handle,
                    movedTokens: [session.handle.id],
                    scrollWorkspaceId: targetWsId
                )
            )

        case let .niriColumnInsert(targetWsId, insertIndex):
            guard isNiriLayout(workspaceId: targetWsId) else { return .unchanged }
            let shouldInheritSizing = targetWsId != session.workspaceId
                && isNiriLayout(workspaceId: session.workspaceId)
            let sizingPolicy: NiriLayoutEngine.NewContainerSizingPolicy = shouldInheritSizing
                ? .inheritSource
                : .workspaceDefault
            var transferMutation: StructuralMutation?
            if targetWsId != session.workspaceId {
                guard case let .changed(mutation) = wmController.workspaceNavigationHandler.moveWindow(
                    handle: session.handle,
                    toWorkspaceId: targetWsId
                ) else { return .unchanged }
                transferMutation = mutation
                if !isNiriLayout(workspaceId: session.workspaceId) {
                    return .awaitingAdmission(mutation, target)
                }
            }
            guard wmController.niriLayoutHandler.insertWindowInNewColumn(
                handle: session.handle,
                insertIndex: insertIndex,
                in: targetWsId,
                sizingPolicy: sizingPolicy,
                source: .mouse
            ) else {
                return transferMutation.map(DragMutationOutcome.changed) ?? .unchanged
            }
            return .changed(
                StructuralMutation(
                    sourceWorkspaceId: session.workspaceId,
                    destinationWorkspaceId: targetWsId,
                    selectedHandle: session.handle,
                    movedTokens: [session.handle.id],
                    scrollWorkspaceId: targetWsId
                )
            )
        }
    }

    func completeDeferredDragMutation(
        _ mutation: StructuralMutation,
        target: OverviewDragTarget
    ) {
        guard let wmController, activateStructuralDestination(mutation) else { return }
        guard let transferGeneration = beginStructuralTransfer() else { return }
        let projectionGeneration = beginProjectionMutation(
            affectedWorkspaceIds: projectionWorkspaceIds(for: mutation)
        )
        wmController.layoutRefreshController.requestImmediateRelayout(
            reason: .overviewMutation,
            affectedWorkspaceIds: mutation.affectedWorkspaceIds,
            postLayout: { [weak self] in
                self?.applyDeferredDragPlacement(
                    mutation,
                    target: target,
                    transferGeneration: transferGeneration,
                    projectionGeneration: projectionGeneration
                )
            },
            postLayoutInvalidated: { [weak self] in
                self?.finishDeferredDragMutation(
                    mutation,
                    transferGeneration: transferGeneration,
                    projectionGeneration: projectionGeneration
                )
            }
        )
    }

    func applyDeferredDragPlacement(
        _ mutation: StructuralMutation,
        target: OverviewDragTarget,
        transferGeneration: UInt64,
        projectionGeneration: UInt64
    ) {
        guard let wmController,
              case .open = state,
              projectionMutationGeneration == projectionGeneration,
              activeStructuralTransferGeneration == transferGeneration,
              wmController.workspaceManager.workspace(for: mutation.selectedHandle.id)
              == mutation.destinationWorkspaceId
        else {
            finishDeferredDragMutation(
                mutation,
                transferGeneration: transferGeneration,
                projectionGeneration: projectionGeneration
            )
            return
        }

        let inserted: Bool
        switch target {
        case let .niriWindowInsert(workspaceId, targetHandle, position):
            inserted = wmController.niriLayoutHandler.insertWindow(
                handle: mutation.selectedHandle,
                targetHandle: targetHandle,
                position: overviewInsertPositionToNiri(position),
                in: workspaceId,
                source: .mouse
            )
        case let .niriColumnInsert(workspaceId, insertIndex):
            let admittedColumnIndex = wmController.niriEngine
                .flatMap { engine in
                    engine.findNode(for: mutation.selectedHandle, in: workspaceId)
                        .flatMap { engine.findColumn(containing: $0, in: workspaceId) }
                        .flatMap { column in
                            column.windowNodes.count == 1
                                ? engine.columnIndex(of: column, in: workspaceId)
                                : nil
                        }
                }
            let resolvedInsertIndex = Self.deferredColumnInsertIndex(
                requestedIndex: insertIndex,
                admittedColumnIndex: admittedColumnIndex
            )
            inserted = wmController.niriLayoutHandler.insertWindowInNewColumn(
                handle: mutation.selectedHandle,
                insertIndex: resolvedInsertIndex,
                in: workspaceId,
                sizingPolicy: .workspaceDefault,
                source: .mouse
            )
        case .workspaceMove:
            inserted = false
        }

        guard inserted else {
            finishDeferredDragMutation(
                mutation,
                transferGeneration: transferGeneration,
                projectionGeneration: projectionGeneration
            )
            return
        }
        wmController.layoutRefreshController.requestImmediateRelayout(
            reason: .overviewMutation,
            affectedWorkspaceIds: mutation.affectedWorkspaceIds,
            postLayout: { [weak self] in
                self?.finishDeferredDragMutation(
                    mutation,
                    transferGeneration: transferGeneration,
                    projectionGeneration: projectionGeneration
                )
            },
            postLayoutInvalidated: { [weak self] in
                self?.finishDeferredDragMutation(
                    mutation,
                    transferGeneration: transferGeneration,
                    projectionGeneration: projectionGeneration
                )
            }
        )
        wmController.layoutRefreshController.startScrollAnimation(for: mutation.destinationWorkspaceId)
    }

    func finishDeferredDragMutation(
        _ mutation: StructuralMutation,
        transferGeneration: UInt64,
        projectionGeneration: UInt64
    ) {
        defer { finishStructuralTransfer(transferGeneration) }
        guard self.projectionMutationGeneration == projectionGeneration else { return }
        synchronizeStructuralSelection(mutation)
        pendingProjectionWorkspaceIds.formUnion(projectionWorkspaceIds(for: mutation))
        let affectedWorkspaceIds = pendingProjectionWorkspaceIds
        pendingProjectionWorkspaceIds.removeAll(keepingCapacity: true)
        refreshCachedOverviewProjection(
            affectedWorkspaceIds: affectedWorkspaceIds
        )
    }

    func isNiriLayout(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let wmController else { return false }
        guard let name = wmController.workspaceManager.descriptor(for: workspaceId)?.name else { return false }
        let layoutType = wmController.settings.layoutType(for: name)
        return layoutType != .dwindle
    }

    func overviewInsertPositionToNiri(_ position: InsertPosition) -> InsertPosition {
        switch position {
        case .before:
            return .after
        case .after:
            return .before
        case .swap:
            return .swap
        }
    }
}
