import AppKit
import Common
import SwiftUI

// CENTERED BAR FEATURE
@MainActor
struct CenteredBarView: View {
    @ObservedObject var viewModel: TrayMenuModel
    let barHeight: CGFloat
    let monitor: Monitor? // nil for single-bar mode, specific monitor for per-monitor mode
    @Environment(\.colorScheme) var colorScheme: ColorScheme

    // Derived sizing from bar height
    private var itemHeight: CGFloat { max(16, barHeight - 4) }
    private var iconSize: CGFloat { max(12, itemHeight - 6) }
    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
    }

    private var activeBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1)
    }

    private var borderColor: Color {
        // Accent color: lavender
        Color(red: 196 / 255.0, green: 167 / 255.0, blue: 231 / 255.0)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(viewModel.centeredBarWorkspaces(for: monitor), id: \.workspace.name) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    backgroundColor: backgroundColor,
                    activeBackgroundColor: activeBackgroundColor,
                    borderColor: borderColor,
                )
            }
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: CenteredBarWorkspaceItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let backgroundColor: Color
    let activeBackgroundColor: Color
    let borderColor: Color

    @State private var isHovered = false

    private var shouldShowModeIndicator: Bool {
        guard CenteredBarSettings.shared.showModeIndicator else { return false }
        guard let mode = activeMode, mode != mainModeId else { return false }
        return true
    }

    private var workspaceDisplayText: String {
        // If we should show mode indicator
        if shouldShowModeIndicator, let mode = activeMode, mode != mainModeId {
            let modeInitial = mode.first.map { String($0).uppercased() } ?? ""
            if CenteredBarSettings.shared.showNumbers {
                // Show both mode and workspace name: "[W] 1"
                return "[\(modeInitial)] \(item.workspace.name)"
            } else {
                // Show only mode initial: "W"
                return modeInitial
            }
        }
        // Normal display: just workspace name
        return item.workspace.name
    }

    var body: some View {
        HStack(spacing: windowSpacing) {
            // Workspace identifier with optional mode indicator
            if CenteredBarSettings.shared.showNumbers || shouldShowModeIndicator {
                Text(workspaceDisplayText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(item.isFocused ? borderColor : .secondary)
                    .frame(minWidth: 16)

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
                        .padding(.horizontal, 2)
                }
            }

            // Window icons
            ForEach(item.windows, id: \.windowId) { window in
                WindowIconView(
                    window: window,
                    workspace: item.workspace,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(item.isFocused ? activeBackgroundColor : (isHovered ? backgroundColor : Color.clear)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(item.isFocused ? borderColor : Color.clear, lineWidth: 1),
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            focusWorkspace(item.workspace)
        }
    }

    private func focusWorkspace(_ workspace: Workspace) {
        Task {
            if let token: RunSessionGuard = .isServerEnabled {
                try await runSession(.menuBarButton, token) {
                    _ = workspace.focusWorkspace()
                }
            }
        }
    }
}

@MainActor
private struct WindowIconView: View {
    let window: CenteredBarWindowItem
    let workspace: Workspace
    let iconSize: CGFloat
    let isFocused: Bool
    let isInFocusedWorkspace: Bool

    @State private var isHovered = false
    @State private var showingWindowList = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .opacity(opacity)

            // Badge showing window count when > 1
            if window.windowCount > 1 {
                Text("\(window.windowCount)")
                    .font(.system(size: max(8, iconSize * 0.4), weight: .bold))
                    .foregroundColor(.white)
                    .padding(2)
                    .background(
                        Circle()
                            .fill(Color.red),
                    )
                    .offset(x: iconSize * 0.2, y: -iconSize * 0.1)
            }
        }
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                focusWindow()
            }
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                workspace: workspace,
                appName: window.appName ?? "Unknown App",
            )
        }
        .help(window.appName ?? "Unknown App")
    }

    private var opacity: Double {
        if isFocused {
            return 1.0
        } else if isInFocusedWorkspace {
            return 0.6
        } else {
            return 0.8
        }
    }

    private func focusWindow() {
        Task {
            if let token: RunSessionGuard = .isServerEnabled {
                try await runSession(.menuBarButton, token) {
                    // First focus the workspace
                    _ = workspace.focusWorkspace()
                    // Then focus the specific window
                    if let window = Window.get(byId: window.windowId) {
                        window.nativeFocus()
                    }
                }
            }
        }
    }
}

// Sheet for selecting individual windows when deduplicated
@MainActor
private struct WindowListSheet: View {
    let windows: [WindowInfo]
    let workspace: Workspace
    let appName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(appName)
                    .font(.headline)
                    .padding()
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Window list
            List(windows) { windowInfo in
                Button {
                    focusSpecificWindow(windowInfo.windowId)
                    dismiss()
                } label: {
                    HStack {
                        Text(windowInfo.title)
                            .foregroundColor(windowInfo.isFocused ? .primary : .secondary)
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    private func focusSpecificWindow(_ windowId: UInt32) {
        Task {
            if let token: RunSessionGuard = .isServerEnabled {
                try await runSession(.menuBarButton, token) {
                    // First focus the workspace
                    _ = workspace.focusWorkspace()
                    // Then focus the specific window
                    if let window = Window.get(byId: windowId) {
                        window.nativeFocus()
                    }
                }
            }
        }
    }
}

// Data models for the centered bar
struct CenteredBarWorkspaceItem {
    let workspace: Workspace
    let isFocused: Bool
    let windows: [CenteredBarWindowItem]
}

struct CenteredBarWindowItem {
    let windowId: UInt32
    let appName: String?
    let icon: NSImage?
    let isFocused: Bool
    let windowCount: Int // Number of windows for this app (for badge)
    let allWindows: [WindowInfo] // All windows of this app (for popout)
}

struct WindowInfo: Identifiable {
    let id: UInt32 // windowId
    let windowId: UInt32
    let title: String
    let isFocused: Bool
}

// Extension to prepare data for centered bar
@MainActor
extension TrayMenuModel {
    func centeredBarWorkspaces(for monitor: Monitor? = nil) -> [CenteredBarWorkspaceItem] {
        let focus = focus
        let allWorkspaces = Workspace.all.sorted()
        let dedupeEnabled = CenteredBarSettings.shared.deduplicateAppIcons
        let hideEmptyWorkspaces = CenteredBarSettings.shared.hideEmptyWorkspaces

        // Filter workspaces by monitor if specified
        var filteredWorkspaces: [Workspace] = if let monitor {
            // Per-monitor mode: show workspaces assigned to this monitor
            // workspaceMonitor already handles fallback to mainMonitor for unassigned workspaces
            allWorkspaces.filter { workspace in
                workspace.workspaceMonitor.rect.topLeftCorner == monitor.rect.topLeftCorner
            }
        } else {
            // Single-bar mode: show all workspaces
            allWorkspaces
        }

        // Filter empty workspaces if enabled
        if hideEmptyWorkspaces {
            filteredWorkspaces = filteredWorkspaces.filter { !$0.allLeafWindowsRecursive.isEmpty }
        }

        return filteredWorkspaces.map { workspace in
            processWorkspace(workspace, focus: focus, dedupeEnabled: dedupeEnabled)
        }
    }

    private func processWorkspace(_ workspace: Workspace, focus: LiveFocus, dedupeEnabled: Bool) -> CenteredBarWorkspaceItem {
        let allWindows = workspace.allLeafWindowsRecursive
        let windows: [CenteredBarWindowItem] = if dedupeEnabled {
            createDedupedWindowItems(allWindows: allWindows, focus: focus)
        } else {
            createIndividualWindowItems(allWindows: allWindows, focus: focus)
        }

        return CenteredBarWorkspaceItem(
            workspace: workspace,
            isFocused: workspace == focus.workspace,
            windows: windows,
        )
    }

    private func createDedupedWindowItems(allWindows: [Window], focus: LiveFocus) -> [CenteredBarWindowItem] {
        let groupedByApp = Dictionary(grouping: allWindows) { window in
            window.app.name ?? "Unknown"
        }

        let items = groupedByApp.map { (appName: String, windowsInApp: [Window]) -> CenteredBarWindowItem in
            createDedupedItem(appName: appName, windowsInApp: windowsInApp, focus: focus)
        }

        return items.sorted { ($0.appName ?? "") < ($1.appName ?? "") }
    }

    private func createDedupedItem(appName: String, windowsInApp: [Window], focus: LiveFocus) -> CenteredBarWindowItem {
        let firstWindow = windowsInApp.first!
        let icon = getIcon(for: firstWindow)
        let anyFocused = windowsInApp.contains { $0 == focus.windowOrNil }
        let windowInfos = windowsInApp.map { createWindowInfo($0, focus: focus) }

        return CenteredBarWindowItem(
            windowId: firstWindow.windowId,
            appName: appName,
            icon: icon,
            isFocused: anyFocused,
            windowCount: windowsInApp.count,
            allWindows: windowInfos,
        )
    }

    private func createIndividualWindowItems(allWindows: [Window], focus: LiveFocus) -> [CenteredBarWindowItem] {
        return allWindows.map { window in
            let icon = getIcon(for: window)
            let windowInfo = createWindowInfo(window, focus: focus)

            return CenteredBarWindowItem(
                windowId: window.windowId,
                appName: window.app.name,
                icon: icon,
                isFocused: window == focus.windowOrNil,
                windowCount: 1,
                allWindows: [windowInfo],
            )
        }
    }

    private func getIcon(for window: Window) -> NSImage? {
        if let macWindow = window as? MacWindow {
            return macWindow.macApp.nsApp.icon
        }
        return nil
    }

    private func createWindowInfo(_ window: Window, focus: LiveFocus) -> WindowInfo {
        // Use app name as title since window.title is async
        let titleText = window.app.name ?? "Untitled"
        return WindowInfo(
            id: window.windowId,
            windowId: window.windowId,
            title: titleText,
            isFocused: window == focus.windowOrNil,
        )
    }
}
