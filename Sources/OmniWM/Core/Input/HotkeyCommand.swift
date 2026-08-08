// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct PhysicalHotkeyTrigger: Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let isRepeat: Bool
}

struct HotkeyInvocation: Equatable, Sendable {
    let command: HotkeyCommand
    let trigger: PhysicalHotkeyTrigger?

    init(command: HotkeyCommand, trigger: PhysicalHotkeyTrigger? = nil) {
        self.command = command
        self.trigger = trigger
    }
}

enum LayoutCompatibility: String {
    case shared = "Shared"
    case niri = "Niri"
    case dwindle = "Dwindle"
}

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focus(Direction)
    case focusPrevious
    case move(Direction)
    case moveToWorkspace(Int)
    case moveWindowToWorkspaceUp
    case moveWindowToWorkspaceDown
    case moveWindowToMonitor(Direction)
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceUp
    case moveColumnToWorkspaceDown
    case switchWorkspace(Int)
    case switchWorkspaceNext
    case switchWorkspacePrevious
    case focusMonitorPrevious
    case focusMonitorNext
    case focusMonitorLast
    case toggleFullscreen
    case toggleNativeFullscreen
    case moveColumn(Direction)
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToIndex(Int)
    case moveWindowDown
    case moveWindowUp
    case moveWindowDownOrToWorkspaceDown
    case moveWindowUpOrToWorkspaceUp
    case consumeOrExpelWindowLeft
    case consumeOrExpelWindowRight
    case consumeWindowIntoColumn
    case expelWindowFromColumn
    case toggleColumnTabbed

    case focusDownOrLeft
    case focusUpOrRight
    case focusWindowInColumn(Int)
    case focusWindowTop
    case focusWindowBottom
    case focusWindowDownOrTop
    case focusWindowUpOrBottom
    case focusWindowOrWorkspaceDown
    case focusWindowOrWorkspaceUp
    case focusColumnFirst
    case focusColumnLast
    case focusColumn(Int)
    case centerColumn
    case centerVisibleColumns
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case setContainerPrimarySpan(NiriSizeChange)
    case setWindowPrimarySpan(NiriSizeChange)
    case setWindowSecondarySpan(NiriSizeChange)

    case moveWorkspaceToMonitor(Direction)
    case swapWorkspaceWithMonitor(Direction)

    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resizeInDirection(Direction, Bool)
    case resizeFocusedWindow(Bool)
    case preselect(Direction)
    case preselectClear

    case workspaceBackAndForth
    case focusWorkspaceAnywhere(Int)
    case moveWindowToWorkspaceOnMonitor(workspaceIndex: Int, monitorDirection: Direction)

    case openCommandPalette

    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case toggleFocusedWindowFloating
    case assignFocusedWindowToScratchpad
    case toggleScratchpadWindow

    case openMenuAnywhere

    case toggleWorkspaceBarVisibility
    case toggleHiddenBarPanel
    case toggleQuakeTerminal
    case toggleWorkspaceLayout
    case toggleOverview
    case toggleSystemStats

    var displayName: String {
        ActionCatalog.title(for: self) ?? String(describing: self)
    }

    var layoutCompatibility: LayoutCompatibility {
        ActionCatalog.layoutCompatibility(for: self) ?? .shared
    }
}
