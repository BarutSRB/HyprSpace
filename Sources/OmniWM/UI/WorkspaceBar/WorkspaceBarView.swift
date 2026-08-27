// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Observation
import SwiftUI

struct WorkspaceBarItem: Identifiable, Equatable {
    let id: WorkspaceDescriptor.ID
    let name: String
    let rawName: String
    let isFocused: Bool
    let tiledWindows: [WorkspaceBarWindowItem]
    let floatingWindows: [WorkspaceBarWindowItem]

    var windows: [WorkspaceBarWindowItem] {
        tiledWindows + floatingWindows
    }
}

struct WorkspaceBarProjection: Equatable {
    let items: [WorkspaceBarItem]
    let scratchpads: [WorkspaceBarScratchpadItem]
}

struct WorkspaceBarWindowItem: Identifiable, Equatable, @unchecked Sendable {
    let id: WindowToken
    let handle: WindowHandle
    let windowId: Int
    let appName: String
    let icon: NSImage?
    let isFocused: Bool
    let windowCount: Int
    let hiddenWindowCount: Int
    let allWindows: [WorkspaceBarWindowInfo]

    var isAppHidden: Bool {
        hiddenWindowCount == windowCount
    }

    var hasHiddenWindows: Bool {
        hiddenWindowCount > 0
    }

    static func == (lhs: WorkspaceBarWindowItem, rhs: WorkspaceBarWindowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.handle === rhs.handle
            && lhs.windowId == rhs.windowId
            && lhs.appName == rhs.appName
            && lhs.icon === rhs.icon
            && lhs.isFocused == rhs.isFocused
            && lhs.windowCount == rhs.windowCount
            && lhs.hiddenWindowCount == rhs.hiddenWindowCount
            && lhs.allWindows == rhs.allWindows
    }
}

struct WorkspaceBarWindowInfo: Identifiable, Equatable, @unchecked Sendable {
    let id: WindowToken
    let handle: WindowHandle
    let windowId: Int
    let title: String
    let isFocused: Bool
    let isAppHidden: Bool
}

enum WorkspaceBarScratchpadPresentation: Equatable {
    case expanded
    case compact
}

struct WorkspaceBarScratchpadItem: Identifiable, Equatable {
    let index: Int
    let label: String?
    let windows: [WorkspaceBarWindowItem]
    let isVisible: Bool
    let isRevealed: Bool
    let presentation: WorkspaceBarScratchpadPresentation

    init(
        index: Int,
        label: String?,
        windows: [WorkspaceBarWindowItem],
        isVisible: Bool,
        isRevealed: Bool? = nil,
        presentation: WorkspaceBarScratchpadPresentation = .expanded
    ) {
        self.index = index
        self.label = label
        self.windows = windows
        self.isVisible = isVisible
        self.isRevealed = isRevealed ?? isVisible
        self.presentation = presentation
    }

    var id: Int {
        index
    }

    var name: String {
        label ?? String(index)
    }

    var isFocused: Bool {
        windows.contains(where: \.isFocused)
    }

    var windowCount: Int {
        windows.reduce(0) { $0 + $1.windowCount }
    }

    func presented(as presentation: WorkspaceBarScratchpadPresentation) -> Self {
        Self(
            index: index,
            label: label,
            windows: windows,
            isVisible: isVisible,
            isRevealed: isRevealed,
            presentation: presentation
        )
    }
}

struct WorkspaceBarSnapshot: Equatable {
    let projection: WorkspaceBarProjection
    let showLabels: Bool
    let showSystemStatsButton: Bool
    let backgroundOpacity: Double
    let barHeight: CGFloat
    let accentColor: SettingsColor?
    let textColor: SettingsColor?

    var items: [WorkspaceBarItem] {
        projection.items
    }

    var scratchpads: [WorkspaceBarScratchpadItem] {
        projection.scratchpads
    }

    func replacingScratchpads(_ scratchpads: [WorkspaceBarScratchpadItem]) -> Self {
        Self(
            projection: WorkspaceBarProjection(items: items, scratchpads: scratchpads),
            showLabels: showLabels,
            showSystemStatsButton: showSystemStatsButton,
            backgroundOpacity: backgroundOpacity,
            barHeight: barHeight,
            accentColor: accentColor,
            textColor: textColor
        )
    }
}

enum WorkspaceBarIslandSlice: Hashable {
    case all
    case active
    case secondary

    func items(in snapshot: WorkspaceBarSnapshot) -> [WorkspaceBarItem] {
        switch self {
        case .all: snapshot.items
        case .active: snapshot.items.filter(\.isFocused)
        case .secondary: snapshot.items.filter { !$0.isFocused }
        }
    }

    func scratchpads(in snapshot: WorkspaceBarSnapshot) -> [WorkspaceBarScratchpadItem] {
        self == .active ? [] : snapshot.scratchpads
    }
}

@MainActor @Observable
final class WorkspaceBarModel {
    var snapshot: WorkspaceBarSnapshot

    init(snapshot: WorkspaceBarSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
struct WorkspaceBarView: View {
    let model: WorkspaceBarModel
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    @Bindable var motionPolicy: MotionPolicy
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    var onToggleSystemStats: () -> Void = {}
    var onSystemStatsAnchorChange: (CGPoint?) -> Void = { _ in }

    var body: some View {
        WorkspaceBarContentView(
            snapshot: model.snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: motionPolicy.animationsEnabled,
            onFocusWorkspace: onFocusWorkspace,
            onFocusWindow: onFocusWindow,
            onActivateScratchpad: onActivateScratchpad,
            onToggleSystemStats: onToggleSystemStats,
            onSystemStatsAnchorChange: onSystemStatsAnchorChange
        )
    }
}

@MainActor
struct WorkspaceBarMeasurementView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false

    var body: some View {
        WorkspaceBarContentView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            animationsEnabled: false,
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: { _ in },
            onToggleSystemStats: {},
            onSystemStatsAnchorChange: { _ in }
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor
private struct WorkspaceBarContentView: View {
    let snapshot: WorkspaceBarSnapshot
    var slice: WorkspaceBarIslandSlice = .all
    var showsSystemStatsButton = false
    let animationsEnabled: Bool
    let onFocusWorkspace: (WorkspaceBarItem) -> Void
    let onFocusWindow: (WindowHandle) -> Void
    let onActivateScratchpad: (Int) -> Void
    let onToggleSystemStats: () -> Void
    let onSystemStatsAnchorChange: (CGPoint?) -> Void

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var itemHeight: CGFloat {
        max(16, snapshot.barHeight - 4)
    }

    private var iconSize: CGFloat {
        max(12, itemHeight - 6)
    }

    private let workspaceSpacing: CGFloat = 8
    private let windowSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 6

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(snapshot.backgroundOpacity)
            : Color.black.opacity(snapshot.backgroundOpacity * 0.5)
    }

    private var accentColor: Color? {
        snapshot.accentColor?.swiftUIColor
    }

    private var textColor: Color? {
        snapshot.textColor?.swiftUIColor
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        HStack(spacing: workspaceSpacing) {
            ForEach(slice.items(in: snapshot), id: \.id) { item in
                WorkspaceItemView(
                    item: item,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    windowSpacing: windowSpacing,
                    cornerRadius: cornerRadius,
                    animationsEnabled: animationsEnabled,
                    showLabels: snapshot.showLabels,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: { onFocusWorkspace(item) },
                    onFocusWindow: onFocusWindow
                )
            }

            ForEach(slice.scratchpads(in: snapshot)) { scratchpad in
                ScratchpadPillView(
                    item: scratchpad,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onActivateScratchpad: onActivateScratchpad
                )
            }

            if showsSystemStatsButton {
                SystemStatsButtonView(
                    itemHeight: itemHeight,
                    accentColor: accentColor,
                    textColor: textColor,
                    onToggle: onToggleSystemStats,
                    onAnchorChange: onSystemStatsAnchorChange
                )
            }
        }
        .padding(.horizontal, 4)
        .frame(height: itemHeight + 4)
        .background {
            if accessibilityReduceTransparency {
                barShape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            } else {
                barShape
                    .fill(backgroundColor)
                    .background(.ultraThinMaterial, in: barShape)
            }

            barShape.strokeBorder(
                colorSchemeContrast == .increased
                    ? Color.primary.opacity(0.45)
                    : Color.secondary.opacity(0.18),
                lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
            )
        }
    }
}

@MainActor
private struct WorkspaceItemView: View {
    let item: WorkspaceBarItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let windowSpacing: CGFloat
    let cornerRadius: CGFloat
    let animationsEnabled: Bool
    let showLabels: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void
    let onFocusWindow: (WindowHandle) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: windowSpacing) {
            if showLabels {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )

                if !item.windows.isEmpty {
                    Divider()
                        .frame(height: iconSize)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }
            } else if item.windows.isEmpty {
                WorkspaceLabelButton(
                    item: item,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWorkspace: onFocusWorkspace
                )
            }

            ForEach(item.tiledWindows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: item.isFocused,
                    context: .tiled,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }

            if !item.tiledWindows.isEmpty && !item.floatingWindows.isEmpty {
                Divider()
                    .frame(height: iconSize)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }

            if !item.floatingWindows.isEmpty {
                FloatingWindowsGroupView(
                    windows: item.floatingWindows,
                    iconSize: iconSize,
                    itemHeight: itemHeight,
                    isInFocusedWorkspace: item.isFocused,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: itemHeight)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture(perform: onFocusWorkspace)
        .background {
            if item.isFocused || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay {
                        if item.isFocused {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(accentColor ?? .accentColor, lineWidth: 1)
                        }
                    }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
private struct SystemStatsButtonView: View {
    let itemHeight: CGFloat
    let accentColor: Color?
    let textColor: Color?
    let onToggle: () -> Void
    let onAnchorChange: (CGPoint?) -> Void

    @State private var isHovered = false

    private var buttonSize: CGFloat {
        max(18, itemHeight)
    }

    private var iconColor: Color {
        if isHovered {
            return accentColor ?? .accentColor
        }
        return textColor ?? .secondary
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: max(11, itemHeight * 0.58), weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: buttonSize, height: buttonSize)
                .background {
                    buttonShape
                        .fill(isHovered ? .regularMaterial : .thinMaterial)
                        .overlay {
                            buttonShape.strokeBorder(Color.secondary.opacity(isHovered ? 0.3 : 0.18), lineWidth: 0.75)
                        }
                }
                .contentShape(buttonShape)
                .background(WorkspaceBarAnchorReporter(onChange: onAnchorChange))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("System stats")
        .help("Show system stats")
    }
}

private struct WorkspaceBarAnchorReporter: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.report(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    @MainActor
    final class Coordinator {
        private let onChange: (CGPoint?) -> Void
        private var lastAnchor: CGPoint?

        init(onChange: @escaping (CGPoint?) -> Void) {
            self.onChange = onChange
        }

        func report(_ view: NSView) {
            let anchor: CGPoint?
            if let window = view.window {
                let localFrame = view.convert(view.bounds, to: nil)
                let screenFrame = window.convertToScreen(localFrame)
                anchor = WorkspaceBarGeometry.statsButtonAnchor(buttonFrame: screenFrame)
            } else {
                anchor = nil
            }
            if anchor != lastAnchor {
                lastAnchor = anchor
                onChange(anchor)
            }
        }
    }
}

@MainActor
private struct WorkspaceLabelButton: View {
    let item: WorkspaceBarItem
    let accentColor: Color?
    let textColor: Color?
    let onFocusWorkspace: () -> Void

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedLabelColor: Color {
        textColor ?? (item.isFocused ? resolvedAccentColor : .secondary)
    }

    var body: some View {
        Button(action: onFocusWorkspace) {
            Text(item.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundColor(resolvedLabelColor)
                .lineLimit(1)
                .frame(minWidth: 16)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Workspace \(item.name)")
        .accessibilityValue(item.isFocused ? "Focused" : "")
        .help("Focus workspace \(item.name)")
    }
}

@MainActor
private struct FloatingWindowsGroupView: View {
    let windows: [WorkspaceBarWindowItem]
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let isInFocusedWorkspace: Bool
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: max(10, iconSize * 0.58), weight: .medium))
                .foregroundStyle(resolvedSecondaryTextColor)
                .accessibilityHidden(true)

            ForEach(windows, id: \.id) { window in
                WindowIconView(
                    window: window,
                    iconSize: iconSize,
                    isFocused: window.isFocused,
                    isInFocusedWorkspace: isInFocusedWorkspace,
                    context: .floating,
                    animationsEnabled: animationsEnabled,
                    accentColor: accentColor,
                    textColor: textColor,
                    onFocusWindow: onFocusWindow
                )
            }
        }
        .padding(.horizontal, 5)
        .frame(height: max(16, itemHeight - 2))
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.24), lineWidth: 0.75)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating windows")
    }
}

@MainActor
private struct ScratchpadPillView: View {
    let item: WorkspaceBarScratchpadItem
    let iconSize: CGFloat
    let itemHeight: CGFloat
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onActivateScratchpad: (Int) -> Void

    @State private var isHovered = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    private var isHighlighted: Bool {
        item.isRevealed || item.isFocused
    }

    private var shownWindows: ArraySlice<WorkspaceBarWindowItem> {
        item.windows.prefix(WorkspaceBarScratchpadLayout.maximumVisibleAppIcons)
    }

    private var hiddenAppIconCount: Int {
        max(0, item.windows.count - shownWindows.count)
    }

    var body: some View {
        Button {
            onActivateScratchpad(item.index)
        } label: {
            HStack(spacing: item.presentation == .compact ? 3 : 5) {
                if item.presentation == .expanded {
                    Image(systemName: "tray.fill")
                        .font(.system(size: max(10, iconSize * 0.64), weight: .semibold))
                        .foregroundColor(isHighlighted ? resolvedAccentColor : resolvedSecondaryTextColor)
                        .accessibilityHidden(true)
                }

                Text(item.name)
                    .font(.system(size: max(9, iconSize * 0.6), weight: .medium))
                    .foregroundColor(isHighlighted ? resolvedAccentColor : resolvedSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: item.presentation == .compact
                            ? WorkspaceBarScratchpadLayout.compactLabelMaximumWidth
                            : nil
                    )
                    .accessibilityHidden(true)

                if item.presentation == .compact {
                    WindowCountBadge(
                        count: item.windowCount,
                        iconSize: iconSize,
                        textColor: textColor
                    )
                } else {
                    ForEach(shownWindows) { window in
                        AppIconImage(icon: window.icon)
                            .frame(width: iconSize, height: iconSize)
                            .opacity(window.isFocused ? 1 : 0.82)
                            .accessibilityHidden(true)
                    }

                    if hiddenAppIconCount > 0 {
                        WindowCountBadge(
                            count: hiddenAppIconCount,
                            prefix: "+",
                            iconSize: iconSize,
                            textColor: textColor
                        )
                    }
                }
            }
            .padding(.horizontal, item.presentation == .compact ? 5 : 8)
            .frame(height: itemHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.12) : nil, value: isHovered)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isHighlighted)
        .background {
            Capsule(style: .continuous)
                .fill(isHighlighted ? resolvedAccentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            item.isFocused ? resolvedAccentColor : Color.secondary
                                .opacity(item.isVisible ? 0.36 : 0.22),
                            lineWidth: item.isFocused ? 1.2 : 0.8
                        )
                }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Scratchpad \(item.name)")
        .accessibilityValue(accessibilityValue)
        .help("Scratchpad \(item.name): \(windowSummary), \(item.isVisible ? "visible" : "hidden")")
    }

    private var scale: CGFloat {
        if item.isFocused {
            1.04
        } else if isHovered {
            1.03
        } else {
            1
        }
    }

    private var windowSummary: String {
        item.windowCount == 1
            ? item.windows[0].appName
            : "\(item.windowCount) windows"
    }

    private var accessibilityValue: String {
        var parts = [windowSummary, item.isVisible ? "Visible" : "Hidden"]
        if item.isFocused {
            parts.append("Focused")
        }
        return parts.joined(separator: ", ")
    }
}

enum WorkspaceBarWindowContext {
    case tiled
    case floating

    var label: String {
        switch self {
        case .tiled:
            "window"
        case .floating:
            "floating window"
        }
    }
}

enum WorkspaceBarHiddenIndicatorStyle: Equatable {
    case appHidden
    case partiallyHidden
}

struct WorkspaceBarWindowPresentation {
    let window: WorkspaceBarWindowItem
    let context: WorkspaceBarWindowContext
    let isFocused: Bool
    let isInFocusedWorkspace: Bool

    var hiddenIndicatorStyle: WorkspaceBarHiddenIndicatorStyle? {
        if window.isAppHidden {
            return .appHidden
        }
        if window.hasHiddenWindows {
            return .partiallyHidden
        }
        return nil
    }

    var appliesHiddenTint: Bool {
        window.isAppHidden
    }

    var iconOpacity: Double {
        if window.isAppHidden {
            return 0.9
        }
        if isFocused {
            return 1.0
        }
        if isInFocusedWorkspace {
            return 0.4
        }
        return 0.5
    }

    var accessibilityLabel: String {
        if window.windowCount > 1 {
            return "\(window.appName), \(window.windowCount) \(context.label)s"
        }
        return "\(window.appName) \(context.label)"
    }

    var accessibilityValue: String {
        var values: [String] = []
        if isFocused {
            values.append("Focused")
        }
        if window.isAppHidden {
            values.append(window.windowCount > 1 ? "All \(window.windowCount) windows hidden" : "App hidden")
        } else if window.hasHiddenWindows {
            values.append("\(window.hiddenWindowCount) of \(window.windowCount) windows hidden")
        }
        return values.joined(separator: ", ")
    }

    var accessibilityHint: String {
        if window.windowCount > 1 {
            return "Opens the window list"
        }
        return window.isAppHidden
            ? "Unhides the app and focuses this window"
            : "Focuses this window"
    }

    var help: String {
        if window.windowCount == 1 {
            return window.isAppHidden
                ? "Unhide and focus \(window.appName)"
                : "Focus \(window.appName) window"
        }
        if window.isAppHidden {
            return "Show \(window.appName) windows — app hidden"
        }
        if window.hasHiddenWindows {
            return "Show \(window.appName) windows — \(window.hiddenWindowCount) of \(window.windowCount) hidden"
        }
        return "Show \(window.appName) windows"
    }
}

struct WorkspaceBarWindowListRowPresentation {
    let window: WorkspaceBarWindowInfo

    var accessibilityValue: String {
        var values: [String] = []
        if window.isFocused {
            values.append("Focused")
        }
        if window.isAppHidden {
            values.append("App hidden")
        }
        return values.joined(separator: ", ")
    }

    var accessibilityHint: String {
        window.isAppHidden
            ? "Unhides the app and focuses this window"
            : "Focuses this window"
    }

    var help: String {
        window.isAppHidden
            ? "Unhide and focus \(window.title)"
            : "Focus \(window.title)"
    }
}

@MainActor
private struct WindowIconView: View {
    let window: WorkspaceBarWindowItem
    let iconSize: CGFloat
    let isFocused: Bool
    let isInFocusedWorkspace: Bool
    let context: WorkspaceBarWindowContext
    let animationsEnabled: Bool
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void

    @State private var isHovered = false
    @State private var showingWindowList = false

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    var body: some View {
        let presentation = WorkspaceBarWindowPresentation(
            window: window,
            context: context,
            isFocused: isFocused,
            isInFocusedWorkspace: isInFocusedWorkspace
        )
        Button {
            if window.windowCount > 1 {
                showingWindowList = true
            } else {
                onFocusWindow(window.handle)
            }
        } label: {
            AppIconImage(icon: window.icon)
                .frame(width: iconSize, height: iconSize)
                .overlay {
                    if presentation.appliesHiddenTint {
                        Color(nsColor: .systemRed)
                            .opacity(0.32)
                            .blendMode(.sourceAtop)
                    }
                }
                .opacity(presentation.iconOpacity)
                .shadow(color: resolvedAccentColor.opacity(glowOpacity), radius: glowRadius)
                .accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                    if window.windowCount > 1 {
                        WindowCountBadge(count: window.windowCount, iconSize: iconSize, textColor: textColor)
                            .offset(x: iconSize * 0.2, y: -max(5, iconSize * 0.1))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let hiddenIndicatorStyle = presentation.hiddenIndicatorStyle {
                        WorkspaceBarHiddenIndicator(style: hiddenIndicatorStyle, iconSize: iconSize)
                            .offset(x: iconSize * 0.2, y: max(5, iconSize * 0.1))
                    }
                }
                .frame(minWidth: max(16, iconSize + 4), minHeight: max(16, iconSize + 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(animationsEnabled ? .easeInOut(duration: 0.15) : nil, value: isFocused)
        .animation(animationsEnabled ? .easeInOut(duration: 0.1) : nil, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .sheet(isPresented: $showingWindowList) {
            WindowListSheet(
                windows: window.allWindows,
                appName: window.appName,
                accentColor: accentColor,
                textColor: textColor,
                onFocusWindow: { handle in
                    onFocusWindow(handle)
                    showingWindowList = false
                }
            )
        }
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .help(presentation.help)
    }

    private var scale: CGFloat {
        if isFocused {
            1.1
        } else if isHovered {
            1.05
        } else {
            1.0
        }
    }

    private var glowRadius: CGFloat {
        isFocused ? 4 : 0
    }

    private var glowOpacity: Double {
        isFocused ? 0.5 : 0
    }
}

@MainActor
private struct WorkspaceBarHiddenIndicator: View {
    let style: WorkspaceBarHiddenIndicatorStyle
    let iconSize: CGFloat

    private var badgeSize: CGFloat {
        max(8, iconSize * 0.48)
    }

    var body: some View {
        Group {
            switch style {
            case .appHidden:
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: max(6, iconSize * 0.3), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color(nsColor: .systemRed), in: Circle())
            case .partiallyHidden:
                Image(systemName: "eye.slash")
                    .font(.system(size: max(6, iconSize * 0.3), weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color(nsColor: .systemRed).opacity(0.72), lineWidth: 0.75)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private struct AppIconImage: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

@MainActor
private struct WindowCountBadge: View {
    let count: Int
    var prefix = ""
    let iconSize: CGFloat
    let textColor: Color?

    var body: some View {
        Text("\(prefix)\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundColor(textColor ?? .primary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                    }
            )
            .frame(minWidth: max(12, iconSize * 0.55), minHeight: max(12, iconSize * 0.55))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct WindowListSheet: View {
    let windows: [WorkspaceBarWindowInfo]
    let appName: String
    let accentColor: Color?
    let textColor: Color?
    let onFocusWindow: (WindowHandle) -> Void
    @Environment(\.dismiss) private var dismiss

    private var resolvedAccentColor: Color {
        accentColor ?? .accentColor
    }

    private var resolvedPrimaryTextColor: Color {
        textColor ?? .primary
    }

    private var resolvedSecondaryTextColor: Color {
        textColor ?? .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
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

            List(windows) { windowInfo in
                let presentation = WorkspaceBarWindowListRowPresentation(window: windowInfo)
                Button {
                    onFocusWindow(windowInfo.handle)
                } label: {
                    HStack {
                        Text(windowInfo.title)
                            .foregroundColor(windowInfo
                                .isFocused ? resolvedPrimaryTextColor : resolvedSecondaryTextColor)
                        Spacer()
                        if windowInfo.isFocused {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(resolvedAccentColor)
                        }
                        if windowInfo.isAppHidden {
                            AppHiddenStatusBadge()
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(windowInfo.title)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(presentation.accessibilityHint)
                .help(presentation.help)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}
