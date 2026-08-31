// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class CommandHandler {
    weak var controller: WMController?
    var nativeFullscreenStateProvider: ((AXWindowRef) -> Bool)?
    var nativeFullscreenSetter: ((AXWindowRef, Bool) -> Bool)?
    var frontmostAppPidProvider: (() -> pid_t?)?
    var frontmostFocusedWindowTokenProvider: (() -> WindowToken?)?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func handleHotkeyInvocation(_ invocation: HotkeyInvocation) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        if invocation.command == .toggleOverview, invocation.trigger?.isRepeat == true {
            return .executed
        }
        switch controller.handleOverviewHotkey(invocation) {
        case .handled:
            return .executed
        case .blocked:
            return .ignoredOverview
        case .inactive:
            return performCommand(invocation.command)
        }
    }

    @discardableResult
    func performCommand(_ command: HotkeyCommand) -> ExternalCommandResult {
        guard let controller else { return .notFound }
        guard controller.isEnabled else { return .ignoredDisabled }
        guard !Self.shouldIgnoreCommand(command, isOverviewOpen: controller.isOverviewOpen()) else {
            return .ignoredOverview
        }

        let layoutType = currentLayoutType()

        switch (command.layoutCompatibility, layoutType) {
        case (.niri, .dwindle),
             (.dwindle, .niri),
             (.dwindle, .defaultLayout):
            return .ignoredLayoutMismatch
        default:
            break
        }

        switch command {
        case let .focus(direction):
            focusWindow(direction: direction)
        case .focusPrevious:
            focusPreviousInNiri()
        case let .move(direction):
            let outcome = moveWindow(direction: direction)
            if outcome == .atWorkspaceEdge, controller.settings.moveCrossesMonitorAtEdge {
                controller.workspaceNavigationHandler.moveWindowAcrossMonitorAtEdge(direction: direction)
            }
        case let .moveWindowToMonitor(direction):
            controller.workspaceNavigationHandler.moveWindowToMonitor(direction: direction)
        case .moveWindowDown:
            moveWindowWithinContainer(direction: .down)
        case .moveWindowUp:
            moveWindowWithinContainer(direction: .up)
        case .moveWindowDownOrToWorkspaceDown:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .down)
        case .moveWindowUpOrToWorkspaceUp:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .up)
        case .consumeOrExpelWindowLeft:
            controller.niriLayoutHandler.consumeOrExpelWindow(direction: .left)
        case .consumeOrExpelWindowRight:
            controller.niriLayoutHandler.consumeOrExpelWindow(direction: .right)
        case .consumeWindowIntoColumn:
            controller.niriLayoutHandler.consumeWindowIntoColumn()
        case .expelWindowFromColumn:
            controller.niriLayoutHandler.expelWindowFromColumn()
        case let .moveToWorkspace(index):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveWindowToWorkspaceUp:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveWindowToWorkspaceDown:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        case let .moveColumnToWorkspace(index):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index)
        case .moveColumnToWorkspaceUp:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .up)
        case .moveColumnToWorkspaceDown:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down)
        case let .switchWorkspace(index):
            controller.workspaceNavigationHandler.switchWorkspace(index: index)
        case .switchWorkspaceNext:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        case .switchWorkspacePrevious:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: false)
        case .focusMonitorPrevious:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true)
        case .focusMonitorNext:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)
        case .focusMonitorLast:
            controller.workspaceNavigationHandler.focusLastMonitor()
        case .toggleFullscreen:
            toggleFullscreen()
        case .toggleNativeFullscreen:
            toggleNativeFullscreenForFocused()
        case let .moveColumn(direction):
            moveContainer(direction: direction)
        case .moveColumnToFirst:
            controller.niriLayoutHandler.moveColumnToFirst()
        case .moveColumnToLast:
            controller.niriLayoutHandler.moveColumnToLast()
        case let .moveColumnToIndex(index):
            controller.niriLayoutHandler.moveColumn(toOneBasedIndex: index)
        case .toggleColumnTabbed:
            toggleColumnTabbedInNiri()
        case .focusDownOrLeft:
            focusDownOrLeftInNiri()
        case .focusUpOrRight:
            focusUpOrRightInNiri()
        case let .focusWindowInColumn(index):
            focusWindowInColumnInNiri(index: index)
        case .focusWindowTop:
            focusWindowTopInNiri()
        case .focusWindowBottom:
            focusWindowBottomInNiri()
        case .focusWindowDownOrTop:
            focusWindowWrapping(direction: .down)
        case .focusWindowUpOrBottom:
            focusWindowWrapping(direction: .up)
        case .focusWindowOrWorkspaceDown:
            focusWindowOrWorkspaceInNiri(direction: .down)
        case .focusWindowOrWorkspaceUp:
            focusWindowOrWorkspaceInNiri(direction: .up)
        case .focusColumnFirst:
            focusColumnFirstInNiri()
        case .focusColumnLast:
            focusColumnLastInNiri()
        case let .focusColumn(index):
            focusColumnInNiri(index: index)
        case .centerColumn:
            controller.niriLayoutHandler.centerColumn()
        case .centerVisibleColumns:
            controller.niriLayoutHandler.centerVisibleColumns()
        case .cycleSizeForward:
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: true)
        case .cycleSizeBackward:
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: false)
        case .cycleWindowPrimarySpanForward:
            controller.niriLayoutHandler.cycleWindowPrimarySpan(forward: true)
        case .cycleWindowPrimarySpanBackward:
            controller.niriLayoutHandler.cycleWindowPrimarySpan(forward: false)
        case .cycleWindowSecondarySpanForward:
            controller.niriLayoutHandler.cycleWindowSecondarySpan(forward: true)
        case .cycleWindowSecondarySpanBackward:
            controller.niriLayoutHandler.cycleWindowSecondarySpan(forward: false)
        case .toggleContainerFullPrimarySpan:
            controller.niriLayoutHandler.toggleContainerFullPrimarySpan()
        case .expandContainerToAvailablePrimarySpan:
            controller.niriLayoutHandler.expandContainerToAvailablePrimarySpan()
        case .resetWindowSecondarySpan:
            controller.niriLayoutHandler.resetWindowSecondarySpan()
        case let .setContainerPrimarySpan(change):
            controller.niriLayoutHandler.setContainerPrimarySpan(change)
        case let .setWindowPrimarySpan(change):
            controller.niriLayoutHandler.setWindowPrimarySpan(change)
        case let .setWindowSecondarySpan(change):
            controller.niriLayoutHandler.setWindowSecondarySpan(change)
        case let .moveWorkspaceToMonitor(direction):
            if let workspaceId = controller.activeWorkspace()?.id {
                _ = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
                    workspaceId,
                    direction: direction,
                    force: true
                )
            }
        case let .swapWorkspaceWithMonitor(direction):
            controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .balanceSizes:
            layoutHandler(as: LayoutSizable.self)?.balanceSizes()
        case .moveToRoot:
            moveToRootInDwindle()
        case .toggleSplit:
            toggleSplitInDwindle()
        case .swapSplit:
            swapSplitInDwindle()
        case let .resizeAlongAxis(orientation, grow):
            resizeAlongAxisInDwindle(orientation: orientation, grow: grow)
        case let .resizeFocusedWindow(grow):
            resizeFocusedWindowInDwindle(grow: grow)
        case let .preselect(direction):
            preselectInDwindle(direction: direction)
        case .preselectClear:
            clearPreselectInDwindle()
        case .workspaceBackAndForth:
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        case .openCommandPalette:
            controller.openCommandPalette()
        case .raiseAllFloatingWindows:
            controller.raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            _ = controller.rescueOffscreenWindows()
        case .toggleFocusedWindowFloating:
            return controller.toggleFocusedWindowFloating()
        case let .assignFocusedWindowToScratchpad(index):
            guard let index = ScratchpadIndex(index) else { return .invalidArguments }
            return controller.assignFocusedWindowToScratchpad(index)
        case let .toggleScratchpad(index):
            guard let index = ScratchpadIndex(index) else { return .invalidArguments }
            return controller.toggleScratchpad(index)
        case .openMenuAnywhere:
            controller.openMenuAnywhere()
        case .toggleWorkspaceBarVisibility:
            controller.toggleWorkspaceBarVisibility()
        case .toggleHiddenBarPanel:
            controller.toggleHiddenBarPanel()
        case .toggleQuakeTerminal:
            controller.toggleQuakeTerminal()
        case .toggleWorkspaceLayout:
            toggleWorkspaceLayout()
        case .toggleOverview:
            controller.toggleOverview()
        case .toggleSystemStats:
            controller.toggleSystemStats()
        }

        return .executed
    }

    static func shouldIgnoreCommand(_: HotkeyCommand, isOverviewOpen: Bool) -> Bool {
        isOverviewOpen
    }

    private func layoutHandler<T>(as capability: T.Type) -> T? {
        guard let controller else { return nil }
        let layoutType = currentLayoutType()
        let handler: AnyObject = switch layoutType {
        case .dwindle:
            controller.layoutRefreshController.dwindleHandler
        case .niri,
             .defaultLayout:
            controller.layoutRefreshController.niriHandler
        }
        return handler as? T
    }

    private func focusPreviousInNiri() {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        let anchor = focusHistoryAnchor(
            controller: controller,
            engine: engine,
            fallbackWorkspaceId: wsId
        )
        if let anchor {
            _ = controller.workspaceManager.rememberFocus(
                anchor.token,
                in: anchor.workspaceId
            )
            if let nodeId = anchor.nodeId {
                controller.workspaceManager.withEngineMutationScope {
                    engine.updateFocusTimestamp(for: nodeId, in: anchor.workspaceId)
                }
            }
            if let target = controller.workspaceManager.mostRecentlyFocusedTiledToken(excluding: anchor.token),
               let targetWorkspaceId = controller.workspaceManager.entry(for: target)?.workspaceId,
               controller.windowActionHandler.navigateToWindowInternal(
                   token: target,
                   workspaceId: targetWorkspaceId
               )
            {
                return
            }
            if anchor.representsCurrentFocus {
                _ = focusGloballyPreviousNiriWindowIfNeeded(
                    controller: controller,
                    engine: engine,
                    anchor: anchor
                )
                return
            }
        }
        if focusGloballyPreviousNiriWindowIfNeeded(
            controller: controller,
            engine: engine,
            anchor: anchor
        ) {
            return
        }

        focusPreviousInCurrentNiriWorkspace(
            controller: controller,
            engine: engine,
            workspaceId: wsId
        )
    }

    private func focusPreviousInCurrentNiriWorkspace(
        controller: WMController,
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let monitor = controller.workspaceManager.monitor(for: workspaceId) else { return }
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let motion = controller.motionPolicy.snapshot()
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let gaps = controller.innerGap(for: monitor)
        let orientation = controller.settings.effectiveOrientation(for: monitor)

        let previousWindow = controller.workspaceManager.withEngineMutationScope { () -> NiriWindow? in
            if let selected = engine.reconcileProjectedSelection(state: &state, in: workspaceId) {
                let currentId = selected.id
                engine.updateFocusTimestamp(for: currentId, in: workspaceId)
                engine.activateWindow(currentId, in: workspaceId)
            }

            return engine.focusPrevious(
                currentNodeId: state.selectedNodeId,
                in: workspaceId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation,
                limitToWorkspace: true
            )
        }
        guard let previousWindow else { return }

        controller.niriLayoutHandler.activateNode(
            previousWindow, in: workspaceId, state: &state,
            options: .init(
                ensureVisible: false,
                updateTimestamp: false,
                layoutRefresh: false,
                axFocus: false,
                startAnimation: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(in: workspaceId)

        if controller.workspaceManager.animationDriver.hasMotion(in: workspaceId) {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
    }

    private func focusGloballyPreviousNiriWindowIfNeeded(
        controller: WMController,
        engine: NiriLayoutEngine,
        anchor: FocusHistoryAnchor?
    ) -> Bool {
        guard let anchor,
              let nodeId = anchor.nodeId,
              !controller.workspaceManager.isAppHidden(anchor.token),
              let target = engine.findMostRecentlyFocusedWindow(excluding: nodeId, in: nil),
              let targetWorkspaceId = controller.workspaceManager.entry(for: target.token)?.workspaceId,
              targetWorkspaceId != anchor.workspaceId
        else {
            return false
        }

        controller.workspaceManager.withEngineMutationScope {
            engine.updateFocusTimestamp(for: nodeId, in: anchor.workspaceId)
            engine.activateWindow(nodeId, in: anchor.workspaceId)
        }
        controller.windowActionHandler.navigateToWindowInternal(
            token: target.token,
            workspaceId: targetWorkspaceId
        )
        return true
    }

    private func focusHistoryAnchor(
        controller: WMController,
        engine: NiriLayoutEngine,
        fallbackWorkspaceId: WorkspaceDescriptor.ID
    ) -> FocusHistoryAnchor? {
        let frontmostPid = frontmostAppPidProvider?()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let observedToken = frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }

        if let observedToken,
           let entry = controller.workspaceManager.entry(for: observedToken),
           !controller.workspaceManager.isAppHidden(pid: entry.pid)
        {
            return FocusHistoryAnchor(
                workspaceId: entry.workspaceId,
                token: observedToken,
                nodeId: engine.findNode(for: observedToken, in: entry.workspaceId)?.id,
                representsCurrentFocus: true
            )
        }

        if let token = controller.workspaceManager.selectedManagedToken,
           let entry = controller.workspaceManager.entry(for: token),
           !controller.workspaceManager.isAppHidden(pid: entry.pid)
        {
            return FocusHistoryAnchor(
                workspaceId: entry.workspaceId,
                token: token,
                nodeId: engine.findNode(for: token, in: entry.workspaceId)?.id,
                representsCurrentFocus: true
            )
        }

        let selectedNodeId = controller.workspaceManager
            .niriViewportState(for: fallbackWorkspaceId)
            .selectedNodeId
        guard let selectedNodeId,
              let node = engine.findNode(by: selectedNodeId, in: fallbackWorkspaceId) as? NiriWindow,
              !engine.isExcludedFromProjection(node.token, in: fallbackWorkspaceId)
        else {
            return nil
        }
        return FocusHistoryAnchor(
            workspaceId: fallbackWorkspaceId,
            token: node.token,
            nodeId: node.id,
            representsCurrentFocus: false
        )
    }

    private struct FocusHistoryAnchor {
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let nodeId: NodeId?
        let representsCurrentFocus: Bool
    }

    private func focusDownOrLeftInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusDownOrLeft(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusUpOrRightInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusUpOrRight(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowInColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusWindowInColumn(
                index,
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowTopInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusWindowTop(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusWindowBottom(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowDownOrTopInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusWindowDownOrTop(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowUpOrBottomInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusWindowUpOrBottom(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusWindowOrWorkspaceInNiri(direction: Direction) {
        guard direction == .down || direction == .up else { return }
        executeCombinedNavigation(onNoTarget: { [weak self] in
            self?.controller?.workspaceNavigationHandler.switchWorkspaceRelative(
                isNext: direction == .down,
                wrapAround: false
            )
        }) { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusTarget(
                direction: direction,
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusColumnFirstInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusColumnFirst(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusColumnLastInNiri() {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusColumnLast(
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func focusColumnInNiri(index: Int) {
        executeCombinedNavigation { engine, currentNode, wsId, motion, state, workingFrame, gaps, orientation in
            engine.focusColumn(
                index,
                currentSelection: currentNode,
                in: wsId,
                motion: motion,
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps,
                orientation: orientation
            )
        }
    }

    private func executeCombinedNavigation(
        onNoTarget: (() -> Void)? = nil,
        _ navigationAction: (
            NiriLayoutEngine,
            NiriNode,
            WorkspaceDescriptor.ID,
            MotionSnapshot,
            inout ViewportState,
            CGRect,
            CGFloat,
            Monitor.Orientation
        )
            -> NiriNode?
    ) {
        guard let controller else { return }
        guard let engine = controller.niriEngine else { return }
        guard let wsId = controller.activeWorkspace()?.id else { return }
        guard let monitor = controller.workspaceManager.monitor(for: wsId) else { return }

        var state = controller.workspaceManager.niriViewportState(for: wsId)
        let currentNode: NiriNode
        if let currentId = state.selectedNodeId,
           let node = engine.findNode(by: currentId, in: wsId)
        {
            currentNode = node
        } else if let lastFocused = controller.workspaceManager.lastFocusedToken(in: wsId),
                  let node = engine.findNode(for: lastFocused, in: wsId)
        {
            state.selectedNodeId = node.id
            currentNode = node
        } else if let selectedId = engine.validateSelection(state.selectedNodeId, in: wsId),
                  let node = engine.findNode(by: selectedId, in: wsId)
        {
            state.selectedNodeId = selectedId
            currentNode = node
        } else {
            onNoTarget?()
            return
        }

        let gap = controller.innerGap(for: monitor)
        let workingFrame = controller.insetWorkingFrame(for: monitor)
        let motion = controller.motionPolicy.snapshot()
        let orientation = controller.settings.effectiveOrientation(for: monitor)
        guard let newNode = controller.workspaceManager.withEngineMutationScope(label: "focus_navigation", {
            navigationAction(engine, currentNode, wsId, motion, &state, workingFrame, gap, orientation)
        }) else {
            onNoTarget?()
            return
        }
        controller.niriLayoutHandler.activateNode(
            newNode, in: wsId, state: &state,
            options: .init(
                activateWindow: false,
                ensureVisible: false,
                layoutRefresh: false,
                axFocus: false
            )
        )
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: state,
                rememberedFocusToken: nil,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.niriLayoutHandler.focusSelectedWindowAndRequestRelayout(in: wsId)
    }

    private func moveWindow(direction: Direction) -> WindowMoveOutcome {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.moveWindow(direction: direction) ?? .blocked
        case .niri,
             .defaultLayout:
            moveWindowInNiri(direction: direction)
        }
    }

    private func focusWindow(direction: Direction) {
        guard let controller else { return }
        switch currentLayoutType() {
        case .dwindle:
            if controller.dwindleLayoutHandler.focusNeighbor(direction: direction) {
                return
            }
            if controller.settings.focusCrossesMonitorAtEdge,
               controller.workspaceNavigationHandler.focusMonitor(direction: direction)
            {
                return
            }
            _ = controller.dwindleLayoutHandler.wrapGroupFocus(direction: direction)
        case .niri,
             .defaultLayout:
            if controller.niriLayoutHandler.focusNeighbor(direction: direction) != true,
               controller.settings.focusCrossesMonitorAtEdge
            {
                _ = controller.workspaceNavigationHandler.focusMonitor(direction: direction)
            }
        }
    }

    private func moveWindowWithinContainer(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.moveGroupMember(direction: direction)
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.moveWindowWithinContainer(direction: direction)
        }
    }

    private func moveContainer(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            _ = controller?.dwindleLayoutHandler.swapWindow(direction: direction)
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.moveColumn(direction: direction)
        }
    }

    private func focusWindowWrapping(direction: Direction) {
        switch currentLayoutType() {
        case .dwindle:
            _ = controller?.dwindleLayoutHandler.wrapGroupFocus(direction: direction)
        case .niri,
             .defaultLayout:
            if direction == .down {
                focusWindowDownOrTopInNiri()
            } else if direction == .up {
                focusWindowUpOrBottomInNiri()
            }
        }
    }

    private func toggleFullscreen() {
        switch currentLayoutType() {
        case .dwindle:
            controller?.dwindleLayoutHandler.toggleFullscreen()
        case .niri,
             .defaultLayout:
            controller?.niriLayoutHandler.toggleFullscreen()
        }
    }

    private func moveWindowInNiri(direction: Direction) -> WindowMoveOutcome {
        controller?.niriLayoutHandler.moveWindow(direction: direction) ?? .blocked
    }

    private func toggleNativeFullscreenForFocused() {
        guard let controller else { return }
        let setFullscreen = nativeFullscreenSetter ?? { axRef, fullscreen in
            AXWindowService.setNativeFullscreen(axRef, fullscreen: fullscreen)
        }
        let isFullscreen = nativeFullscreenStateProvider ?? { axRef in
            AXWindowService.isFullscreen(axRef)
        }

        if let token = controller.workspaceManager.selectedManagedToken,
           let entry = controller.workspaceManager.entry(for: token),
           !controller.workspaceManager.isAppHidden(pid: entry.pid)
        {
            let currentState = isFullscreen(entry.axRef)
            if currentState {
                applyNativeFullscreenExit(
                    token,
                    axRef: entry.axRef,
                    controller: controller,
                    setter: setFullscreen
                )
                return
            }

            guard controller.workspaceManager.requestNativeFullscreenEnter(token, in: entry.workspaceId) else {
                return
            }
            guard setFullscreen(entry.axRef, true) else {
                controller.workspaceManager.restoreNativeFullscreenRecord(for: token)
                return
            }
            return
        }

        guard controller.workspaceManager.isAppFullscreenActive
            || controller.workspaceManager.hasPendingNativeFullscreenTransition
        else {
            return
        }

        let frontmostPid = frontmostAppPidProvider?() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostToken = frontmostFocusedWindowTokenProvider?()
            ?? frontmostPid.flatMap { controller.axEventHandler.focusedWindowToken(for: $0) }
        guard let token = controller.workspaceManager.nativeFullscreenCommandTarget(frontmostToken: frontmostToken),
              let entry = controller.workspaceManager.entry(for: token),
              !controller.workspaceManager.isAppHidden(pid: entry.pid)
        else {
            return
        }

        applyNativeFullscreenExit(
            token,
            axRef: entry.axRef,
            controller: controller,
            setter: setFullscreen
        )
    }

    private func applyNativeFullscreenExit(
        _ token: WindowToken,
        axRef: AXWindowRef,
        controller: WMController,
        setter: (AXWindowRef, Bool) -> Bool
    ) {
        guard controller.workspaceManager.requestNativeFullscreenExit(token) else { return }
        if !setter(axRef, false) {
            _ = controller.workspaceManager.markNativeFullscreenSuspended(token)
        }
    }

    private func toggleColumnTabbedInNiri() {
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, motion, state, _, _, _, orientation in
            if engine.toggleColumnTabbed(
                in: wsId,
                state: state,
                motion: motion,
                orientation: orientation
            ) {
                controller.workspaceManager.recordReconcileEvent(
                    .layoutOperationPerformed(workspaceId: wsId, operation: .displayModeChanged, source: .command)
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
            }
        }
    }

    private func currentLayoutType() -> LayoutType {
        guard let controller else { return .niri }
        guard let ws = controller.activeWorkspace() else { return .niri }
        return controller.settings.layoutType(for: ws.name)
    }

    private func moveToRootInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let stable = controller.settings.dwindleMoveToRootStable
            if engine.moveSelectionToRoot(stable: stable, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.windowMovedToRoot, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func toggleSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.toggleOrientation(in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitOrientationToggled, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func swapSplitInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.swapSplit(in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitSwapped, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func resizeAlongAxisInDwindle(orientation: DwindleOrientation, grow: Bool) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            if engine.resizeSelected(by: delta, orientation: orientation, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func resizeFocusedWindowInDwindle(grow: Bool) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            if engine.resizeFocusedWindow(by: delta, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func preselectInDwindle(direction: Direction) {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.setPreselection(direction, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
            }
        }
    }

    private func clearPreselectInDwindle() {
        guard let controller else { return }
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            if engine.setPreselection(nil, in: wsId) {
                controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
            }
        }
    }

    private func toggleWorkspaceLayout() {
        guard let controller else { return }
        guard let workspace = controller.activeWorkspace() else { return }
        let workspaceName = workspace.name

        let currentLayout = controller.settings.layoutType(for: workspaceName)

        let newLayout: LayoutType = switch currentLayout {
        case .niri,
             .defaultLayout: .dwindle
        case .dwindle: .niri
        }

        _ = setWorkspaceLayout(newLayout, forWorkspaceNamed: workspaceName)
    }

    @discardableResult
    func setWorkspaceLayout(_ newLayout: LayoutType, forWorkspaceNamed workspaceName: String? = nil) -> Bool {
        guard let controller else { return false }
        let resolvedWorkspaceName = workspaceName ?? controller.activeWorkspace()?.name
        guard let resolvedWorkspaceName else { return false }

        var configs = controller.settings.workspaceConfigurations
        guard let index = configs.firstIndex(where: { $0.name == resolvedWorkspaceName }) else { return false }

        guard configs[index].layoutType != newLayout else { return false }

        configs[index] = configs[index].with(layoutType: newLayout)
        controller.settings.workspaceConfigurations = configs
        controller.layoutRefreshController.requestRelayout(reason: .workspaceLayoutToggled)
        if let ipcApplicationBridge = controller.ipcApplicationBridge {
            Task {
                await ipcApplicationBridge.publishEvent(.layoutChanged)
            }
        }
        return true
    }
}
