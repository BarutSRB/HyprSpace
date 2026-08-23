// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public enum IPCAutomationLayoutCompatibility: String, Codable, CaseIterable, Equatable, Sendable {
    case shared
    case niri
    case dwindle
}

public enum IPCQuerySelectorName: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case window
    case workspace
    case display
    case focused
    case visible
    case floating
    case scratchpad
    case app
    case bundleId = "bundle-id"
    case current
    case main

    public var flag: String {
        "--\(rawValue)"
    }

    public var expectsValue: Bool {
        switch self {
        case .window,
             .workspace,
             .display,
             .app,
             .bundleId:
            true
        case .focused,
             .visible,
             .floating,
             .scratchpad,
             .current,
             .main:
            false
        }
    }
}

public enum IPCCommandArgumentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case direction
    case workspaceNumber = "workspace-number"
    case columnIndex = "column-index"
    case windowIndex = "window-index"
    case layout
    case resizeAxis = "resize-axis"
    case resizeOperation = "resize-operation"
    case sizeChange = "size-change"

    public var usagePlaceholder: String {
        switch self {
        case .direction:
            "<left|right|up|down>"
        case .workspaceNumber,
             .columnIndex,
             .windowIndex:
            "<number>"
        case .layout:
            "<default|niri|dwindle>"
        case .resizeAxis:
            "<horizontal|vertical>"
        case .resizeOperation:
            "<grow|shrink>"
        case .sizeChange:
            "<size-change>"
        }
    }
}

public struct IPCQuerySelectorDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQuerySelectorName
    public let summary: String

    public init(name: IPCQuerySelectorName, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public struct IPCQueryDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQueryName
    public let summary: String
    public let selectors: [IPCQuerySelectorDescriptor]
    public let fields: [String]

    public init(
        name: IPCQueryName,
        summary: String,
        selectors: [IPCQuerySelectorDescriptor] = [],
        fields: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.selectors = selectors
        self.fields = fields
    }
}

public struct IPCCommandArgumentDescriptor: Codable, Equatable, Sendable {
    public let kind: IPCCommandArgumentKind
    public let summary: String

    public init(kind: IPCCommandArgumentKind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public struct IPCCommandDescriptor: Codable, Equatable, Sendable {
    public let commandWords: [String]
    public let path: String
    public let name: IPCCommandName
    public let summary: String
    public let arguments: [IPCCommandArgumentDescriptor]
    public let layoutCompatibility: IPCAutomationLayoutCompatibility

    public init(
        commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) {
        self.commandWords = commandWords
        self.path = IPCCommandDescriptor.makePath(commandWords: commandWords, arguments: arguments)
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.layoutCompatibility = layoutCompatibility
    }

    private static func makePath(
        commandWords: [String],
        arguments: [IPCCommandArgumentDescriptor]
    ) -> String {
        let parts = ["command"] + commandWords + arguments.map(\.kind.usagePlaceholder)
        return parts.joined(separator: " ")
    }
}

public struct IPCWorkspaceActionDescriptor: Codable, Equatable, Sendable {
    public let actionWords: [String]
    public let path: String
    public let name: IPCWorkspaceActionName
    public let summary: String
    public let arguments: [String]
    public let optionalFlags: [String]

    public init(
        actionWords: [String],
        name: IPCWorkspaceActionName,
        summary: String,
        arguments: [String] = [],
        optionalFlags: [String] = []
    ) {
        self.actionWords = actionWords
        path = Self.makePath(actionWords: actionWords, arguments: arguments, optionalFlags: optionalFlags)
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.optionalFlags = optionalFlags
    }

    private static func makePath(
        actionWords: [String],
        arguments: [String],
        optionalFlags: [String]
    ) -> String {
        let parts = ["workspace"] + actionWords + arguments.map { "<\($0)>" } + optionalFlags.map { "[\($0)]" }
        return parts.joined(separator: " ")
    }
}

public struct IPCWindowActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWindowActionName
    public let summary: String
    public let arguments: [String]

    public init(
        path: String,
        name: IPCWindowActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCRuleActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCRuleActionName
    public let summary: String
    public let arguments: [String]
    public let options: [IPCRuleActionOptionDescriptor]

    public init(
        path: String,
        name: IPCRuleActionName,
        summary: String,
        arguments: [String] = [],
        options: [IPCRuleActionOptionDescriptor] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.options = options
    }
}

public struct IPCRuleActionOptionDescriptor: Codable, Equatable, Sendable {
    public let flag: String
    public let summary: String
    public let valuePlaceholder: String?
    public let exclusiveGroup: String?

    public init(
        flag: String,
        summary: String,
        valuePlaceholder: String? = nil,
        exclusiveGroup: String? = nil
    ) {
        self.flag = flag
        self.summary = summary
        self.valuePlaceholder = valuePlaceholder
        self.exclusiveGroup = exclusiveGroup
    }
}

public struct IPCSubscriptionDescriptor: Codable, Equatable, Sendable {
    public let channel: IPCSubscriptionChannel
    public let summary: String
    public let resultKind: IPCResultKind

    public init(channel: IPCSubscriptionChannel, summary: String, resultKind: IPCResultKind) {
        self.channel = channel
        self.summary = summary
        self.resultKind = resultKind
    }
}

public enum IPCAutomationManifest {
    private static let directionArgument = IPCCommandArgumentDescriptor(
        kind: .direction,
        summary: "Direction argument."
    )
    private static let workspaceNumberArgument = IPCCommandArgumentDescriptor(
        kind: .workspaceNumber,
        summary: "Positive numeric workspace ID."
    )
    private static let columnIndexArgument = IPCCommandArgumentDescriptor(
        kind: .columnIndex,
        summary: "One-based column index."
    )
    private static let windowIndexArgument = IPCCommandArgumentDescriptor(
        kind: .windowIndex,
        summary: "One-based window index within the focused column."
    )
    private static let layoutArgument = IPCCommandArgumentDescriptor(
        kind: .layout,
        summary: "Workspace layout selection."
    )
    private static let resizeAxisArgument = IPCCommandArgumentDescriptor(
        kind: .resizeAxis,
        summary: "Dwindle split axis."
    )
    private static let resizeOperationArgument = IPCCommandArgumentDescriptor(
        kind: .resizeOperation,
        summary: "Whether to grow or shrink."
    )
    private static let sizeChangeArgument = IPCCommandArgumentDescriptor(
        kind: .sizeChange,
        summary: "Size change such as 100, 50%, +10, or -10%."
    )

    private static func command(
        _ commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) -> IPCCommandDescriptor {
        IPCCommandDescriptor(
            commandWords: commandWords,
            name: name,
            summary: summary,
            arguments: arguments,
            layoutCompatibility: layoutCompatibility
        )
    }

    public static let windowFieldCatalog: [String] = [
        "id",
        "pid",
        "workspace",
        "display",
        "app",
        "title",
        "frame",
        "mode",
        "layout-reason",
        "manual-override",
        "is-focused",
        "is-visible",
        "is-app-hidden",
        "is-scratchpad",
        "hidden-reason"
    ]

    public static let workspaceFieldCatalog: [String] = [
        "id",
        "raw-name",
        "display-name",
        "number",
        "layout",
        "display",
        "is-focused",
        "is-visible",
        "is-current",
        "window-counts",
        "focused-window-id"
    ]

    public static let displayFieldCatalog: [String] = [
        "id",
        "name",
        "is-main",
        "is-current",
        "frame",
        "visible-frame",
        "has-notch",
        "orientation",
        "inner-gap",
        "outer-gap-left",
        "outer-gap-right",
        "outer-gap-top",
        "outer-gap-bottom",
        "active-workspace"
    ]

    public static let queryDescriptors: [IPCQueryDescriptor] = [
        IPCQueryDescriptor(
            name: .workspaceBar,
            summary: "Return the workspace bar projection for every monitor."
        ),
        IPCQueryDescriptor(
            name: .activeWorkspace,
            summary: "Return the current interaction monitor and active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .focusedMonitor,
            summary: "Return the current interaction monitor and its active workspace snapshot."
        ),
        IPCQueryDescriptor(
            name: .apps,
            summary: "Return the managed app summary used by OmniWM surfaces."
        ),
        IPCQueryDescriptor(
            name: .focusedWindow,
            summary: "Return the focused managed window snapshot."
        ),
        IPCQueryDescriptor(
            name: .windows,
            summary: "Return managed OmniWM windows only.",
            selectors: [
                .init(name: .window, summary: "Filter by a session-scoped opaque window id."),
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .focused, summary: "Only include the focused managed window."),
                .init(
                    name: .visible,
                    summary: "Only include windows on visible workspaces that are neither hidden nor owned by a hidden app."
                ),
                .init(name: .floating, summary: "Only include floating managed windows."),
                .init(name: .scratchpad, summary: "Only include the scratchpad window."),
                .init(name: .app, summary: "Filter by application display name."),
                .init(name: .bundleId, summary: "Filter by application bundle identifier.")
            ],
            fields: windowFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .workspaces,
            summary: "Return configured workspaces with live occupancy and monitor assignment.",
            selectors: [
                .init(name: .workspace, summary: "Filter by workspace raw name, display name, or id."),
                .init(name: .display, summary: "Filter by active monitor name or display id."),
                .init(name: .current, summary: "Only include the interaction monitor's active workspace."),
                .init(name: .visible, summary: "Only include visible workspaces."),
                .init(name: .focused, summary: "Only include the workspace containing the focused managed window.")
            ],
            fields: workspaceFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .displays,
            summary: "Return connected displays with live geometry and active workspace state.",
            selectors: [
                .init(name: .display, summary: "Filter by display name or display id."),
                .init(name: .main, summary: "Only include the main display."),
                .init(name: .current, summary: "Only include the interaction display.")
            ],
            fields: displayFieldCatalog
        ),
        IPCQueryDescriptor(
            name: .rules,
            summary: "Return persisted user window rules with normalized public fields."
        ),
        IPCQueryDescriptor(
            name: .ruleActions,
            summary: "Return the public persisted-rule action registry."
        ),
        IPCQueryDescriptor(
            name: .queries,
            summary: "Return the public automation query registry."
        ),
        IPCQueryDescriptor(
            name: .commands,
            summary: "Return the public automation command registry."
        ),
        IPCQueryDescriptor(
            name: .subscriptions,
            summary: "Return the public subscription registry."
        ),
        IPCQueryDescriptor(
            name: .capabilities,
            summary: "Return protocol, command, query, selector, and subscription capabilities."
        )
    ]

    public static let commandDescriptors: [IPCCommandDescriptor] = [
        command(
            ["focus"],
            name: .focus,
            summary: "Focus spatially; Dwindle Up/Down traverse grouped tabs before edge fallback.",
            arguments: [directionArgument]
        ),
        command(
            ["focus", "previous"],
            name: .focusPrevious,
            summary: "Focus the previously focused window.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus", "down-or-left"],
            name: .focusDownOrLeft,
            summary: "Traverse backward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus", "up-or-right"],
            name: .focusUpOrRight,
            summary: "Traverse forward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window-in-column"],
            name: .focusWindowInColumn,
            summary: "Focus a window in the focused Niri column by one-based index.",
            arguments: [windowIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "top"],
            name: .focusWindowTop,
            summary: "Focus the top window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "bottom"],
            name: .focusWindowBottom,
            summary: "Focus the bottom window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window", "down-or-top"],
            name: .focusWindowDownOrTop,
            summary: "Focus the next window in the active Niri column or Dwindle group, wrapping to the top."
        ),
        command(
            ["focus-window", "up-or-bottom"],
            name: .focusWindowUpOrBottom,
            summary: "Focus the previous window in the active Niri column or Dwindle group, wrapping to the bottom."
        ),
        command(
            ["focus-window-or-workspace-down"],
            name: .focusWindowOrWorkspaceDown,
            summary: "Focus down using the active Niri orientation; if no target exists, switch without wrapping to the workspace below.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-window-or-workspace-up"],
            name: .focusWindowOrWorkspaceUp,
            summary: "Focus up using the active Niri orientation; if no target exists, switch without wrapping to the workspace above.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column"],
            name: .focusColumn,
            summary: "Focus a Niri column by one-based index.",
            arguments: [columnIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column", "first"],
            name: .focusColumnFirst,
            summary: "Focus the first Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["focus-column", "last"],
            name: .focusColumnLast,
            summary: "Focus the last Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["center-column"],
            name: .centerColumn,
            summary: "Center the focused Niri column without changing focus.",
            layoutCompatibility: .niri
        ),
        command(
            ["center-visible-columns"],
            name: .centerVisibleColumns,
            summary: "Center the current block of fully visible Niri columns in the viewport.",
            layoutCompatibility: .niri
        ),
        command(
            ["move"],
            name: .move,
            summary: "Move with layout-aware consume/expel or Dwindle join/extract behavior.",
            arguments: [directionArgument]
        ),
        command(
            ["move-window-down"],
            name: .moveWindowDown,
            summary: "Reorder the focused window down by one without wrapping within its Niri column or Dwindle group."
        ),
        command(
            ["move-window-up"],
            name: .moveWindowUp,
            summary: "Reorder the focused window up by one without wrapping within its Niri column or Dwindle group."
        ),
        command(
            ["move-window-down-or-to-workspace-down"],
            name: .moveWindowDownOrToWorkspaceDown,
            summary: "Move the focused Niri window down, or to the workspace below at the column edge.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-window-up-or-to-workspace-up"],
            name: .moveWindowUpOrToWorkspaceUp,
            summary: "Move the focused Niri window up, or to the workspace above at the column edge.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-or-expel-window-left"],
            name: .consumeOrExpelWindowLeft,
            summary: "Consume the focused Niri window into the column to the left, or expel it left from its column.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-or-expel-window-right"],
            name: .consumeOrExpelWindowRight,
            summary: "Consume the focused Niri window into the column to the right, or expel it right from its column.",
            layoutCompatibility: .niri
        ),
        command(
            ["consume-window-into-column"],
            name: .consumeWindowIntoColumn,
            summary: "Consume the top window from the next Niri column into the focused column.",
            layoutCompatibility: .niri
        ),
        command(
            ["expel-window-from-column"],
            name: .expelWindowFromColumn,
            summary: "Expel the bottom window from the focused Niri column into a new following column.",
            layoutCompatibility: .niri
        ),
        command(
            ["switch-workspace"],
            name: .switchWorkspace,
            summary: "Switch to a workspace on the interaction monitor by workspace ID.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["switch-workspace", "next"],
            name: .switchWorkspaceNext,
            summary: "Switch to the next workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "prev"],
            name: .switchWorkspacePrevious,
            summary: "Switch to the previous workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "back-and-forth"],
            name: .switchWorkspaceBackAndForth,
            summary: "Switch to the previously active workspace on the current monitor."
        ),
        command(
            ["switch-workspace", "anywhere"],
            name: .switchWorkspaceAnywhere,
            summary: "Focus a workspace by workspace ID across all monitors.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["move-to-workspace"],
            name: .moveToWorkspace,
            summary: "Move the focused window to a workspace by workspace ID.",
            arguments: [workspaceNumberArgument]
        ),
        command(
            ["move-to-workspace", "up"],
            name: .moveToWorkspaceUp,
            summary: "Move the focused window to the adjacent workspace above."
        ),
        command(
            ["move-to-workspace", "down"],
            name: .moveToWorkspaceDown,
            summary: "Move the focused window to the adjacent workspace below."
        ),
        command(
            ["move-to-workspace", "on-monitor"],
            name: .moveToWorkspaceOnMonitor,
            summary: "Move the focused window to a workspace already assigned to the requested adjacent monitor.",
            arguments: [workspaceNumberArgument, directionArgument]
        ),
        command(
            ["move-to-monitor"],
            name: .moveToMonitor,
            summary: "Move the focused window to the active workspace on the adjacent monitor.",
            arguments: [directionArgument]
        ),
        command(
            ["focus-monitor", "prev"],
            name: .focusMonitorPrevious,
            summary: "Move interaction focus to the previous monitor."
        ),
        command(
            ["focus-monitor", "next"],
            name: .focusMonitorNext,
            summary: "Move interaction focus to the next monitor."
        ),
        command(
            ["focus-monitor", "last"],
            name: .focusMonitorLast,
            summary: "Move interaction focus back to the previous monitor."
        ),
        command(
            ["move-column"],
            name: .moveColumn,
            summary: "Move a Niri column horizontally or a complete Dwindle tile/group without monitor fallback.",
            arguments: [directionArgument]
        ),
        command(
            ["move-column-to-first"],
            name: .moveColumnToFirst,
            summary: "Move the focused Niri column to the first position.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-last"],
            name: .moveColumnToLast,
            summary: "Move the focused Niri column to the last position.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-index"],
            name: .moveColumnToIndex,
            summary: "Move the focused Niri column to a one-based index.",
            arguments: [columnIndexArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace"],
            name: .moveColumnToWorkspace,
            summary: "Move the focused Niri column to a Niri workspace by workspace ID.",
            arguments: [workspaceNumberArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace", "up"],
            name: .moveColumnToWorkspaceUp,
            summary: "Move the focused Niri column to the adjacent workspace above.",
            layoutCompatibility: .niri
        ),
        command(
            ["move-column-to-workspace", "down"],
            name: .moveColumnToWorkspaceDown,
            summary: "Move the focused Niri column to the adjacent workspace below.",
            layoutCompatibility: .niri
        ),
        command(
            ["toggle-column-tabbed"],
            name: .toggleColumnTabbed,
            summary: "Toggle tabbed mode for the focused Niri column.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-size", "forward"],
            name: .cycleSizeForward,
            summary: "Cycle layout sizing presets forward."
        ),
        command(
            ["cycle-size", "backward"],
            name: .cycleSizeBackward,
            summary: "Cycle layout sizing presets backward."
        ),
        command(
            ["cycle-window-primary-span", "forward"],
            name: .cycleWindowPrimarySpanForward,
            summary: "Cycle Niri window primary-span presets forward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-primary-span", "backward"],
            name: .cycleWindowPrimarySpanBackward,
            summary: "Cycle Niri window primary-span presets backward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-secondary-span", "forward"],
            name: .cycleWindowSecondarySpanForward,
            summary: "Cycle Niri window secondary-span presets forward.",
            layoutCompatibility: .niri
        ),
        command(
            ["cycle-window-secondary-span", "backward"],
            name: .cycleWindowSecondarySpanBackward,
            summary: "Cycle Niri window secondary-span presets backward.",
            layoutCompatibility: .niri
        ),
        command(
            ["toggle-container-full-primary-span"],
            name: .toggleContainerFullPrimarySpan,
            summary: "Toggle full-primary-span mode for the focused Niri container.",
            layoutCompatibility: .niri
        ),
        command(
            ["expand-container-to-available-primary-span"],
            name: .expandContainerToAvailablePrimarySpan,
            summary: "Expand the focused Niri container into available primary-axis space.",
            layoutCompatibility: .niri
        ),
        command(
            ["reset-window-secondary-span"],
            name: .resetWindowSecondarySpan,
            summary: "Reset the focused Niri window secondary span.",
            layoutCompatibility: .niri
        ),
        command(
            ["set-container-primary-span"],
            name: .setContainerPrimarySpan,
            summary: "Set or adjust the focused Niri container primary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["set-window-primary-span"],
            name: .setWindowPrimarySpan,
            summary: "Set or adjust the focused Niri window primary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["set-window-secondary-span"],
            name: .setWindowSecondarySpan,
            summary: "Set or adjust the focused Niri window secondary span.",
            arguments: [sizeChangeArgument],
            layoutCompatibility: .niri
        ),
        command(
            ["swap-workspace-with-monitor"],
            name: .swapWorkspaceWithMonitor,
            summary: "Swap the active workspace with the active workspace on an adjacent monitor.",
            arguments: [directionArgument]
        ),
        command(["balance-sizes"], name: .balanceSizes, summary: "Balance layout sizes in the active workspace."),
        command(
            ["move-to-root"],
            name: .moveToRoot,
            summary: "Move the selected Dwindle window to the root split.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["toggle-split"],
            name: .toggleSplit,
            summary: "Toggle the active Dwindle split orientation.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["swap-split"],
            name: .swapSplit,
            summary: "Swap the active Dwindle split.",
            layoutCompatibility: .dwindle
        ),
        command(
            ["resize"],
            name: .resize,
            summary: "Resize the selected Dwindle window.",
            arguments: [resizeAxisArgument, resizeOperationArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["resize-focused"],
            name: .resizeFocused,
            summary: "Grow or shrink the focused Dwindle window.",
            arguments: [resizeOperationArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["preselect"],
            name: .preselect,
            summary: "Set the Dwindle preselection direction.",
            arguments: [directionArgument],
            layoutCompatibility: .dwindle
        ),
        command(
            ["preselect", "clear"],
            name: .preselectClear,
            summary: "Clear the Dwindle preselection.",
            layoutCompatibility: .dwindle
        ),
        command(["open-command-palette"], name: .openCommandPalette, summary: "Toggle the command palette."),
        command(
            ["raise-all-floating-windows"],
            name: .raiseAllFloatingWindows,
            summary: "Raise all visible floating windows."
        ),
        command(
            ["rescue-offscreen-windows"],
            name: .rescueOffscreenWindows,
            summary: "Clamp tracked floating windows back onto their visible monitors."
        ),
        command(
            ["toggle-focused-window-floating"],
            name: .toggleFocusedWindowFloating,
            summary: "Toggle the focused managed window between tiled and floating."
        ),
        command(
            ["scratchpad", "assign"],
            name: .scratchpadAssign,
            summary: "Assign the focused managed window to the scratchpad."
        ),
        command(["scratchpad", "toggle"], name: .scratchpadToggle, summary: "Show or hide the scratchpad window."),
        command(["open-menu-anywhere"], name: .openMenuAnywhere, summary: "Open the menu surface anywhere."),
        command(
            ["toggle-workspace-bar"],
            name: .toggleWorkspaceBar,
            summary: "Toggle runtime workspace bar visibility."
        ),
        command(["hidden-bar", "panel"], name: .hiddenBarPanel, summary: "Toggle the hidden-bar items panel."),
        command(
            ["toggle-quake-terminal"],
            name: .toggleQuakeTerminal,
            summary: "Toggle the configured Quake terminal."
        ),
        command(
            ["toggle-workspace-layout"],
            name: .toggleWorkspaceLayout,
            summary: "Toggle the current workspace between Niri and Dwindle."
        ),
        command(
            ["set-workspace-layout"],
            name: .setWorkspaceLayout,
            summary: "Set the current workspace layout explicitly.",
            arguments: [layoutArgument]
        ),
        command(["toggle-fullscreen"], name: .toggleFullscreen, summary: "Toggle OmniWM-managed fullscreen."),
        command(
            ["toggle-native-fullscreen"],
            name: .toggleNativeFullscreen,
            summary: "Toggle native macOS fullscreen."
        ),
        command(["toggle-overview"], name: .toggleOverview, summary: "Toggle the overview surface."),
        command(
            ["toggle-system-stats"],
            name: .toggleSystemStats,
            summary: "Toggle the system stats popup when a workspace-bar System Stats button is available."
        )
    ]

    public static let workspaceActionDescriptors: [IPCWorkspaceActionDescriptor] = [
        .init(
            actionWords: ["focus-name"],
            name: .focusName,
            summary: "Focus a workspace by raw workspace ID or unambiguous configured display name.",
            arguments: ["name"]
        ),
        .init(
            actionWords: ["move-to-monitor"],
            name: .moveToMonitor,
            summary: "Move a workspace to an adjacent monitor; --force temporarily overrides its configured assignment.",
            arguments: ["workspace", "left|right|up|down"],
            optionalFlags: ["--force"]
        )
    ]

    public static let windowActionDescriptors: [IPCWindowActionDescriptor] = [
        .init(
            path: "window focus <opaque-id>",
            name: .focus,
            summary: "Focus a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window navigate <opaque-id>",
            name: .navigate,
            summary: "Navigate to a managed window by session-scoped opaque id.",
            arguments: ["opaque-id"]
        ),
        .init(
            path: "window summon-right <opaque-id>",
            name: .summonRight,
            summary: "Summon a managed window to the right of the focused window.",
            arguments: ["opaque-id"]
        )
    ]

    public static let ruleDefinitionOptionDescriptors: [IPCRuleActionOptionDescriptor] = [
        .init(
            flag: "--bundle-id",
            summary: "Match windows by application bundle identifier.",
            valuePlaceholder: "<bundle-id>"
        ),
        .init(
            flag: "--app-name-substring",
            summary: "Match windows by application display-name substring.",
            valuePlaceholder: "<text>"
        ),
        .init(
            flag: "--title-substring",
            summary: "Match windows by title substring.",
            valuePlaceholder: "<text>"
        ),
        .init(
            flag: "--title-regex",
            summary: "Match windows by title regular expression.",
            valuePlaceholder: "<pattern>"
        ),
        .init(
            flag: "--ax-role",
            summary: "Match windows by accessibility role.",
            valuePlaceholder: "<role>"
        ),
        .init(
            flag: "--ax-subrole",
            summary: "Match windows by accessibility subrole.",
            valuePlaceholder: "<subrole>"
        ),
        .init(
            flag: "--layout",
            summary: "Set the rule layout action.",
            valuePlaceholder: "<auto|tile|float>"
        ),
        .init(
            flag: "--assign-to-workspace",
            summary: "Assign matching windows to a workspace name.",
            valuePlaceholder: "<name>"
        ),
        .init(
            flag: "--initial-container-primary-span",
            summary: "Set the initial Niri container primary-span proportion for resizable windows (0.05 through 1.0).",
            valuePlaceholder: "<proportion>"
        ),
        .init(
            flag: "--min-width",
            summary: "Set the minimum floating width in points.",
            valuePlaceholder: "<points>"
        ),
        .init(
            flag: "--min-height",
            summary: "Set the minimum floating height in points.",
            valuePlaceholder: "<points>"
        )
    ]

    public static let ruleActionDescriptors: [IPCRuleActionDescriptor] = [
        .init(
            path: "rule add [options]",
            name: .add,
            summary: "Append a new persisted user rule.",
            options: ruleDefinitionOptionDescriptors
        ),
        .init(
            path: "rule replace <rule-id> [options]",
            name: .replace,
            summary: "Replace a persisted user rule in place.",
            arguments: ["rule-id"],
            options: ruleDefinitionOptionDescriptors
        ),
        .init(
            path: "rule remove <rule-id>",
            name: .remove,
            summary: "Remove a persisted user rule.",
            arguments: ["rule-id"]
        ),
        .init(
            path: "rule move <rule-id> <position>",
            name: .move,
            summary: "Move a persisted user rule to a one-based position.",
            arguments: ["rule-id", "position"]
        ),
        .init(
            path: "rule apply [--focused|--window <opaque-id>|--pid <pid>]",
            name: .apply,
            summary: "Reapply the current rule set to a focused window, explicit window id, or process.",
            options: [
                .init(
                    flag: "--focused",
                    summary: "Reapply rules to the currently focused automation target.",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--window",
                    summary: "Reapply rules to a specific managed window by opaque id.",
                    valuePlaceholder: "<opaque-id>",
                    exclusiveGroup: "target"
                ),
                .init(
                    flag: "--pid",
                    summary: "Reapply rules to all managed windows for a process id.",
                    valuePlaceholder: "<pid>",
                    exclusiveGroup: "target"
                )
            ]
        )
    ]

    public static let subscriptionDescriptors: [IPCSubscriptionDescriptor] = [
        .init(channel: .focus, summary: "Focused window snapshot updates.", resultKind: .focusedWindow),
        .init(
            channel: .workspaceBar,
            summary: "Workspace bar projection updates.",
            resultKind: .workspaceBar
        ),
        .init(
            channel: .activeWorkspace,
            summary: "Interaction monitor and active workspace updates.",
            resultKind: .activeWorkspace
        ),
        .init(
            channel: .focusedMonitor,
            summary: "Focused monitor updates for the current interaction target.",
            resultKind: .focusedMonitor
        ),
        .init(
            channel: .windowsChanged,
            summary: "Managed window inventory updates.",
            resultKind: .windows
        ),
        .init(
            channel: .displayChanged,
            summary: "Display state updates.",
            resultKind: .displays
        ),
        .init(
            channel: .layoutChanged,
            summary: "Workspace layout updates.",
            resultKind: .workspaces
        )
    ]

    public static func queryDescriptor(for name: IPCQueryName) -> IPCQueryDescriptor? {
        queryDescriptors.first { $0.name == name }
    }

    public static func commandDescriptor(for name: IPCCommandName) -> IPCCommandDescriptor? {
        commandDescriptors.first { $0.name == name }
    }

    public static func ruleActionDescriptor(for name: IPCRuleActionName) -> IPCRuleActionDescriptor? {
        ruleActionDescriptors.first { $0.name == name }
    }

    public static func commandDescriptors(matching commandWords: [String]) -> [IPCCommandDescriptor] {
        commandDescriptors
            .sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.path < $1.path
            }
            .filter { descriptor in
                guard commandWords.count >= descriptor.commandWords.count else { return false }
                return Array(commandWords.prefix(descriptor.commandWords.count)) == descriptor.commandWords
            }
    }

    public static func workspaceActionDescriptors(matching actionWords: [String]) -> [IPCWorkspaceActionDescriptor] {
        workspaceActionDescriptors
            .sorted { $0.path < $1.path }
            .filter { descriptor in
                guard actionWords.count >= descriptor.actionWords.count else { return false }
                return Array(actionWords.prefix(descriptor.actionWords.count)) == descriptor.actionWords
            }
    }

    public static func expandedChannels(for request: IPCSubscribeRequest) -> [IPCSubscriptionChannel] {
        let channels = request.allChannels ? IPCSubscriptionChannel.allCases : request.channels
        var seen: Set<IPCSubscriptionChannel> = []
        return channels.filter { seen.insert($0).inserted }
    }
}
