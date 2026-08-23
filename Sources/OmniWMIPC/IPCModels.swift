// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public enum OmniWMIPCProtocol {
    public static let version = 11
}

public struct IPCRequestEnvelope: Decodable, Sendable {
    public let version: Int
    public let id: String?
    public let kind: String?
    public let authorizationToken: String?
}

public struct IPCNoPayload: Codable, Equatable, Sendable {
    public init() {}
}

public enum IPCRequestKind: String, Codable, Equatable, Sendable {
    case ping
    case version
    case command
    case query
    case rule
    case workspace
    case window
    case subscribe
}

public enum IPCResponseKind: String, Codable, Equatable, Sendable {
    case ping
    case version
    case command
    case query
    case rule
    case workspace
    case window
    case subscribe
    case error

    public init(requestKind: IPCRequestKind) {
        switch requestKind {
        case .ping:
            self = .ping
        case .version:
            self = .version
        case .command:
            self = .command
        case .query:
            self = .query
        case .rule:
            self = .rule
        case .workspace:
            self = .workspace
        case .window:
            self = .window
        case .subscribe:
            self = .subscribe
        }
    }
}

public enum IPCResponseStatus: String, Codable, Equatable, Sendable {
    case success
    case executed
    case ignored
    case error
    case subscribed
}

public enum IPCErrorCode: String, Codable, Equatable, Sendable, Error {
    case invalidRequest = "invalid_request"
    case invalidArguments = "invalid_arguments"
    case protocolMismatch = "protocol_mismatch"
    case disabled = "ignored_disabled"
    case overviewOpen = "ignored_overview"
    case layoutMismatch = "layout_mismatch"
    case unauthorized = "unauthorized"
    case staleWindowId = "stale_window_id"
    case notFound = "not_found"
    case workspaceAssignmentConflict = "workspace_assignment_conflict"
    case workspaceStateConflict = "workspace_state_conflict"
    case internalError = "internal_error"
}

public enum IPCSubscriptionChannel: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case focus
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case windowsChanged = "windows-changed"
    case displayChanged = "display-changed"
    case layoutChanged = "layout-changed"
}

public enum IPCEventKind: String, Codable, Equatable, Sendable {
    case event
}

public enum IPCDirection: String, Codable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum IPCResizeAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum IPCWindowMode: String, Codable, Equatable, Sendable {
    case tiling
    case floating
}

public enum IPCWorkspaceLayout: String, Codable, Equatable, Sendable {
    case defaultLayout = "default"
    case niri
    case dwindle
}

public enum IPCHiddenReason: String, Codable, Equatable, Sendable {
    case workspaceInactive = "workspace-inactive"
    case layoutTransient = "layout-transient"
    case scratchpad
}

public enum IPCLayoutReason: String, Codable, Equatable, Sendable {
    case standard
    case nativeFullscreen = "native-fullscreen"
}

public enum IPCManualWindowOverride: String, Codable, Equatable, Sendable {
    case forceTile = "force-tile"
    case forceFloat = "force-float"
}

public enum IPCDisplayOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum IPCRuleLayout: String, Codable, Equatable, Sendable {
    case auto
    case tile
    case float
}

public enum IPCResizeOperation: String, Codable, Equatable, Sendable {
    case grow
    case shrink
}

public struct IPCWorkspaceRef: Codable, Equatable, Sendable {
    public let id: String
    public let rawName: String
    public let displayName: String
    public let number: Int?

    public init(id: String, rawName: String, displayName: String, number: Int?) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
    }
}

public struct IPCDisplayRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isMain: Bool

    public init(id: String, name: String, isMain: Bool) {
        self.id = id
        self.name = name
        self.isMain = isMain
    }
}

public struct IPCAppRef: Codable, Equatable, Sendable {
    public let name: String
    public let bundleId: String?

    public init(name: String, bundleId: String?) {
        self.name = name
        self.bundleId = bundleId
    }
}

public struct IPCWorkspaceWindowCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let tiled: Int
    public let floating: Int
    public let scratchpad: Int

    public init(total: Int, tiled: Int, floating: Int, scratchpad: Int) {
        self.total = total
        self.tiled = tiled
        self.floating = floating
        self.scratchpad = scratchpad
    }
}

public enum IPCCommandName: String, Codable, CaseIterable, Equatable, Sendable {
    case focus
    case focusPrevious = "focus-previous"
    case focusDownOrLeft = "focus-down-or-left"
    case focusUpOrRight = "focus-up-or-right"
    case focusWindowInColumn = "focus-window-in-column"
    case focusWindowTop = "focus-window-top"
    case focusWindowBottom = "focus-window-bottom"
    case focusWindowDownOrTop = "focus-window-down-or-top"
    case focusWindowUpOrBottom = "focus-window-up-or-bottom"
    case focusWindowOrWorkspaceDown = "focus-window-or-workspace-down"
    case focusWindowOrWorkspaceUp = "focus-window-or-workspace-up"
    case focusColumn = "focus-column"
    case focusColumnFirst = "focus-column-first"
    case focusColumnLast = "focus-column-last"
    case centerColumn = "center-column"
    case centerVisibleColumns = "center-visible-columns"
    case move
    case moveWindowDown = "move-window-down"
    case moveWindowUp = "move-window-up"
    case moveWindowDownOrToWorkspaceDown = "move-window-down-or-to-workspace-down"
    case moveWindowUpOrToWorkspaceUp = "move-window-up-or-to-workspace-up"
    case consumeOrExpelWindowLeft = "consume-or-expel-window-left"
    case consumeOrExpelWindowRight = "consume-or-expel-window-right"
    case consumeWindowIntoColumn = "consume-window-into-column"
    case expelWindowFromColumn = "expel-window-from-column"
    case switchWorkspace = "switch-workspace"
    case switchWorkspaceNext = "switch-workspace-next"
    case switchWorkspacePrevious = "switch-workspace-previous"
    case switchWorkspaceBackAndForth = "switch-workspace-back-and-forth"
    case switchWorkspaceAnywhere = "switch-workspace-anywhere"
    case moveToWorkspace = "move-to-workspace"
    case moveToWorkspaceUp = "move-to-workspace-up"
    case moveToWorkspaceDown = "move-to-workspace-down"
    case moveToWorkspaceOnMonitor = "move-to-workspace-on-monitor"
    case moveToMonitor = "move-to-monitor"
    case focusMonitorPrevious = "focus-monitor-previous"
    case focusMonitorNext = "focus-monitor-next"
    case focusMonitorLast = "focus-monitor-last"
    case moveColumn = "move-column"
    case moveColumnToFirst = "move-column-to-first"
    case moveColumnToLast = "move-column-to-last"
    case moveColumnToIndex = "move-column-to-index"
    case moveColumnToWorkspace = "move-column-to-workspace"
    case moveColumnToWorkspaceUp = "move-column-to-workspace-up"
    case moveColumnToWorkspaceDown = "move-column-to-workspace-down"
    case toggleColumnTabbed = "toggle-column-tabbed"
    case cycleSizeForward = "cycle-size-forward"
    case cycleSizeBackward = "cycle-size-backward"
    case cycleWindowPrimarySpanForward = "cycle-window-primary-span-forward"
    case cycleWindowPrimarySpanBackward = "cycle-window-primary-span-backward"
    case cycleWindowSecondarySpanForward = "cycle-window-secondary-span-forward"
    case cycleWindowSecondarySpanBackward = "cycle-window-secondary-span-backward"
    case toggleContainerFullPrimarySpan = "toggle-container-full-primary-span"
    case expandContainerToAvailablePrimarySpan = "expand-container-to-available-primary-span"
    case resetWindowSecondarySpan = "reset-window-secondary-span"
    case setContainerPrimarySpan = "set-container-primary-span"
    case setWindowPrimarySpan = "set-window-primary-span"
    case setWindowSecondarySpan = "set-window-secondary-span"
    case swapWorkspaceWithMonitor = "swap-workspace-with-monitor"
    case balanceSizes = "balance-sizes"
    case moveToRoot = "move-to-root"
    case toggleSplit = "toggle-split"
    case swapSplit = "swap-split"
    case resize
    case resizeFocused = "resize-focused"
    case preselect
    case preselectClear = "preselect-clear"
    case openCommandPalette = "open-command-palette"
    case raiseAllFloatingWindows = "raise-all-floating-windows"
    case rescueOffscreenWindows = "rescue-offscreen-windows"
    case toggleWorkspaceLayout = "toggle-workspace-layout"
    case setWorkspaceLayout = "set-workspace-layout"
    case toggleFullscreen = "toggle-fullscreen"
    case toggleNativeFullscreen = "toggle-native-fullscreen"
    case toggleOverview = "toggle-overview"
    case toggleSystemStats = "toggle-system-stats"
    case toggleQuakeTerminal = "toggle-quake-terminal"
    case toggleWorkspaceBar = "toggle-workspace-bar"
    case hiddenBarPanel = "hidden-bar-panel"
    case toggleFocusedWindowFloating = "toggle-focused-window-floating"
    case scratchpadAssign = "scratchpad-assign"
    case scratchpadToggle = "scratchpad-toggle"
    case openMenuAnywhere = "open-menu-anywhere"
}

public enum IPCSizeChangeKind: String, Codable, Equatable, Sendable {
    case setFixed = "set-fixed"
    case setProportion = "set-proportion"
    case adjustFixed = "adjust-fixed"
    case adjustProportion = "adjust-proportion"
}

public struct IPCSizeChange: Codable, Equatable, Sendable {
    public let kind: IPCSizeChangeKind
    public let value: Double

    public init(kind: IPCSizeChangeKind, value: Double) {
        self.kind = kind
        self.value = value
    }

    public static func setFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setFixed, value: value)
    }

    public static func setProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setProportion, value: value)
    }

    public static func adjustFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustFixed, value: value)
    }

    public static func adjustProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustProportion, value: value)
    }
}

public enum IPCCommandArgumentValue: Equatable, Sendable {
    case direction(IPCDirection)
    case integer(Int)
    case layout(IPCWorkspaceLayout)
    case resizeAxis(IPCResizeAxis)
    case resizeOperation(IPCResizeOperation)
    case sizeChange(IPCSizeChange)
}

public enum IPCCommandRequestConstructionError: Error, Equatable, Sendable {
    case invalidArgumentCount
    case invalidArgumentType
}

public enum IPCCommandRequest: Equatable, Sendable {
    case focus(direction: IPCDirection)
    case focusPrevious
    case focusDownOrLeft
    case focusUpOrRight
    case focusWindowInColumn(windowIndex: Int)
    case focusWindowTop
    case focusWindowBottom
    case focusWindowDownOrTop
    case focusWindowUpOrBottom
    case focusWindowOrWorkspaceDown
    case focusWindowOrWorkspaceUp
    case focusColumn(columnIndex: Int)
    case focusColumnFirst
    case focusColumnLast
    case centerColumn
    case centerVisibleColumns
    case move(direction: IPCDirection)
    case moveWindowDown
    case moveWindowUp
    case moveWindowDownOrToWorkspaceDown
    case moveWindowUpOrToWorkspaceUp
    case consumeOrExpelWindowLeft
    case consumeOrExpelWindowRight
    case consumeWindowIntoColumn
    case expelWindowFromColumn
    case switchWorkspace(workspaceNumber: Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case switchWorkspaceBackAndForth
    case switchWorkspaceAnywhere(workspaceNumber: Int)
    case moveToWorkspace(workspaceNumber: Int)
    case moveToWorkspaceUp
    case moveToWorkspaceDown
    case moveToWorkspaceOnMonitor(workspaceNumber: Int, direction: IPCDirection)
    case moveToMonitor(direction: IPCDirection)
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case moveColumn(direction: IPCDirection)
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToIndex(columnIndex: Int)
    case moveColumnToWorkspace(workspaceNumber: Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case toggleColumnTabbed
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case setContainerPrimarySpan(change: IPCSizeChange)
    case setWindowPrimarySpan(change: IPCSizeChange)
    case setWindowSecondarySpan(change: IPCSizeChange)
    case swapWorkspaceWithMonitor(direction: IPCDirection)
    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resize(axis: IPCResizeAxis, operation: IPCResizeOperation)
    case resizeFocused(operation: IPCResizeOperation)
    case preselect(direction: IPCDirection)
    case preselectClear
    case openCommandPalette
    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case toggleWorkspaceLayout
    case setWorkspaceLayout(layout: IPCWorkspaceLayout)
    case toggleFullscreen
    case toggleNativeFullscreen
    case toggleOverview
    case toggleSystemStats
    case toggleQuakeTerminal
    case toggleWorkspaceBar
    case hiddenBarPanel
    case toggleFocusedWindowFloating
    case scratchpadAssign
    case scratchpadToggle
    case openMenuAnywhere

    public var name: IPCCommandName {
        switch self {
        case .focus:
            .focus
        case .focusPrevious:
            .focusPrevious
        case .focusDownOrLeft:
            .focusDownOrLeft
        case .focusUpOrRight:
            .focusUpOrRight
        case .focusWindowInColumn:
            .focusWindowInColumn
        case .focusWindowTop:
            .focusWindowTop
        case .focusWindowBottom:
            .focusWindowBottom
        case .focusWindowDownOrTop:
            .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            .focusWindowOrWorkspaceUp
        case .focusColumn:
            .focusColumn
        case .focusColumnFirst:
            .focusColumnFirst
        case .focusColumnLast:
            .focusColumnLast
        case .centerColumn:
            .centerColumn
        case .centerVisibleColumns:
            .centerVisibleColumns
        case .move:
            .move
        case .moveWindowDown:
            .moveWindowDown
        case .moveWindowUp:
            .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            .expelWindowFromColumn
        case .switchWorkspace:
            .switchWorkspace
        case .switchWorkspaceNext:
            .switchWorkspaceNext
        case .switchWorkspacePrevious:
            .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            .switchWorkspaceAnywhere
        case .moveToWorkspace:
            .moveToWorkspace
        case .moveToWorkspaceUp:
            .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            .moveToWorkspaceOnMonitor
        case .moveToMonitor:
            .moveToMonitor
        case .focusMonitorPrevious:
            .focusMonitorPrevious
        case .focusMonitorNext:
            .focusMonitorNext
        case .focusMonitorLast:
            .focusMonitorLast
        case .moveColumn:
            .moveColumn
        case .moveColumnToFirst:
            .moveColumnToFirst
        case .moveColumnToLast:
            .moveColumnToLast
        case .moveColumnToIndex:
            .moveColumnToIndex
        case .moveColumnToWorkspace:
            .moveColumnToWorkspace
        case .moveColumnToWorkspaceUp:
            .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            .toggleColumnTabbed
        case .cycleSizeForward:
            .cycleSizeForward
        case .cycleSizeBackward:
            .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            .setContainerPrimarySpan
        case .setWindowPrimarySpan:
            .setWindowPrimarySpan
        case .setWindowSecondarySpan:
            .setWindowSecondarySpan
        case .swapWorkspaceWithMonitor:
            .swapWorkspaceWithMonitor
        case .balanceSizes:
            .balanceSizes
        case .moveToRoot:
            .moveToRoot
        case .toggleSplit:
            .toggleSplit
        case .swapSplit:
            .swapSplit
        case .resize:
            .resize
        case .resizeFocused:
            .resizeFocused
        case .preselect:
            .preselect
        case .preselectClear:
            .preselectClear
        case .openCommandPalette:
            .openCommandPalette
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            .setWorkspaceLayout
        case .toggleFullscreen:
            .toggleFullscreen
        case .toggleNativeFullscreen:
            .toggleNativeFullscreen
        case .toggleOverview:
            .toggleOverview
        case .toggleSystemStats:
            .toggleSystemStats
        case .toggleQuakeTerminal:
            .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            .toggleWorkspaceBar
        case .hiddenBarPanel:
            .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            .toggleFocusedWindowFloating
        case .scratchpadAssign:
            .scratchpadAssign
        case .scratchpadToggle:
            .scratchpadToggle
        case .openMenuAnywhere:
            .openMenuAnywhere
        }
    }

    public init(name: IPCCommandName, argumentValues: [IPCCommandArgumentValue] = []) throws {
        func requireNoArguments() throws {
            guard argumentValues.isEmpty else {
                throw IPCCommandRequestConstructionError.invalidArgumentCount
            }
        }

        func requireDirection() throws -> IPCDirection {
            guard argumentValues.count == 1, case let .direction(direction) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return direction
        }

        func requireInteger() throws -> Int {
            guard argumentValues.count == 1, case let .integer(value) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        }

        func requireLayout() throws -> IPCWorkspaceLayout {
            guard argumentValues.count == 1, case let .layout(layout) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return layout
        }

        func requireSizeChange() throws -> IPCSizeChange {
            guard argumentValues.count == 1, case let .sizeChange(change) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return change
        }

        func requireResizeArguments() throws -> (axis: IPCResizeAxis, operation: IPCResizeOperation) {
            guard argumentValues.count == 2,
                  case let .resizeAxis(axis) = argumentValues[0],
                  case let .resizeOperation(operation) = argumentValues[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (axis, operation)
        }

        func requireResizeOperation() throws -> IPCResizeOperation {
            guard argumentValues.count == 1, case let .resizeOperation(operation) = argumentValues[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return operation
        }

        func requireWorkspaceAndDirection() throws -> (workspaceNumber: Int, direction: IPCDirection) {
            guard argumentValues.count == 2,
                  case let .integer(workspaceNumber) = argumentValues[0],
                  case let .direction(direction) = argumentValues[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (workspaceNumber, direction)
        }

        switch name {
        case .focus:
            self = .focus(direction: try requireDirection())
        case .focusPrevious:
            try requireNoArguments()
            self = .focusPrevious
        case .focusDownOrLeft:
            try requireNoArguments()
            self = .focusDownOrLeft
        case .focusUpOrRight:
            try requireNoArguments()
            self = .focusUpOrRight
        case .focusWindowInColumn:
            self = .focusWindowInColumn(windowIndex: try requireInteger())
        case .focusWindowTop:
            try requireNoArguments()
            self = .focusWindowTop
        case .focusWindowBottom:
            try requireNoArguments()
            self = .focusWindowBottom
        case .focusWindowDownOrTop:
            try requireNoArguments()
            self = .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            try requireNoArguments()
            self = .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            try requireNoArguments()
            self = .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            try requireNoArguments()
            self = .focusWindowOrWorkspaceUp
        case .focusColumn:
            self = .focusColumn(columnIndex: try requireInteger())
        case .focusColumnFirst:
            try requireNoArguments()
            self = .focusColumnFirst
        case .focusColumnLast:
            try requireNoArguments()
            self = .focusColumnLast
        case .centerColumn:
            try requireNoArguments()
            self = .centerColumn
        case .centerVisibleColumns:
            try requireNoArguments()
            self = .centerVisibleColumns
        case .move:
            self = .move(direction: try requireDirection())
        case .moveWindowDown:
            try requireNoArguments()
            self = .moveWindowDown
        case .moveWindowUp:
            try requireNoArguments()
            self = .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            try requireNoArguments()
            self = .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            try requireNoArguments()
            self = .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            try requireNoArguments()
            self = .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            try requireNoArguments()
            self = .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            try requireNoArguments()
            self = .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            try requireNoArguments()
            self = .expelWindowFromColumn
        case .switchWorkspace:
            self = .switchWorkspace(workspaceNumber: try requireInteger())
        case .switchWorkspaceNext:
            try requireNoArguments()
            self = .switchWorkspaceNext
        case .switchWorkspacePrevious:
            try requireNoArguments()
            self = .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            try requireNoArguments()
            self = .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            self = .switchWorkspaceAnywhere(workspaceNumber: try requireInteger())
        case .moveToWorkspace:
            self = .moveToWorkspace(workspaceNumber: try requireInteger())
        case .moveToWorkspaceUp:
            try requireNoArguments()
            self = .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            try requireNoArguments()
            self = .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            let arguments = try requireWorkspaceAndDirection()
            self = .moveToWorkspaceOnMonitor(
                workspaceNumber: arguments.workspaceNumber,
                direction: arguments.direction
            )
        case .moveToMonitor:
            self = .moveToMonitor(direction: try requireDirection())
        case .focusMonitorPrevious:
            try requireNoArguments()
            self = .focusMonitorPrevious
        case .focusMonitorNext:
            try requireNoArguments()
            self = .focusMonitorNext
        case .focusMonitorLast:
            try requireNoArguments()
            self = .focusMonitorLast
        case .moveColumn:
            self = .moveColumn(direction: try requireDirection())
        case .moveColumnToFirst:
            try requireNoArguments()
            self = .moveColumnToFirst
        case .moveColumnToLast:
            try requireNoArguments()
            self = .moveColumnToLast
        case .moveColumnToIndex:
            self = .moveColumnToIndex(columnIndex: try requireInteger())
        case .moveColumnToWorkspace:
            self = .moveColumnToWorkspace(workspaceNumber: try requireInteger())
        case .moveColumnToWorkspaceUp:
            try requireNoArguments()
            self = .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            try requireNoArguments()
            self = .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            try requireNoArguments()
            self = .toggleColumnTabbed
        case .cycleSizeForward:
            try requireNoArguments()
            self = .cycleSizeForward
        case .cycleSizeBackward:
            try requireNoArguments()
            self = .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            try requireNoArguments()
            self = .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            try requireNoArguments()
            self = .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            try requireNoArguments()
            self = .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            try requireNoArguments()
            self = .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            try requireNoArguments()
            self = .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            try requireNoArguments()
            self = .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            try requireNoArguments()
            self = .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            self = .setContainerPrimarySpan(change: try requireSizeChange())
        case .setWindowPrimarySpan:
            self = .setWindowPrimarySpan(change: try requireSizeChange())
        case .setWindowSecondarySpan:
            self = .setWindowSecondarySpan(change: try requireSizeChange())
        case .swapWorkspaceWithMonitor:
            self = .swapWorkspaceWithMonitor(direction: try requireDirection())
        case .balanceSizes:
            try requireNoArguments()
            self = .balanceSizes
        case .moveToRoot:
            try requireNoArguments()
            self = .moveToRoot
        case .toggleSplit:
            try requireNoArguments()
            self = .toggleSplit
        case .swapSplit:
            try requireNoArguments()
            self = .swapSplit
        case .resize:
            let arguments = try requireResizeArguments()
            self = .resize(axis: arguments.axis, operation: arguments.operation)
        case .resizeFocused:
            self = .resizeFocused(operation: try requireResizeOperation())
        case .preselect:
            self = .preselect(direction: try requireDirection())
        case .preselectClear:
            try requireNoArguments()
            self = .preselectClear
        case .openCommandPalette:
            try requireNoArguments()
            self = .openCommandPalette
        case .raiseAllFloatingWindows:
            try requireNoArguments()
            self = .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            try requireNoArguments()
            self = .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            try requireNoArguments()
            self = .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            self = .setWorkspaceLayout(layout: try requireLayout())
        case .toggleFullscreen:
            try requireNoArguments()
            self = .toggleFullscreen
        case .toggleNativeFullscreen:
            try requireNoArguments()
            self = .toggleNativeFullscreen
        case .toggleOverview:
            try requireNoArguments()
            self = .toggleOverview
        case .toggleSystemStats:
            try requireNoArguments()
            self = .toggleSystemStats
        case .toggleQuakeTerminal:
            try requireNoArguments()
            self = .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            try requireNoArguments()
            self = .toggleWorkspaceBar
        case .hiddenBarPanel:
            try requireNoArguments()
            self = .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            try requireNoArguments()
            self = .toggleFocusedWindowFloating
        case .scratchpadAssign:
            try requireNoArguments()
            self = .scratchpadAssign
        case .scratchpadToggle:
            try requireNoArguments()
            self = .scratchpadToggle
        case .openMenuAnywhere:
            try requireNoArguments()
            self = .openMenuAnywhere
        }
    }
}

extension IPCCommandRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    private struct IPCDirectionArguments: Codable, Equatable, Sendable {
        let direction: IPCDirection
    }

    private struct IPCWorkspaceNumberArguments: Codable, Equatable, Sendable {
        let workspaceNumber: Int
    }

    private struct IPCColumnIndexArguments: Codable, Equatable, Sendable {
        let columnIndex: Int
    }

    private struct IPCWindowIndexArguments: Codable, Equatable, Sendable {
        let windowIndex: Int
    }

    private struct IPCWorkspaceOnMonitorArguments: Codable, Equatable, Sendable {
        let workspaceNumber: Int
        let direction: IPCDirection
    }

    private struct IPCLayoutArguments: Codable, Equatable, Sendable {
        let layout: IPCWorkspaceLayout
    }

    private struct IPCResizeArguments: Codable, Equatable, Sendable {
        let axis: IPCResizeAxis
        let operation: IPCResizeOperation
    }

    private struct IPCResizeOperationArguments: Codable, Equatable, Sendable {
        let operation: IPCResizeOperation
    }

    private struct IPCSizeChangeArguments: Codable, Equatable, Sendable {
        let change: IPCSizeChange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCCommandName.self, forKey: .name)

        switch name {
        case .focus:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .focus(direction: arguments.direction)
        case .focusPrevious:
            self = .focusPrevious
        case .focusDownOrLeft:
            self = .focusDownOrLeft
        case .focusUpOrRight:
            self = .focusUpOrRight
        case .focusWindowInColumn:
            let arguments = try container.decode(IPCWindowIndexArguments.self, forKey: .arguments)
            self = .focusWindowInColumn(windowIndex: arguments.windowIndex)
        case .focusWindowTop:
            self = .focusWindowTop
        case .focusWindowBottom:
            self = .focusWindowBottom
        case .focusWindowDownOrTop:
            self = .focusWindowDownOrTop
        case .focusWindowUpOrBottom:
            self = .focusWindowUpOrBottom
        case .focusWindowOrWorkspaceDown:
            self = .focusWindowOrWorkspaceDown
        case .focusWindowOrWorkspaceUp:
            self = .focusWindowOrWorkspaceUp
        case .focusColumn:
            let arguments = try container.decode(IPCColumnIndexArguments.self, forKey: .arguments)
            self = .focusColumn(columnIndex: arguments.columnIndex)
        case .focusColumnFirst:
            self = .focusColumnFirst
        case .focusColumnLast:
            self = .focusColumnLast
        case .centerColumn:
            self = .centerColumn
        case .centerVisibleColumns:
            self = .centerVisibleColumns
        case .move:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .move(direction: arguments.direction)
        case .moveWindowDown:
            self = .moveWindowDown
        case .moveWindowUp:
            self = .moveWindowUp
        case .moveWindowDownOrToWorkspaceDown:
            self = .moveWindowDownOrToWorkspaceDown
        case .moveWindowUpOrToWorkspaceUp:
            self = .moveWindowUpOrToWorkspaceUp
        case .consumeOrExpelWindowLeft:
            self = .consumeOrExpelWindowLeft
        case .consumeOrExpelWindowRight:
            self = .consumeOrExpelWindowRight
        case .consumeWindowIntoColumn:
            self = .consumeWindowIntoColumn
        case .expelWindowFromColumn:
            self = .expelWindowFromColumn
        case .switchWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .switchWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .switchWorkspaceNext:
            self = .switchWorkspaceNext
        case .switchWorkspacePrevious:
            self = .switchWorkspacePrevious
        case .switchWorkspaceBackAndForth:
            self = .switchWorkspaceBackAndForth
        case .switchWorkspaceAnywhere:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .switchWorkspaceAnywhere(workspaceNumber: arguments.workspaceNumber)
        case .moveToWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .moveToWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .moveToWorkspaceUp:
            self = .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            self = .moveToWorkspaceDown
        case .moveToWorkspaceOnMonitor:
            let arguments = try container.decode(IPCWorkspaceOnMonitorArguments.self, forKey: .arguments)
            self = .moveToWorkspaceOnMonitor(workspaceNumber: arguments.workspaceNumber, direction: arguments.direction)
        case .moveToMonitor:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .moveToMonitor(direction: arguments.direction)
        case .focusMonitorPrevious:
            self = .focusMonitorPrevious
        case .focusMonitorNext:
            self = .focusMonitorNext
        case .focusMonitorLast:
            self = .focusMonitorLast
        case .moveColumn:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .moveColumn(direction: arguments.direction)
        case .moveColumnToFirst:
            self = .moveColumnToFirst
        case .moveColumnToLast:
            self = .moveColumnToLast
        case .moveColumnToIndex:
            let arguments = try container.decode(IPCColumnIndexArguments.self, forKey: .arguments)
            self = .moveColumnToIndex(columnIndex: arguments.columnIndex)
        case .moveColumnToWorkspace:
            let arguments = try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments)
            self = .moveColumnToWorkspace(workspaceNumber: arguments.workspaceNumber)
        case .moveColumnToWorkspaceUp:
            self = .moveColumnToWorkspaceUp
        case .moveColumnToWorkspaceDown:
            self = .moveColumnToWorkspaceDown
        case .toggleColumnTabbed:
            self = .toggleColumnTabbed
        case .cycleSizeForward:
            self = .cycleSizeForward
        case .cycleSizeBackward:
            self = .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            self = .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            self = .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            self = .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            self = .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            self = .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            self = .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            self = .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setContainerPrimarySpan(change: arguments.change)
        case .setWindowPrimarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setWindowPrimarySpan(change: arguments.change)
        case .setWindowSecondarySpan:
            let arguments = try container.decode(IPCSizeChangeArguments.self, forKey: .arguments)
            self = .setWindowSecondarySpan(change: arguments.change)
        case .swapWorkspaceWithMonitor:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .swapWorkspaceWithMonitor(direction: arguments.direction)
        case .balanceSizes:
            self = .balanceSizes
        case .moveToRoot:
            self = .moveToRoot
        case .toggleSplit:
            self = .toggleSplit
        case .swapSplit:
            self = .swapSplit
        case .resize:
            let arguments = try container.decode(IPCResizeArguments.self, forKey: .arguments)
            self = .resize(axis: arguments.axis, operation: arguments.operation)
        case .resizeFocused:
            let arguments = try container.decode(IPCResizeOperationArguments.self, forKey: .arguments)
            self = .resizeFocused(operation: arguments.operation)
        case .preselect:
            let arguments = try container.decode(IPCDirectionArguments.self, forKey: .arguments)
            self = .preselect(direction: arguments.direction)
        case .preselectClear:
            self = .preselectClear
        case .openCommandPalette:
            self = .openCommandPalette
        case .raiseAllFloatingWindows:
            self = .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            self = .rescueOffscreenWindows
        case .toggleWorkspaceLayout:
            self = .toggleWorkspaceLayout
        case .setWorkspaceLayout:
            let arguments = try container.decode(IPCLayoutArguments.self, forKey: .arguments)
            self = .setWorkspaceLayout(layout: arguments.layout)
        case .toggleFullscreen:
            self = .toggleFullscreen
        case .toggleNativeFullscreen:
            self = .toggleNativeFullscreen
        case .toggleOverview:
            self = .toggleOverview
        case .toggleSystemStats:
            self = .toggleSystemStats
        case .toggleQuakeTerminal:
            self = .toggleQuakeTerminal
        case .toggleWorkspaceBar:
            self = .toggleWorkspaceBar
        case .hiddenBarPanel:
            self = .hiddenBarPanel
        case .toggleFocusedWindowFloating:
            self = .toggleFocusedWindowFloating
        case .scratchpadAssign:
            self = .scratchpadAssign
        case .scratchpadToggle:
            self = .scratchpadToggle
        case .openMenuAnywhere:
            self = .openMenuAnywhere
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        switch self {
        case let .focus(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .focusPrevious:
            break
        case .focusDownOrLeft:
            break
        case .focusUpOrRight:
            break
        case let .focusWindowInColumn(windowIndex):
            try container.encode(IPCWindowIndexArguments(windowIndex: windowIndex), forKey: .arguments)
        case .focusWindowTop:
            break
        case .focusWindowBottom:
            break
        case .focusWindowDownOrTop:
            break
        case .focusWindowUpOrBottom:
            break
        case .focusWindowOrWorkspaceDown:
            break
        case .focusWindowOrWorkspaceUp:
            break
        case let .focusColumn(columnIndex):
            try container.encode(IPCColumnIndexArguments(columnIndex: columnIndex), forKey: .arguments)
        case .focusColumnFirst:
            break
        case .focusColumnLast:
            break
        case .centerColumn:
            break
        case .centerVisibleColumns:
            break
        case let .move(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .moveWindowDown:
            break
        case .moveWindowUp:
            break
        case .moveWindowDownOrToWorkspaceDown:
            break
        case .moveWindowUpOrToWorkspaceUp:
            break
        case .consumeOrExpelWindowLeft:
            break
        case .consumeOrExpelWindowRight:
            break
        case .consumeWindowIntoColumn:
            break
        case .expelWindowFromColumn:
            break
        case let .switchWorkspace(workspaceNumber):
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: workspaceNumber), forKey: .arguments)
        case .switchWorkspaceNext:
            break
        case .switchWorkspacePrevious:
            break
        case .switchWorkspaceBackAndForth:
            break
        case let .switchWorkspaceAnywhere(workspaceNumber):
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: workspaceNumber), forKey: .arguments)
        case let .moveToWorkspace(workspaceNumber):
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: workspaceNumber), forKey: .arguments)
        case .moveToWorkspaceUp:
            break
        case .moveToWorkspaceDown:
            break
        case let .moveToWorkspaceOnMonitor(workspaceNumber, direction):
            try container.encode(
                IPCWorkspaceOnMonitorArguments(workspaceNumber: workspaceNumber, direction: direction),
                forKey: .arguments
            )
        case let .moveToMonitor(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .focusMonitorPrevious:
            break
        case .focusMonitorNext:
            break
        case .focusMonitorLast:
            break
        case let .moveColumn(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .moveColumnToFirst:
            break
        case .moveColumnToLast:
            break
        case let .moveColumnToIndex(columnIndex):
            try container.encode(IPCColumnIndexArguments(columnIndex: columnIndex), forKey: .arguments)
        case let .moveColumnToWorkspace(workspaceNumber):
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: workspaceNumber), forKey: .arguments)
        case .moveColumnToWorkspaceUp:
            break
        case .moveColumnToWorkspaceDown:
            break
        case .toggleColumnTabbed:
            break
        case .cycleSizeForward:
            break
        case .cycleSizeBackward:
            break
        case .cycleWindowPrimarySpanForward:
            break
        case .cycleWindowPrimarySpanBackward:
            break
        case .cycleWindowSecondarySpanForward:
            break
        case .cycleWindowSecondarySpanBackward:
            break
        case .toggleContainerFullPrimarySpan:
            break
        case .expandContainerToAvailablePrimarySpan:
            break
        case .resetWindowSecondarySpan:
            break
        case let .setContainerPrimarySpan(change):
            try container.encode(IPCSizeChangeArguments(change: change), forKey: .arguments)
        case let .setWindowPrimarySpan(change):
            try container.encode(IPCSizeChangeArguments(change: change), forKey: .arguments)
        case let .setWindowSecondarySpan(change):
            try container.encode(IPCSizeChangeArguments(change: change), forKey: .arguments)
        case let .swapWorkspaceWithMonitor(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .balanceSizes:
            break
        case .moveToRoot:
            break
        case .toggleSplit:
            break
        case .swapSplit:
            break
        case let .resize(axis, operation):
            try container.encode(
                IPCResizeArguments(axis: axis, operation: operation),
                forKey: .arguments
            )
        case let .resizeFocused(operation):
            try container.encode(IPCResizeOperationArguments(operation: operation), forKey: .arguments)
        case let .preselect(direction):
            try container.encode(IPCDirectionArguments(direction: direction), forKey: .arguments)
        case .preselectClear:
            break
        case .openCommandPalette:
            break
        case .raiseAllFloatingWindows:
            break
        case .rescueOffscreenWindows:
            break
        case .toggleWorkspaceLayout:
            break
        case let .setWorkspaceLayout(layout):
            try container.encode(IPCLayoutArguments(layout: layout), forKey: .arguments)
        case .toggleFullscreen:
            break
        case .toggleNativeFullscreen:
            break
        case .toggleOverview:
            break
        case .toggleSystemStats:
            break
        case .toggleQuakeTerminal:
            break
        case .toggleWorkspaceBar:
            break
        case .hiddenBarPanel:
            break
        case .toggleFocusedWindowFloating:
            break
        case .scratchpadAssign:
            break
        case .scratchpadToggle:
            break
        case .openMenuAnywhere:
            break
        }
    }
}

public enum IPCQueryName: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case apps
    case focusedWindow = "focused-window"
    case windows
    case workspaces
    case displays
    case rules
    case ruleActions = "rule-actions"
    case queries
    case commands
    case subscriptions
    case capabilities
}

public struct IPCQuerySelectors: Codable, Equatable, Sendable {
    public let window: String?
    public let workspace: String?
    public let display: String?
    public let focused: Bool?
    public let visible: Bool?
    public let floating: Bool?
    public let scratchpad: Bool?
    public let app: String?
    public let bundleId: String?
    public let current: Bool?
    public let main: Bool?

    public init(
        window: String? = nil,
        workspace: String? = nil,
        display: String? = nil,
        focused: Bool? = nil,
        visible: Bool? = nil,
        floating: Bool? = nil,
        scratchpad: Bool? = nil,
        app: String? = nil,
        bundleId: String? = nil,
        current: Bool? = nil,
        main: Bool? = nil
    ) {
        self.window = window
        self.workspace = workspace
        self.display = display
        self.focused = focused
        self.visible = visible
        self.floating = floating
        self.scratchpad = scratchpad
        self.app = app
        self.bundleId = bundleId
        self.current = current
        self.main = main
    }

    public var providedSelectorNames: [IPCQuerySelectorName] {
        var names: [IPCQuerySelectorName] = []
        if window != nil { names.append(.window) }
        if workspace != nil { names.append(.workspace) }
        if display != nil { names.append(.display) }
        if focused != nil { names.append(.focused) }
        if visible != nil { names.append(.visible) }
        if floating != nil { names.append(.floating) }
        if scratchpad != nil { names.append(.scratchpad) }
        if app != nil { names.append(.app) }
        if bundleId != nil { names.append(.bundleId) }
        if current != nil { names.append(.current) }
        if main != nil { names.append(.main) }
        return names
    }

    public func setting(_ selector: IPCQuerySelectorName, value: String? = nil) -> IPCQuerySelectors {
        switch selector {
        case .window:
            IPCQuerySelectors(
                window: value,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .workspace:
            IPCQuerySelectors(
                window: window,
                workspace: value,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .display:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: value,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .focused:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: true,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .visible:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: true,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .floating:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: true,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .scratchpad:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: true,
                app: app,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .app:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: value,
                bundleId: bundleId,
                current: current,
                main: main
            )
        case .bundleId:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: value,
                current: current,
                main: main
            )
        case .current:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: true,
                main: main
            )
        case .main:
            IPCQuerySelectors(
                window: window,
                workspace: workspace,
                display: display,
                focused: focused,
                visible: visible,
                floating: floating,
                scratchpad: scratchpad,
                app: app,
                bundleId: bundleId,
                current: current,
                main: true
            )
        }
    }
}

public struct IPCQueryRequest: Codable, Equatable, Sendable {
    public let name: IPCQueryName
    public let selectors: IPCQuerySelectors
    public let fields: [String]

    public init(
        name: IPCQueryName,
        selectors: IPCQuerySelectors = IPCQuerySelectors(),
        fields: [String] = []
    ) {
        self.name = name
        self.selectors = selectors
        self.fields = fields
    }
}

public struct IPCRuleDefinition: Codable, Equatable, Sendable {
    public let bundleId: String
    public let appNameSubstring: String?
    public let titleSubstring: String?
    public let titleRegex: String?
    public let axRole: String?
    public let axSubrole: String?
    public let layout: IPCRuleLayout
    public let assignToWorkspace: String?
    public let initialContainerPrimarySpan: Double?
    public let minWidth: Double?
    public let minHeight: Double?

    public init(
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        layout: IPCRuleLayout = .auto,
        assignToWorkspace: String? = nil,
        initialContainerPrimarySpan: Double? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil
    ) {
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.initialContainerPrimarySpan = initialContainerPrimarySpan
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}

public enum IPCRuleApplyTarget: Equatable, Sendable {
    case focused
    case window(windowId: String)
    case pid(Int32)
}

extension IPCRuleApplyTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case windowId
        case pid
    }

    private enum Kind: String, Codable {
        case focused
        case window
        case pid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .focused:
            self = .focused
        case .window:
            self = .window(windowId: try container.decode(String.self, forKey: .windowId))
        case .pid:
            self = .pid(try container.decode(Int32.self, forKey: .pid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .focused:
            try container.encode(Kind.focused, forKey: .kind)
        case let .window(windowId):
            try container.encode(Kind.window, forKey: .kind)
            try container.encode(windowId, forKey: .windowId)
        case let .pid(pid):
            try container.encode(Kind.pid, forKey: .kind)
            try container.encode(pid, forKey: .pid)
        }
    }
}

public enum IPCRuleActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case add
    case replace
    case remove
    case move
    case apply
}

public enum IPCRuleRequest: Equatable, Sendable {
    case add(rule: IPCRuleDefinition)
    case replace(id: String, rule: IPCRuleDefinition)
    case remove(id: String)
    case move(id: String, position: Int)
    case apply(target: IPCRuleApplyTarget)

    public var name: IPCRuleActionName {
        switch self {
        case .add:
            .add
        case .replace:
            .replace
        case .remove:
            .remove
        case .move:
            .move
        case .apply:
            .apply
        }
    }
}

extension IPCRuleRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    private struct AddArguments: Codable, Equatable, Sendable {
        let rule: IPCRuleDefinition
    }

    private struct ReplaceArguments: Codable, Equatable, Sendable {
        let id: String
        let rule: IPCRuleDefinition
    }

    private struct RemoveArguments: Codable, Equatable, Sendable {
        let id: String
    }

    private struct MoveArguments: Codable, Equatable, Sendable {
        let id: String
        let position: Int
    }

    private struct ApplyArguments: Codable, Equatable, Sendable {
        let target: IPCRuleApplyTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCRuleActionName.self, forKey: .name)

        switch name {
        case .add:
            let arguments = try container.decode(AddArguments.self, forKey: .arguments)
            self = .add(rule: arguments.rule)
        case .replace:
            let arguments = try container.decode(ReplaceArguments.self, forKey: .arguments)
            self = .replace(id: arguments.id, rule: arguments.rule)
        case .remove:
            let arguments = try container.decode(RemoveArguments.self, forKey: .arguments)
            self = .remove(id: arguments.id)
        case .move:
            let arguments = try container.decode(MoveArguments.self, forKey: .arguments)
            self = .move(id: arguments.id, position: arguments.position)
        case .apply:
            let arguments = try container.decode(ApplyArguments.self, forKey: .arguments)
            self = .apply(target: arguments.target)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        switch self {
        case let .add(rule):
            try container.encode(AddArguments(rule: rule), forKey: .arguments)
        case let .replace(id, rule):
            try container.encode(ReplaceArguments(id: id, rule: rule), forKey: .arguments)
        case let .remove(id):
            try container.encode(RemoveArguments(id: id), forKey: .arguments)
        case let .move(id, position):
            try container.encode(MoveArguments(id: id, position: position), forKey: .arguments)
        case let .apply(target):
            try container.encode(ApplyArguments(target: target), forKey: .arguments)
        }
    }
}

public enum IPCWorkspaceActionName: String, Codable, Equatable, Sendable {
    case focusName = "focus-name"
    case moveToMonitor = "move-to-monitor"
}

public enum IPCWorkspaceRequest: Equatable, Sendable {
    case focusName(target: WorkspaceTarget)
    case moveToMonitor(target: WorkspaceTarget, direction: IPCDirection, force: Bool = false)

    public var name: IPCWorkspaceActionName {
        switch self {
        case .focusName:
            .focusName
        case .moveToMonitor:
            .moveToMonitor
        }
    }

    public var target: WorkspaceTarget {
        switch self {
        case let .focusName(target),
             let .moveToMonitor(target, _, _):
            target
        }
    }
}

extension IPCWorkspaceRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case workspaceTarget
        case direction
        case force
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCWorkspaceActionName.self, forKey: .name)
        let target = try container.decode(WorkspaceTarget.self, forKey: .workspaceTarget)

        switch name {
        case .focusName:
            self = .focusName(target: target)
        case .moveToMonitor:
            self = .moveToMonitor(
                target: target,
                direction: try container.decode(IPCDirection.self, forKey: .direction),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(target, forKey: .workspaceTarget)

        switch self {
        case .focusName:
            break
        case let .moveToMonitor(_, direction, force):
            try container.encode(direction, forKey: .direction)
            try container.encode(force, forKey: .force)
        }
    }
}

public enum IPCWindowActionName: String, Codable, Equatable, Sendable {
    case focus
    case navigate
    case summonRight = "summon-right"
}

public struct IPCWindowRequest: Codable, Equatable, Sendable {
    public let name: IPCWindowActionName
    public let windowId: String

    public init(name: IPCWindowActionName, windowId: String) {
        self.name = name
        self.windowId = windowId
    }
}

public struct IPCSubscribeRequest: Codable, Equatable, Sendable {
    public let channels: [IPCSubscriptionChannel]
    public let allChannels: Bool
    public let sendInitial: Bool

    public init(
        channels: [IPCSubscriptionChannel],
        allChannels: Bool = false,
        sendInitial: Bool = true
    ) {
        self.channels = channels
        self.allChannels = allChannels
        self.sendInitial = sendInitial
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case none(IPCNoPayload)
        case command(IPCCommandRequest)
        case query(IPCQueryRequest)
        case rule(IPCRuleRequest)
        case workspace(IPCWorkspaceRequest)
        case window(IPCWindowRequest)
        case subscribe(IPCSubscribeRequest)
    }

    public let version: Int
    public let id: String
    public let kind: IPCRequestKind
    public let authorizationToken: String?
    public let payload: Payload

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCRequestKind,
        authorizationToken: String? = nil,
        payload: Payload
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.authorizationToken = authorizationToken
        self.payload = payload
    }

    public init(id: String, command: IPCCommandRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .command, authorizationToken: authorizationToken, payload: .command(command))
    }

    public init(id: String, query: IPCQueryRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .query, authorizationToken: authorizationToken, payload: .query(query))
    }

    public init(id: String, rule: IPCRuleRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .rule, authorizationToken: authorizationToken, payload: .rule(rule))
    }

    public init(id: String, workspace: IPCWorkspaceRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .workspace, authorizationToken: authorizationToken, payload: .workspace(workspace))
    }

    public init(id: String, window: IPCWindowRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .window, authorizationToken: authorizationToken, payload: .window(window))
    }

    public init(id: String, subscribe: IPCSubscribeRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .subscribe, authorizationToken: authorizationToken, payload: .subscribe(subscribe))
    }

    public init(id: String, kind: IPCRequestKind, authorizationToken: String? = nil) {
        self.init(id: id, kind: kind, authorizationToken: authorizationToken, payload: .none(.init()))
    }

    public func authorizing(with token: String?) -> IPCRequest {
        IPCRequest(
            version: version,
            id: id,
            kind: kind,
            authorizationToken: token,
            payload: payload
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case authorizationToken = "authorizationToken"
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(IPCRequestKind.self, forKey: .kind)
        authorizationToken = try container.decodeIfPresent(String.self, forKey: .authorizationToken)

        switch kind {
        case .ping,
             .version:
            payload = .none(try container.decodeIfPresent(IPCNoPayload.self, forKey: .payload) ?? .init())
        case .command:
            payload = .command(try container.decode(IPCCommandRequest.self, forKey: .payload))
        case .query:
            payload = .query(try container.decode(IPCQueryRequest.self, forKey: .payload))
        case .rule:
            payload = .rule(try container.decode(IPCRuleRequest.self, forKey: .payload))
        case .workspace:
            payload = .workspace(try container.decode(IPCWorkspaceRequest.self, forKey: .payload))
        case .window:
            payload = .window(try container.decode(IPCWindowRequest.self, forKey: .payload))
        case .subscribe:
            payload = .subscribe(try container.decode(IPCSubscribeRequest.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(authorizationToken, forKey: .authorizationToken)

        switch payload {
        case let .none(payload):
            try container.encode(payload, forKey: .payload)
        case let .command(payload):
            try container.encode(payload, forKey: .payload)
        case let .query(payload):
            try container.encode(payload, forKey: .payload)
        case let .rule(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspace(payload):
            try container.encode(payload, forKey: .payload)
        case let .window(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscribe(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

public enum IPCResultKind: String, Codable, Equatable, Sendable {
    case pong
    case version
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case apps
    case focusedWindow = "focused-window"
    case windows
    case workspaces
    case displays
    case rules
    case ruleActions = "rule-actions"
    case queries
    case commands
    case subscriptions
    case capabilities
    case subscribed
}

public struct IPCPingResult: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String = "pong") {
        self.message = message
    }
}

public struct IPCVersionResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let appVersion: String?

    public init(protocolVersion: Int = OmniWMIPCProtocol.version, appVersion: String?) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct IPCSubscribeResult: Codable, Equatable, Sendable {
    public let channels: [IPCSubscriptionChannel]

    public init(channels: [IPCSubscriptionChannel]) {
        self.channels = channels
    }
}

public struct IPCSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct IPCRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct IPCWorkspaceBarWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isFocused: Bool

    public init(id: String, title: String, isFocused: Bool) {
        self.id = id
        self.title = title
        self.isFocused = isFocused
    }
}

public struct IPCWorkspaceBarApp: Codable, Equatable, Sendable {
    public let id: String
    public let appName: String
    public let isFocused: Bool
    public let windowCount: Int
    public let allWindows: [IPCWorkspaceBarWindow]

    public init(
        id: String,
        appName: String,
        isFocused: Bool,
        windowCount: Int,
        allWindows: [IPCWorkspaceBarWindow]
    ) {
        self.id = id
        self.appName = appName
        self.isFocused = isFocused
        self.windowCount = windowCount
        self.allWindows = allWindows
    }
}

public struct IPCWorkspaceBarScratchpad: Codable, Equatable, Sendable {
    public let window: IPCWorkspaceBarApp
    public let isVisible: Bool

    public init(window: IPCWorkspaceBarApp, isVisible: Bool) {
        self.window = window
        self.isVisible = isVisible
    }
}

public struct IPCWorkspaceBarWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let rawName: String
    public let displayName: String
    public let number: Int?
    public let isFocused: Bool
    public let windows: [IPCWorkspaceBarApp]

    public init(
        id: String,
        rawName: String,
        displayName: String,
        number: Int?,
        isFocused: Bool,
        windows: [IPCWorkspaceBarApp]
    ) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
        self.isFocused = isFocused
        self.windows = windows
    }
}

public struct IPCWorkspaceBarMonitor: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let isVisible: Bool
    public let showLabels: Bool
    public let backgroundOpacity: Double
    public let barHeight: Double
    public let scratchpad: IPCWorkspaceBarScratchpad?
    public let workspaces: [IPCWorkspaceBarWorkspace]

    public init(
        id: String,
        name: String,
        enabled: Bool,
        isVisible: Bool,
        showLabels: Bool,
        backgroundOpacity: Double,
        barHeight: Double,
        scratchpad: IPCWorkspaceBarScratchpad?,
        workspaces: [IPCWorkspaceBarWorkspace]
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.isVisible = isVisible
        self.showLabels = showLabels
        self.backgroundOpacity = backgroundOpacity
        self.barHeight = barHeight
        self.scratchpad = scratchpad
        self.workspaces = workspaces
    }
}

public struct IPCWorkspaceBarQueryResult: Codable, Equatable, Sendable {
    public let interactionMonitorId: String?
    public let monitors: [IPCWorkspaceBarMonitor]

    public init(interactionMonitorId: String?, monitors: [IPCWorkspaceBarMonitor]) {
        self.interactionMonitorId = interactionMonitorId
        self.monitors = monitors
    }
}

public struct IPCActiveWorkspaceQueryResult: Codable, Equatable, Sendable {
    public let display: IPCDisplayRef?
    public let workspace: IPCWorkspaceRef?
    public let focusedApp: IPCAppRef?

    public init(display: IPCDisplayRef?, workspace: IPCWorkspaceRef?, focusedApp: IPCAppRef?) {
        self.display = display
        self.workspace = workspace
        self.focusedApp = focusedApp
    }
}

public struct IPCFocusedMonitorQueryResult: Codable, Equatable, Sendable {
    public let display: IPCDisplayRef?
    public let activeWorkspace: IPCWorkspaceRef?

    public init(display: IPCDisplayRef?, activeWorkspace: IPCWorkspaceRef?) {
        self.display = display
        self.activeWorkspace = activeWorkspace
    }
}

public struct IPCManagedAppSummary: Codable, Equatable, Sendable {
    public let bundleId: String
    public let appName: String
    public let windowSize: IPCSize

    public init(bundleId: String, appName: String, windowSize: IPCSize) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowSize = windowSize
    }
}

public struct IPCAppsQueryResult: Codable, Equatable, Sendable {
    public let apps: [IPCManagedAppSummary]

    public init(apps: [IPCManagedAppSummary]) {
        self.apps = apps
    }
}

public struct IPCFocusedWindowSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32?
    public let workspace: IPCWorkspaceRef?
    public let display: IPCDisplayRef?
    public let app: IPCAppRef?
    public let title: String?
    public let frame: IPCRect?

    public init(
        id: String,
        pid: Int32? = nil,
        workspace: IPCWorkspaceRef?,
        display: IPCDisplayRef?,
        app: IPCAppRef?,
        title: String?,
        frame: IPCRect?
    ) {
        self.id = id
        self.pid = pid
        self.workspace = workspace
        self.display = display
        self.app = app
        self.title = title
        self.frame = frame
    }
}

public struct IPCFocusedWindowQueryResult: Codable, Equatable, Sendable {
    public let window: IPCFocusedWindowSnapshot?

    public init(window: IPCFocusedWindowSnapshot?) {
        self.window = window
    }
}

public struct IPCWindowQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let pid: Int32?
    public let workspace: IPCWorkspaceRef?
    public let display: IPCDisplayRef?
    public let app: IPCAppRef?
    public let title: String?
    public let frame: IPCRect?
    public let mode: IPCWindowMode?
    public let layoutReason: IPCLayoutReason?
    public let manualOverride: IPCManualWindowOverride?
    public let isFocused: Bool?
    public let isVisible: Bool?
    public let isAppHidden: Bool?
    public let isScratchpad: Bool?
    public let hiddenReason: IPCHiddenReason?

    public init(
        id: String? = nil,
        pid: Int32? = nil,
        workspace: IPCWorkspaceRef? = nil,
        display: IPCDisplayRef? = nil,
        app: IPCAppRef? = nil,
        title: String? = nil,
        frame: IPCRect? = nil,
        mode: IPCWindowMode? = nil,
        layoutReason: IPCLayoutReason? = nil,
        manualOverride: IPCManualWindowOverride? = nil,
        isFocused: Bool? = nil,
        isVisible: Bool? = nil,
        isAppHidden: Bool? = nil,
        isScratchpad: Bool? = nil,
        hiddenReason: IPCHiddenReason? = nil
    ) {
        self.id = id
        self.pid = pid
        self.workspace = workspace
        self.display = display
        self.app = app
        self.title = title
        self.frame = frame
        self.mode = mode
        self.layoutReason = layoutReason
        self.manualOverride = manualOverride
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.isAppHidden = isAppHidden
        self.isScratchpad = isScratchpad
        self.hiddenReason = hiddenReason
    }
}

public struct IPCWindowsQueryResult: Codable, Equatable, Sendable {
    public let windows: [IPCWindowQuerySnapshot]

    public init(windows: [IPCWindowQuerySnapshot]) {
        self.windows = windows
    }
}

public struct IPCWorkspaceQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let rawName: String?
    public let displayName: String?
    public let number: Int?
    public let layout: IPCWorkspaceLayout?
    public let display: IPCDisplayRef?
    public let isFocused: Bool?
    public let isVisible: Bool?
    public let isCurrent: Bool?
    public let counts: IPCWorkspaceWindowCounts?
    public let focusedWindowId: String?

    public init(
        id: String? = nil,
        rawName: String? = nil,
        displayName: String? = nil,
        number: Int? = nil,
        layout: IPCWorkspaceLayout? = nil,
        display: IPCDisplayRef? = nil,
        isFocused: Bool? = nil,
        isVisible: Bool? = nil,
        isCurrent: Bool? = nil,
        counts: IPCWorkspaceWindowCounts? = nil,
        focusedWindowId: String? = nil
    ) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
        self.layout = layout
        self.display = display
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.isCurrent = isCurrent
        self.counts = counts
        self.focusedWindowId = focusedWindowId
    }
}

public struct IPCWorkspacesQueryResult: Codable, Equatable, Sendable {
    public let workspaces: [IPCWorkspaceQuerySnapshot]

    public init(workspaces: [IPCWorkspaceQuerySnapshot]) {
        self.workspaces = workspaces
    }
}

public struct IPCDisplayQuerySnapshot: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let isMain: Bool?
    public let isCurrent: Bool?
    public let frame: IPCRect?
    public let visibleFrame: IPCRect?
    public let hasNotch: Bool?
    public let orientation: IPCDisplayOrientation?
    public let innerGap: Double?
    public let outerGapLeft: Double?
    public let outerGapRight: Double?
    public let outerGapTop: Double?
    public let outerGapBottom: Double?
    public let activeWorkspace: IPCWorkspaceRef?

    public init(
        id: String? = nil,
        name: String? = nil,
        isMain: Bool? = nil,
        isCurrent: Bool? = nil,
        frame: IPCRect? = nil,
        visibleFrame: IPCRect? = nil,
        hasNotch: Bool? = nil,
        orientation: IPCDisplayOrientation? = nil,
        innerGap: Double? = nil,
        outerGapLeft: Double? = nil,
        outerGapRight: Double? = nil,
        outerGapTop: Double? = nil,
        outerGapBottom: Double? = nil,
        activeWorkspace: IPCWorkspaceRef? = nil
    ) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.isCurrent = isCurrent
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.hasNotch = hasNotch
        self.orientation = orientation
        self.innerGap = innerGap
        self.outerGapLeft = outerGapLeft
        self.outerGapRight = outerGapRight
        self.outerGapTop = outerGapTop
        self.outerGapBottom = outerGapBottom
        self.activeWorkspace = activeWorkspace
    }
}

public struct IPCDisplaysQueryResult: Codable, Equatable, Sendable {
    public let displays: [IPCDisplayQuerySnapshot]

    public init(displays: [IPCDisplayQuerySnapshot]) {
        self.displays = displays
    }
}

public struct IPCQueriesQueryResult: Codable, Equatable, Sendable {
    public let queries: [IPCQueryDescriptor]

    public init(queries: [IPCQueryDescriptor]) {
        self.queries = queries
    }
}

public struct IPCRuleActionsQueryResult: Codable, Equatable, Sendable {
    public let ruleActions: [IPCRuleActionDescriptor]

    public init(ruleActions: [IPCRuleActionDescriptor]) {
        self.ruleActions = ruleActions
    }
}

public struct IPCRuleSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let position: Int
    public let bundleId: String
    public let appNameSubstring: String?
    public let titleSubstring: String?
    public let titleRegex: String?
    public let axRole: String?
    public let axSubrole: String?
    public let layout: IPCRuleLayout
    public let assignToWorkspace: String?
    public let initialContainerPrimarySpan: Double?
    public let minWidth: Double?
    public let minHeight: Double?
    public let specificity: Int
    public let isValid: Bool
    public let invalidRegexMessage: String?
    public let validationMessages: [String]

    private enum CodingKeys: String, CodingKey {
        case id, position, bundleId, appNameSubstring, titleSubstring, titleRegex, axRole, axSubrole
        case layout, assignToWorkspace, initialContainerPrimarySpan, minWidth, minHeight, specificity, isValid
        case invalidRegexMessage, validationMessages
    }

    public init(
        id: String,
        position: Int,
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        layout: IPCRuleLayout,
        assignToWorkspace: String? = nil,
        initialContainerPrimarySpan: Double? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        specificity: Int,
        isValid: Bool,
        invalidRegexMessage: String? = nil,
        validationMessages: [String] = []
    ) {
        self.id = id
        self.position = position
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.initialContainerPrimarySpan = initialContainerPrimarySpan
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.specificity = specificity
        self.isValid = isValid
        self.invalidRegexMessage = invalidRegexMessage
        self.validationMessages = validationMessages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        position = try container.decode(Int.self, forKey: .position)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appNameSubstring = try container.decodeIfPresent(String.self, forKey: .appNameSubstring)
        titleSubstring = try container.decodeIfPresent(String.self, forKey: .titleSubstring)
        titleRegex = try container.decodeIfPresent(String.self, forKey: .titleRegex)
        axRole = try container.decodeIfPresent(String.self, forKey: .axRole)
        axSubrole = try container.decodeIfPresent(String.self, forKey: .axSubrole)
        layout = try container.decode(IPCRuleLayout.self, forKey: .layout)
        assignToWorkspace = try container.decodeIfPresent(String.self, forKey: .assignToWorkspace)
        initialContainerPrimarySpan = try container.decodeIfPresent(Double.self, forKey: .initialContainerPrimarySpan)
        minWidth = try container.decodeIfPresent(Double.self, forKey: .minWidth)
        minHeight = try container.decodeIfPresent(Double.self, forKey: .minHeight)
        specificity = try container.decode(Int.self, forKey: .specificity)
        isValid = try container.decode(Bool.self, forKey: .isValid)
        invalidRegexMessage = try container.decodeIfPresent(String.self, forKey: .invalidRegexMessage)
        validationMessages = try container.decodeIfPresent([String].self, forKey: .validationMessages) ?? []
    }
}

public struct IPCRulesQueryResult: Codable, Equatable, Sendable {
    public let rules: [IPCRuleSnapshot]

    public init(rules: [IPCRuleSnapshot]) {
        self.rules = rules
    }
}

public struct IPCCommandsQueryResult: Codable, Equatable, Sendable {
    public let commands: [IPCCommandDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]

    public init(
        commands: [IPCCommandDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor]
    ) {
        self.commands = commands
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
    }
}

public struct IPCSubscriptionsQueryResult: Codable, Equatable, Sendable {
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(subscriptions: [IPCSubscriptionDescriptor]) {
        self.subscriptions = subscriptions
    }
}

public struct IPCCapabilitiesQueryResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let appVersion: String?
    public let authorizationRequired: Bool
    public let windowIdScope: String
    public let queries: [IPCQueryDescriptor]
    public let commands: [IPCCommandDescriptor]
    public let ruleActions: [IPCRuleActionDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(
        protocolVersion: Int = OmniWMIPCProtocol.version,
        appVersion: String?,
        authorizationRequired: Bool,
        windowIdScope: String,
        queries: [IPCQueryDescriptor],
        commands: [IPCCommandDescriptor],
        ruleActions: [IPCRuleActionDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor],
        subscriptions: [IPCSubscriptionDescriptor]
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.authorizationRequired = authorizationRequired
        self.windowIdScope = windowIdScope
        self.queries = queries
        self.commands = commands
        self.ruleActions = ruleActions
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
        self.subscriptions = subscriptions
    }
}

public struct IPCResult: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case pong(IPCPingResult)
        case version(IPCVersionResult)
        case workspaceBar(IPCWorkspaceBarQueryResult)
        case activeWorkspace(IPCActiveWorkspaceQueryResult)
        case focusedMonitor(IPCFocusedMonitorQueryResult)
        case apps(IPCAppsQueryResult)
        case focusedWindow(IPCFocusedWindowQueryResult)
        case windows(IPCWindowsQueryResult)
        case workspaces(IPCWorkspacesQueryResult)
        case displays(IPCDisplaysQueryResult)
        case rules(IPCRulesQueryResult)
        case ruleActions(IPCRuleActionsQueryResult)
        case queries(IPCQueriesQueryResult)
        case commands(IPCCommandsQueryResult)
        case subscriptions(IPCSubscriptionsQueryResult)
        case capabilities(IPCCapabilitiesQueryResult)
        case subscribed(IPCSubscribeResult)
    }

    public let kind: IPCResultKind
    public let payload: Payload

    public init(kind: IPCResultKind, payload: Payload) {
        self.kind = kind
        self.payload = payload
    }

    public init(pong: IPCPingResult) {
        self.init(kind: .pong, payload: .pong(pong))
    }

    public init(version: IPCVersionResult) {
        self.init(kind: .version, payload: .version(version))
    }

    public init(workspaceBar: IPCWorkspaceBarQueryResult) {
        self.init(kind: .workspaceBar, payload: .workspaceBar(workspaceBar))
    }

    public init(activeWorkspace: IPCActiveWorkspaceQueryResult) {
        self.init(kind: .activeWorkspace, payload: .activeWorkspace(activeWorkspace))
    }

    public init(focusedMonitor: IPCFocusedMonitorQueryResult) {
        self.init(kind: .focusedMonitor, payload: .focusedMonitor(focusedMonitor))
    }

    public init(apps: IPCAppsQueryResult) {
        self.init(kind: .apps, payload: .apps(apps))
    }

    public init(focusedWindow: IPCFocusedWindowQueryResult) {
        self.init(kind: .focusedWindow, payload: .focusedWindow(focusedWindow))
    }

    public init(windows: IPCWindowsQueryResult) {
        self.init(kind: .windows, payload: .windows(windows))
    }

    public init(workspaces: IPCWorkspacesQueryResult) {
        self.init(kind: .workspaces, payload: .workspaces(workspaces))
    }

    public init(displays: IPCDisplaysQueryResult) {
        self.init(kind: .displays, payload: .displays(displays))
    }

    public init(rules: IPCRulesQueryResult) {
        self.init(kind: .rules, payload: .rules(rules))
    }

    public init(ruleActions: IPCRuleActionsQueryResult) {
        self.init(kind: .ruleActions, payload: .ruleActions(ruleActions))
    }

    public init(queries: IPCQueriesQueryResult) {
        self.init(kind: .queries, payload: .queries(queries))
    }

    public init(commands: IPCCommandsQueryResult) {
        self.init(kind: .commands, payload: .commands(commands))
    }

    public init(subscriptions: IPCSubscriptionsQueryResult) {
        self.init(kind: .subscriptions, payload: .subscriptions(subscriptions))
    }

    public init(capabilities: IPCCapabilitiesQueryResult) {
        self.init(kind: .capabilities, payload: .capabilities(capabilities))
    }

    public init(subscribed: IPCSubscribeResult) {
        self.init(kind: .subscribed, payload: .subscribed(subscribed))
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(IPCResultKind.self, forKey: .kind)

        switch kind {
        case .pong:
            payload = .pong(try container.decode(IPCPingResult.self, forKey: .payload))
        case .version:
            payload = .version(try container.decode(IPCVersionResult.self, forKey: .payload))
        case .workspaceBar:
            payload = .workspaceBar(try container.decode(IPCWorkspaceBarQueryResult.self, forKey: .payload))
        case .activeWorkspace:
            payload = .activeWorkspace(try container.decode(IPCActiveWorkspaceQueryResult.self, forKey: .payload))
        case .focusedMonitor:
            payload = .focusedMonitor(try container.decode(IPCFocusedMonitorQueryResult.self, forKey: .payload))
        case .apps:
            payload = .apps(try container.decode(IPCAppsQueryResult.self, forKey: .payload))
        case .focusedWindow:
            payload = .focusedWindow(try container.decode(IPCFocusedWindowQueryResult.self, forKey: .payload))
        case .windows:
            payload = .windows(try container.decode(IPCWindowsQueryResult.self, forKey: .payload))
        case .workspaces:
            payload = .workspaces(try container.decode(IPCWorkspacesQueryResult.self, forKey: .payload))
        case .displays:
            payload = .displays(try container.decode(IPCDisplaysQueryResult.self, forKey: .payload))
        case .rules:
            payload = .rules(try container.decode(IPCRulesQueryResult.self, forKey: .payload))
        case .ruleActions:
            payload = .ruleActions(try container.decode(IPCRuleActionsQueryResult.self, forKey: .payload))
        case .queries:
            payload = .queries(try container.decode(IPCQueriesQueryResult.self, forKey: .payload))
        case .commands:
            payload = .commands(try container.decode(IPCCommandsQueryResult.self, forKey: .payload))
        case .subscriptions:
            payload = .subscriptions(try container.decode(IPCSubscriptionsQueryResult.self, forKey: .payload))
        case .capabilities:
            payload = .capabilities(try container.decode(IPCCapabilitiesQueryResult.self, forKey: .payload))
        case .subscribed:
            payload = .subscribed(try container.decode(IPCSubscribeResult.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch payload {
        case let .pong(payload):
            try container.encode(payload, forKey: .payload)
        case let .version(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspaceBar(payload):
            try container.encode(payload, forKey: .payload)
        case let .activeWorkspace(payload):
            try container.encode(payload, forKey: .payload)
        case let .focusedMonitor(payload):
            try container.encode(payload, forKey: .payload)
        case let .apps(payload):
            try container.encode(payload, forKey: .payload)
        case let .focusedWindow(payload):
            try container.encode(payload, forKey: .payload)
        case let .windows(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspaces(payload):
            try container.encode(payload, forKey: .payload)
        case let .displays(payload):
            try container.encode(payload, forKey: .payload)
        case let .rules(payload):
            try container.encode(payload, forKey: .payload)
        case let .ruleActions(payload):
            try container.encode(payload, forKey: .payload)
        case let .queries(payload):
            try container.encode(payload, forKey: .payload)
        case let .commands(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscriptions(payload):
            try container.encode(payload, forKey: .payload)
        case let .capabilities(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscribed(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let kind: IPCResponseKind
    public let ok: Bool
    public let status: IPCResponseStatus
    public let code: IPCErrorCode?
    public let result: IPCResult?

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCResponseKind,
        ok: Bool,
        status: IPCResponseStatus,
        code: IPCErrorCode? = nil,
        result: IPCResult? = nil
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.ok = ok
        self.status = status
        self.code = code
        self.result = result
    }

    public static func success(
        id: String,
        kind: IPCResponseKind,
        status: IPCResponseStatus = .success,
        result: IPCResult? = nil
    ) -> IPCResponse {
        IPCResponse(id: id, kind: kind, ok: true, status: status, result: result)
    }

    public static func failure(
        id: String,
        kind: IPCResponseKind,
        status: IPCResponseStatus = .error,
        code: IPCErrorCode,
        result: IPCResult? = nil
    ) -> IPCResponse {
        IPCResponse(id: id, kind: kind, ok: false, status: status, code: code, result: result)
    }
}

public struct IPCEventEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let kind: IPCEventKind
    public let channel: IPCSubscriptionChannel
    public let ok: Bool
    public let status: IPCResponseStatus
    public let code: IPCErrorCode?
    public let result: IPCResult

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCEventKind = .event,
        channel: IPCSubscriptionChannel,
        ok: Bool = true,
        status: IPCResponseStatus = .success,
        code: IPCErrorCode? = nil,
        result: IPCResult
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.channel = channel
        self.ok = ok
        self.status = status
        self.code = code
        self.result = result
    }

    public static func success(
        id: String,
        channel: IPCSubscriptionChannel,
        status: IPCResponseStatus = .success,
        result: IPCResult
    ) -> IPCEventEnvelope {
        IPCEventEnvelope(
            id: id,
            channel: channel,
            ok: true,
            status: status,
            result: result
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case channel
        case ok
        case status
        case code
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(IPCEventKind.self, forKey: .kind)
        channel = try container.decode(IPCSubscriptionChannel.self, forKey: .channel)
        ok = try container.decode(Bool.self, forKey: .ok)
        status = try container.decode(IPCResponseStatus.self, forKey: .status)
        code = try container.decodeIfPresent(IPCErrorCode.self, forKey: .code)
        result = try container.decode(IPCResult.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(channel, forKey: .channel)
        try container.encode(ok, forKey: .ok)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encode(result, forKey: .result)
    }
}

public enum IPCWindowOpaqueIDValidationResult: Equatable, Sendable {
    case valid(pid: Int32, windowId: Int)
    case stale
    case invalid
}

public enum IPCWindowOpaqueID {
    private struct DecodedPayload {
        let sessionToken: String
        let pid: Int32
        let windowId: Int
    }

    public static func encode(pid: Int32, windowId: Int, sessionToken: String) -> String {
        let payload = "\(sessionToken):\(pid):\(windowId)"
        return "ow_" + base64URLEncoded(Data(payload.utf8))
    }

    public static func validate(
        _ value: String,
        expectingSessionToken sessionToken: String
    ) -> IPCWindowOpaqueIDValidationResult {
        guard let decoded = decodePayload(value) else {
            return .invalid
        }
        guard decoded.sessionToken == sessionToken else {
            return .stale
        }
        return .valid(pid: decoded.pid, windowId: decoded.windowId)
    }

    public static func decode(
        _ value: String,
        expectingSessionToken sessionToken: String
    ) -> (pid: Int32, windowId: Int)? {
        switch validate(value, expectingSessionToken: sessionToken) {
        case let .valid(pid, windowId):
            return (pid, windowId)
        case .stale,
             .invalid:
            return nil
        }
    }

    private static func decodePayload(_ value: String) -> DecodedPayload? {
        guard value.hasPrefix("ow_") else { return nil }
        let encoded = String(value.dropFirst(3))
        guard let data = base64URLDecoded(encoded),
              let payload = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let bytes = payload.utf8
        guard let windowDelimiter = bytes.lastIndex(of: 0x3A),
              let pidDelimiter = bytes[..<windowDelimiter].lastIndex(of: 0x3A)
        else {
            return nil
        }

        let pidStart = bytes.index(after: pidDelimiter)
        let windowStart = bytes.index(after: windowDelimiter)
        guard let sessionToken = String(bytes: bytes[..<pidDelimiter], encoding: .utf8),
              let pidText = String(bytes: bytes[pidStart ..< windowDelimiter], encoding: .utf8),
              let windowText = String(bytes: bytes[windowStart...], encoding: .utf8),
              let pid = Int32(pidText),
              let windowId = Int(windowText)
        else {
            return nil
        }

        return DecodedPayload(
            sessionToken: sessionToken,
            pid: pid,
            windowId: windowId
        )
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        let remainder = value.count % 4
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        return Data(base64Encoded: base64)
    }
}
