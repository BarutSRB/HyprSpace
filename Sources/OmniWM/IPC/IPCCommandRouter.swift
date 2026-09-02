// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import OmniWMIPC

@MainActor
final class IPCCommandRouter {
    let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCCommandRequest) -> ExternalCommandResult {
        switch request {
        case let .focus(ipcDirection):
            return controller.commandHandler.performCommand(.focus(direction(for: ipcDirection)))
        case .focusPrevious:
            return controller.commandHandler.performCommand(.focusPrevious)
        case .focusDownOrLeft:
            return controller.commandHandler.performCommand(.focusDownOrLeft)
        case .focusUpOrRight:
            return controller.commandHandler.performCommand(.focusUpOrRight)
        case let .focusWindowInColumn(windowIndex):
            guard windowIndex >= 0 else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.focusWindowInColumn(windowIndex))
        case .focusWindowTop:
            return controller.commandHandler.performCommand(.focusWindowTop)
        case .focusWindowBottom:
            return controller.commandHandler.performCommand(.focusWindowBottom)
        case .focusWindowDownOrTop:
            return controller.commandHandler.performCommand(.focusWindowDownOrTop)
        case .focusWindowUpOrBottom:
            return controller.commandHandler.performCommand(.focusWindowUpOrBottom)
        case .focusWindowOrWorkspaceDown:
            return controller.commandHandler.performCommand(.focusWindowOrWorkspaceDown)
        case .focusWindowOrWorkspaceUp:
            return controller.commandHandler.performCommand(.focusWindowOrWorkspaceUp)
        case let .focusColumn(columnIndex):
            guard let zeroBasedIndex = zeroBasedIndex(from: columnIndex) else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.focusColumn(zeroBasedIndex))
        case .focusColumnFirst:
            return controller.commandHandler.performCommand(.focusColumnFirst)
        case .focusColumnLast:
            return controller.commandHandler.performCommand(.focusColumnLast)
        case .centerColumn:
            return controller.commandHandler.performCommand(.centerColumn)
        case .centerVisibleColumns:
            return controller.commandHandler.performCommand(.centerVisibleColumns)
        case let .move(ipcDirection):
            return controller.commandHandler.performCommand(.move(direction(for: ipcDirection)))
        case .moveWindowDown:
            return controller.commandHandler.performCommand(.moveWindowDown)
        case .moveWindowUp:
            return controller.commandHandler.performCommand(.moveWindowUp)
        case .moveWindowDownOrToWorkspaceDown:
            return controller.commandHandler.performCommand(.moveWindowDownOrToWorkspaceDown)
        case .moveWindowUpOrToWorkspaceUp:
            return controller.commandHandler.performCommand(.moveWindowUpOrToWorkspaceUp)
        case .consumeOrExpelWindowLeft:
            return controller.commandHandler.performCommand(.consumeOrExpelWindowLeft)
        case .consumeOrExpelWindowRight:
            return controller.commandHandler.performCommand(.consumeOrExpelWindowRight)
        case .consumeWindowIntoColumn:
            return controller.commandHandler.performCommand(.consumeWindowIntoColumn)
        case .expelWindowFromColumn:
            return controller.commandHandler.performCommand(.expelWindowFromColumn)
        case let .switchWorkspace(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspace(to: target)
        case .switchWorkspaceNext:
            return switchWorkspace(using: .switchWorkspaceNext)
        case .switchWorkspacePrevious:
            return switchWorkspace(using: .switchWorkspacePrevious)
        case .switchWorkspaceBackAndForth:
            return switchWorkspace(using: .workspaceBackAndForth)
        case let .switchWorkspaceAnywhere(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return switchWorkspaceAnywhere(to: target)
        case let .moveToWorkspace(workspaceNumber):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(to: target)
        case .moveToWorkspaceUp:
            return moveFocusedWindow(using: .moveWindowToWorkspaceUp)
        case .moveToWorkspaceDown:
            return moveFocusedWindow(using: .moveWindowToWorkspaceDown)
        case let .moveToWorkspaceOnMonitor(workspaceNumber, ipcDirection):
            guard let target = workspaceTarget(from: workspaceNumber) else {
                return .invalidArguments
            }
            return moveFocusedWindow(
                to: target,
                onMonitor: direction(for: ipcDirection)
            )
        case let .moveToMonitor(ipcDirection):
            return moveFocusedWindowToMonitor(direction(for: ipcDirection))
        case .focusMonitorPrevious:
            return focusMonitor(previous: true)
        case .focusMonitorNext:
            return focusMonitor(previous: false)
        case .focusMonitorLast:
            return focusLastMonitor()
        case let .moveColumn(ipcDirection):
            return controller.commandHandler.performCommand(.moveColumn(direction(for: ipcDirection)))
        case .moveColumnToFirst:
            return controller.commandHandler.performCommand(.moveColumnToFirst)
        case .moveColumnToLast:
            return controller.commandHandler.performCommand(.moveColumnToLast)
        case let .moveColumnToIndex(columnIndex):
            guard columnIndex >= 0 else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.moveColumnToIndex(columnIndex))
        case let .moveColumnToWorkspace(workspaceNumber):
            guard let workspaceIndex = zeroBasedIndex(from: workspaceNumber) else {
                return .invalidArguments
            }
            return controller.commandHandler.performCommand(.moveColumnToWorkspace(workspaceIndex))
        case .moveColumnToWorkspaceUp:
            return controller.commandHandler.performCommand(.moveColumnToWorkspaceUp)
        case .moveColumnToWorkspaceDown:
            return controller.commandHandler.performCommand(.moveColumnToWorkspaceDown)
        case .toggleColumnTabbed:
            return controller.commandHandler.performCommand(.toggleColumnTabbed)
        case .cycleSizeForward:
            return controller.commandHandler.performCommand(.cycleSizeForward)
        case .cycleSizeBackward:
            return controller.commandHandler.performCommand(.cycleSizeBackward)
        case .cycleWindowPrimarySpanForward:
            return controller.commandHandler.performCommand(.cycleWindowPrimarySpanForward)
        case .cycleWindowPrimarySpanBackward:
            return controller.commandHandler.performCommand(.cycleWindowPrimarySpanBackward)
        case .cycleWindowSecondarySpanForward:
            return controller.commandHandler.performCommand(.cycleWindowSecondarySpanForward)
        case .cycleWindowSecondarySpanBackward:
            return controller.commandHandler.performCommand(.cycleWindowSecondarySpanBackward)
        case .toggleContainerFullPrimarySpan:
            return controller.commandHandler.performCommand(.toggleContainerFullPrimarySpan)
        case .expandContainerToAvailablePrimarySpan:
            return controller.commandHandler.performCommand(.expandContainerToAvailablePrimarySpan)
        case .resetWindowSecondarySpan:
            return controller.commandHandler.performCommand(.resetWindowSecondarySpan)
        case let .setContainerPrimarySpan(change):
            return controller.commandHandler.performCommand(.setContainerPrimarySpan(sizeChange(for: change)))
        case let .setWindowPrimarySpan(change):
            return controller.commandHandler.performCommand(.setWindowPrimarySpan(sizeChange(for: change)))
        case let .setWindowSecondarySpan(change):
            return controller.commandHandler.performCommand(.setWindowSecondarySpan(sizeChange(for: change)))
        case let .swapWorkspaceWithMonitor(ipcDirection):
            return swapWorkspaceWithMonitor(direction: direction(for: ipcDirection))
        case .balanceSizes:
            return controller.commandHandler.performCommand(.balanceSizes)
        case .moveToRoot:
            return controller.commandHandler.performCommand(.moveToRoot)
        case .toggleSplit:
            return controller.commandHandler.performCommand(.toggleSplit)
        case .swapSplit:
            return controller.commandHandler.performCommand(.swapSplit)
        case let .resize(axis, operation):
            return controller.commandHandler.performCommand(
                .resizeAlongAxis(dwindleOrientation(for: axis), operation == .grow)
            )
        case let .resizeFocused(operation):
            return controller.commandHandler.performCommand(.resizeFocusedWindow(operation == .grow))
        case let .preselect(ipcDirection):
            return controller.commandHandler.performCommand(.preselect(direction(for: ipcDirection)))
        case .preselectClear:
            return controller.commandHandler.performCommand(.preselectClear)
        case .openCommandPalette:
            return controller.commandHandler.performCommand(.openCommandPalette)
        case .raiseAllFloatingWindows:
            return raiseAllFloatingWindows()
        case .rescueOffscreenWindows:
            return rescueOffscreenWindows()
        case .toggleWorkspaceLayout:
            return controller.commandHandler.performCommand(.toggleWorkspaceLayout)
        case let .setWorkspaceLayout(layout):
            if let guardResult = validateControllerState() {
                return guardResult
            }
            return controller.commandHandler.setWorkspaceLayout(layoutType(for: layout)) ? .executed : .noChange
        case .toggleFullscreen:
            return controller.commandHandler.performCommand(.toggleFullscreen)
        case .toggleNativeFullscreen:
            return controller.commandHandler.performCommand(.toggleNativeFullscreen)
        case .toggleOverview:
            return controller.commandHandler.performCommand(.toggleOverview)
        case .toggleSystemStats:
            return controller.commandHandler.performCommand(.toggleSystemStats)
        case .toggleQuakeTerminal:
            return controller.commandHandler.performCommand(.toggleQuakeTerminal)
        case .toggleWorkspaceBar:
            return controller.commandHandler.performCommand(.toggleWorkspaceBarVisibility)
        case .hiddenBarPanel:
            return controller.commandHandler.performCommand(.toggleHiddenBarPanel)
        case .toggleFocusedWindowFloating:
            return toggleFocusedWindowFloating()
        case let .scratchpadAssign(index):
            return assignFocusedWindowToScratchpad(index)
        case let .scratchpadToggle(index):
            return toggleScratchpad(index)
        case .openMenuAnywhere:
            return controller.commandHandler.performCommand(.openMenuAnywhere)
        }
    }

    func handle(_ request: IPCWorkspaceRequest) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }

        switch request {
        case let .focusName(target):
            return focusWorkspace(target)
        case let .moveToMonitor(target, ipcDirection, force):
            return moveWorkspaceToMonitor(
                target,
                direction: direction(for: ipcDirection),
                force: force
            )
        }
    }

    private func focusWorkspace(_ target: WorkspaceTarget) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        guard controller.activeWorkspace()?.name != rawWorkspaceID else { return .noChange }
        return controller.windowActionHandler.focusWorkspaceFromBar(named: rawWorkspaceID) ? .executed : .notFound
    }

    private func moveWorkspaceToMonitor(
        _ target: WorkspaceTarget,
        direction: Direction,
        force: Bool
    ) -> ExternalCommandResult {
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .success(resolved):
            rawWorkspaceID = resolved
        case let .failure(result):
            return result
        }

        guard let workspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            let outcome = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
                workspaceId,
                direction: direction,
                force: force
            )
        else {
            return .notFound
        }

        switch outcome.status {
        case .executed:
            return .executed
        case .conflict:
            return .workspaceAssignmentConflict
        case .stateConflict:
            return .workspaceStateConflict
        case .notFound:
            return .notFound
        }
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }

        switch IPCWindowOpaqueID.validate(request.windowId, expectingSessionToken: sessionToken) {
        case .invalid:
            return .invalidArguments
        case .stale:
            return .staleWindowId
        case let .valid(pid, windowId):
            let token = WindowToken(pid: pid, windowId: windowId)
            switch request.name {
            case .focus:
                return controller.windowActionHandler.focusWindowFromBar(token: token)
                    ? .executed
                    : .notFound
            case .navigate:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.navigateToWindow(handle: handle)
                    ? .executed
                    : .notFound
            case .summonRight:
                guard let handle = controller.workspaceManager.handle(for: token) else {
                    return .notFound
                }
                return controller.windowActionHandler.summonWindowRight(handle: handle)
                    ? .executed
                    : .notFound
            }
        }
    }

    private func validateControllerState() -> ExternalCommandResult? {
        guard controller.isEnabled else { return .ignoredDisabled }
        guard !controller.isOverviewOpen() else { return .ignoredOverview }
        return nil
    }

    private func direction(for value: IPCDirection) -> Direction {
        switch value {
        case .left:
            .left
        case .right:
            .right
        case .up:
            .up
        case .down:
            .down
        }
    }

    private func dwindleOrientation(for axis: IPCResizeAxis) -> DwindleOrientation {
        switch axis {
        case .horizontal:
            .horizontal
        case .vertical:
            .vertical
        }
    }

    private func sizeChange(for change: IPCSizeChange) -> NiriSizeChange {
        switch change.kind {
        case .setFixed:
            .setFixed(change.value)
        case .setProportion:
            .setProportion(change.value)
        case .adjustFixed:
            .adjustFixed(change.value)
        case .adjustProportion:
            .adjustProportion(change.value)
        }
    }

    private func zeroBasedIndex(from oneBasedValue: Int) -> Int? {
        guard oneBasedValue > 0 else { return nil }
        return oneBasedValue - 1
    }

    private func workspaceTarget(from workspaceNumber: Int) -> WorkspaceTarget? {
        WorkspaceTarget(workspaceNumber: workspaceNumber)
    }

    private func focusMonitor(previous: Bool) -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let result = controller.commandHandler.performCommand(previous ? .focusMonitorPrevious : .focusMonitorNext)
        guard result == .executed else { return result }
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        return currentMonitorId == previousMonitorId ? .noChange : .executed
    }

    private func focusLastMonitor() -> ExternalCommandResult {
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        let result = controller.commandHandler.performCommand(.focusMonitorLast)
        guard result == .executed else { return result }
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        return currentMonitorId == previousMonitorId ? .noChange : .executed
    }

    private func layoutType(for value: IPCWorkspaceLayout) -> LayoutType {
        switch value {
        case .defaultLayout:
            .defaultLayout
        case .niri:
            .niri
        case .dwindle:
            .dwindle
        }
    }

    private func switchWorkspace(using command: HotkeyCommand) -> ExternalCommandResult {
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .noChange : .executed
    }

    private func moveFocusedWindow(using command: HotkeyCommand) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        let result = controller.commandHandler.performCommand(command)
        guard result == .executed else { return result }
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .noChange : .executed
    }

    private func moveFocusedWindowToMonitor(_ direction: Direction) -> ExternalCommandResult {
        guard let token = controller.workspaceManager.selectedManagedToken,
              let workspaceId = controller.workspaceManager.workspace(for: token),
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
              controller.workspaceManager.adjacentMonitor(from: monitorId, direction: direction) != nil
        else { return .notFound }
        return moveFocusedWindow(using: .moveWindowToMonitor(direction))
    }

    private func isAlreadyOnWorkspace(_ token: WindowToken, rawWorkspaceID: String) -> Bool {
        guard let targetId = controller.workspaceManager.workspaceId(for: rawWorkspaceID, createIfMissing: false)
        else { return false }
        return controller.workspaceManager.workspace(for: token) == targetId
    }

    private func swapWorkspaceWithMonitor(direction: Direction) -> ExternalCommandResult {
        guard let monitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id,
            controller.workspaceManager.adjacentMonitor(from: monitorId, direction: direction) != nil
        else { return .notFound }
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let result = controller.commandHandler.performCommand(.swapWorkspaceWithMonitor(direction))
        guard result == .executed else { return result }
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .noChange : .executed
    }

    private func raiseAllFloatingWindows() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard controller.windowActionHandler.hasRaisableFloatingWindows() else {
            return .noChange
        }
        return controller.commandHandler.performCommand(.raiseAllFloatingWindows)
    }

    private func rescueOffscreenWindows() -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        return controller.rescueOffscreenWindows() > 0 ? .executed : .noChange
    }

    private func toggleFocusedWindowFloating() -> ExternalCommandResult {
        controller.commandHandler.performCommand(.toggleFocusedWindowFloating)
    }

    private func assignFocusedWindowToScratchpad(_ index: Int) -> ExternalCommandResult {
        controller.commandHandler.performCommand(.assignFocusedWindowToScratchpad(index))
    }

    private func toggleScratchpad(_ index: Int) -> ExternalCommandResult {
        controller.commandHandler.performCommand(.toggleScratchpad(index))
    }

    private func switchWorkspace(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard controller.activeWorkspace()?.name != rawWorkspaceID else { return .noChange }
        let previousWorkspaceId = controller.activeWorkspace()?.id
        controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: rawWorkspaceID)
        return controller.activeWorkspace()?.id == previousWorkspaceId ? .notFound : .executed
    }

    private func switchWorkspaceAnywhere(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard controller.activeWorkspace()?.name != rawWorkspaceID else { return .noChange }
        let previousWorkspaceId = controller.activeWorkspace()?.id
        let previousMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        controller.workspaceNavigationHandler.focusWorkspaceAnywhere(rawWorkspaceID: rawWorkspaceID)
        let currentWorkspaceId = controller.activeWorkspace()?.id
        let currentMonitorId = controller.workspaceManager.interactionMonitorId ?? controller.monitorForInteraction()?
            .id
        return currentWorkspaceId == previousWorkspaceId && currentMonitorId == previousMonitorId ? .notFound :
            .executed
    }

    private func moveFocusedWindow(to target: WorkspaceTarget) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard !isAlreadyOnWorkspace(token, rawWorkspaceID: rawWorkspaceID) else { return .noChange }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveFocusedWindow(toRawWorkspaceID: rawWorkspaceID)
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }

    private func moveFocusedWindow(
        to target: WorkspaceTarget,
        onMonitor monitorDirection: Direction
    ) -> ExternalCommandResult {
        if let guardResult = validateControllerState() {
            return guardResult
        }
        guard let token = controller.workspaceManager.selectedManagedToken else { return .notFound }
        let rawWorkspaceID: String
        switch resolveWorkspaceTarget(target) {
        case let .failure(result):
            return result
        case let .success(resolved):
            rawWorkspaceID = resolved
        }

        guard !isAlreadyOnWorkspace(token, rawWorkspaceID: rawWorkspaceID) else { return .noChange }
        let previousWorkspaceId = controller.workspaceManager.workspace(for: token)
        controller.workspaceNavigationHandler.moveWindowToWorkspaceOnMonitor(
            rawWorkspaceID: rawWorkspaceID,
            monitorDirection: monitorDirection
        )
        return controller.workspaceManager.workspace(for: token) == previousWorkspaceId ? .notFound : .executed
    }

    private func resolveWorkspaceTarget(_ target: WorkspaceTarget) -> Result<String, ExternalCommandResult> {
        let resolver = WorkspaceTargetResolver(
            settings: controller.settings,
            workspaceManager: controller.workspaceManager
        )

        switch resolver.resolve(target) {
        case let .success(rawWorkspaceID):
            return .success(rawWorkspaceID)
        case .failure(.notFound):
            return .failure(.notFound)
        case .failure(.invalidTarget),
             .failure(.ambiguousDisplayName):
            return .failure(.invalidArguments)
        }
    }
}
