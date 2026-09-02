// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

enum MonitorSetupSystemSettings {
    static let displaysURLString = "x-apple.systempreferences:com.apple.preference.displays"

    @MainActor
    static func openDisplays() {
        guard let url = URL(string: displaysURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct MonitorSetupGuide: View {
    private enum Step: Int, CaseIterable {
        case macOSArrangement
        case physicalArrangement
        case workspaceHomes
        case mouseWarp

        var title: String {
            switch self {
            case .macOSArrangement: "Arrange Displays in macOS"
            case .physicalArrangement: "Match Your Real Desk"
            case .workspaceHomes: "Give Every Display a Workspace"
            case .mouseWarp: "Make the Pointer Feel Natural"
            }
        }

        var icon: String {
            switch self {
            case .macOSArrangement: "macwindow.on.rectangle"
            case .physicalArrangement: "display.2"
            case .workspaceHomes: "rectangle.3.group"
            case .mouseWarp: "computermouse"
            }
        }
    }

    @Bindable private var settings: SettingsStore
    @Bindable private var controller: WMController
    private let onFinish: () -> Void
    private let onSkip: () -> Void

    @State private var step = Step.macOSArrangement
    @State private var draft: MonitorSetupDraft
    @State private var draftMonitors: [Monitor]
    @State private var liveMonitors: [Monitor]
    @State private var selectedMonitor: Monitor.ID?
    @State private var confirmedMacOSArrangement = false
    @State private var identificationOverlayController: MonitorIdentificationOverlayController
    @AccessibilityFocusState private var headingFocused: Bool

    init(
        settings: SettingsStore,
        controller: WMController,
        monitors: [Monitor],
        onFinish: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        let sortedMonitors = MonitorSettingsTabModel.sortedMonitors(monitors)
        self.settings = settings
        self.controller = controller
        self.onFinish = onFinish
        self.onSkip = onSkip
        _draft = State(initialValue: MonitorSetupDraft(
            monitors: sortedMonitors,
            routingMode: settings.monitorRoutingMode,
            routingSettings: settings.monitorRoutingSettings,
            mouseWarpEnabled: settings.mouseWarpEnabled,
            workspaceConfigurations: settings.workspaceConfigurations
        ))
        _draftMonitors = State(initialValue: sortedMonitors)
        _liveMonitors = State(initialValue: sortedMonitors)
        _selectedMonitor = State(initialValue: sortedMonitors.first?.id)
        _identificationOverlayController = State(initialValue: MonitorIdentificationOverlayController())
    }

    private var draftDisplayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: draftMonitors)
    }

    private var liveDisplayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: liveMonitors)
    }

    private var displayNumbers: [Monitor.ID: Int] {
        Dictionary(uniqueKeysWithValues: draftMonitors.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    private var routingTiles: [RoutingArrangementCanvas.Tile] {
        draftMonitors.compactMap { monitor in
            guard let cell = draft.cell(for: monitor.id) else { return nil }
            return RoutingArrangementCanvas.Tile(
                id: monitor.id,
                column: cell.column,
                row: cell.row,
                displayLabel: draftDisplayLabels[monitor.id],
                fallbackName: monitor.name,
                isMain: monitor.isMain,
                identifierNumber: displayNumbers[monitor.id]
            )
        }
    }

    private var routingRows: [RoutingAccessibleEditor.Row] {
        draftMonitors.map { monitor in
            let number = displayNumbers[monitor.id] ?? 0
            let name = draftDisplayLabels[monitor.id]?.accessibilityName ?? monitor.name
            return RoutingAccessibleEditor.Row(id: monitor.id, name: "Display \(number), \(name)")
        }
    }

    private var routingReadiness: MonitorSetupDraft.Readiness {
        draft.readiness(for: liveMonitors)
    }

    private var uncoveredMonitors: [Monitor] {
        draft.uncoveredMonitors(in: liveMonitors)
    }

    private var hasWorkspaceCoverage: Bool {
        draft.hasWorkspaceCoverage(in: liveMonitors)
    }

    private var canContinue: Bool {
        switch step {
        case .macOSArrangement:
            confirmedMacOSArrangement && liveMonitors.count > 1
        case .physicalArrangement:
            routingReadiness == .ready
        case .workspaceHomes:
            routingReadiness == .ready && hasWorkspaceCoverage
        case .mouseWarp:
            routingReadiness == .ready && hasWorkspaceCoverage
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .padding(28)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(.background)
        .onAppear {
            headingFocused = true
            refreshLiveMonitors()
        }
        .onChange(of: step) { _, _ in
            identificationOverlayController.hide()
            headingFocused = true
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refreshLiveMonitors()
        }
        .onDisappear {
            identificationOverlayController.hide()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(step.title, systemImage: step.icon)
                    .font(.title2.bold())
                    .accessibilityHeading(.h1)
                    .accessibilityFocused($headingFocused)

                Spacer()

                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(Step.allCases.count)
            )
            .accessibilityLabel("Monitor setup progress")
            .accessibilityValue("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var stepContent: some View {
        if routingReadiness == .monitorConfigurationChanged {
            monitorConfigurationChangedContent
        } else {
            switch step {
            case .macOSArrangement:
                macOSArrangementStep
            case .physicalArrangement:
                physicalArrangementStep
            case .workspaceHomes:
                workspaceHomesStep
            case .mouseWarp:
                mouseWarpStep
            }
        }
    }

    private var macOSArrangementStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation(
                title: "First, make a technical staircase",
                text: "This macOS arrangement is intentionally different from your desk. "
                    + "It keeps OmniWM’s hidden windows from appearing on another display."
            )

            MonitorSetupStaircaseIllustration(
                displayCount: max(2, liveMonitors.count),
                animationsEnabled: controller.motionPolicy.animationsEnabled
            )

            MonitorSetupInstructionRow(
                number: 1,
                title: "Put your physically largest or widest display at the bottom",
                detail: "OmniWM cannot measure physical screen size, so choose the display yourself."
            )
            MonitorSetupInstructionRow(
                number: 2,
                title: "Place the next display on its top-right corner",
                detail: "Its bottom-left corner should touch the lower display’s top-right corner."
            )
            MonitorSetupInstructionRow(
                number: 3,
                title: "Continue upward and to the right",
                detail: "For equal-size displays, any order is fine."
            )

            MonitorSetupCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your current macOS arrangement")
                            .font(.headline)
                        Text("This preview updates when you return from Display Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Display Settings", action: MonitorSetupSystemSettings.openDisplays)
                }

                if liveMonitors.isEmpty {
                    ContentUnavailableView(
                        "No Displays Detected",
                        systemImage: "display.trianglebadge.exclamationmark",
                        description: Text("Reconnect your displays, then return to this guide.")
                    )
                    .frame(height: 170)
                } else {
                    MonitorArrangementCanvas(
                        monitors: liveMonitors,
                        displayLabels: liveDisplayLabels,
                        height: 180
                    )
                }

                if let warning = MonitorSetupMacOSAssessment.warning(for: liveMonitors) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Toggle(isOn: $confirmedMacOSArrangement) {
                    Text("I arranged the displays like the staircase above")
                }
                .disabled(liveMonitors.count < 2)
                .accessibilityHint("Confirms the physical size and corner placement that OmniWM cannot verify.")
            }
        }
    }

    private var physicalArrangementStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation(
                title: "Now show OmniWM where the displays really are",
                text: "macOS keeps the technical staircase. In OmniWM, arrange the numbered tiles "
                    + "to match which display is left, right, above, or below on your desk."
            )

            HStack(spacing: 12) {
                MonitorSetupMapLabel(
                    icon: "macwindow",
                    title: "macOS",
                    detail: "Technical staircase"
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MonitorSetupMapLabel(
                    icon: "display.2",
                    title: "OmniWM",
                    detail: "Your real desk"
                )
            }
            .frame(maxWidth: .infinity)

            MonitorSetupCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OmniWM routing arrangement")
                            .font(.headline)
                        Text("Drag tiles, or use the arrow buttons below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Numbers on Screens") {
                        identificationOverlayController.show(
                            monitors: draftMonitors,
                            displayLabels: draftDisplayLabels
                        )
                    }
                    .disabled(routingReadiness == .monitorConfigurationChanged)
                    .accessibilityHint("Briefly shows each tile’s number on its physical display.")
                }

                RoutingArrangementCanvas(
                    tiles: routingTiles,
                    selected: selectedMonitor,
                    onSelect: { selectedMonitor = $0 },
                    onPlace: { monitorID, column, row in
                        draft.place(monitorID, at: .init(column: column, row: row))
                    },
                    height: 230
                )

                RoutingAccessibleEditor(
                    rows: routingRows,
                    onMove: { monitorID, direction in
                        draft.move(monitorID, direction: direction)
                    }
                )

                routingStatus
            }

            Text(
                "A display can be farther away in the grid, but every display must be reachable "
                    + "through a shared row or column. A diagonal tile by itself is disconnected."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var workspaceHomesStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation(
                title: "Make every display a window destination",
                text: "Moving a window to another display requires a workspace there. Assign at least one "
                    + "workspace to every connected display before finishing setup."
            )

            MonitorSetupCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace home monitors")
                        .font(.headline)
                    Text("You can change these later in Workspaces settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(draft.workspaceConfigurations) { configuration in
                        MonitorSetupWorkspaceRow(
                            configuration: configuration,
                            monitorAssignment: monitorAssignmentBinding(for: configuration.id),
                            connectedMonitors: liveMonitors,
                            canRemove: draft.isDraftCreatedWorkspace(configuration.id),
                            onRemove: {
                                draft.removeDraftCreatedWorkspace(configuration.id)
                            }
                        )
                    }
                }
            }

            MonitorSetupCard {
                if hasWorkspaceCoverage {
                    Label("Every display has a workspace", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "Add or reassign a workspace for each display below",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)

                    ForEach(uncoveredMonitors, id: \.id) { monitor in
                        Button {
                            draft.addWorkspace(for: monitor)
                        } label: {
                            Label(
                                "Add Workspace to \(displayName(for: monitor))",
                                systemImage: "plus.circle"
                            )
                        }
                    }
                }
            }
        }
    }

    private var mouseWarpStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            explanation(
                title: "Let the pointer follow your real desk",
                text: "The macOS staircase leaves only corner contact between displays. Mouse Warp uses "
                    + "your OmniWM arrangement to move the pointer across the matching display edge."
            )

            MonitorSetupMouseWarpIllustration(
                animationsEnabled: controller.motionPolicy.animationsEnabled
            )

            MonitorSetupCard {
                Toggle(isOn: $draft.mouseWarpEnabled) {
                    HStack(spacing: 8) {
                        Text("Mouse Warp")
                        MonitorSetupBadge(text: "Recommended")
                    }
                }

                Text(
                    "When the pointer reaches a display edge, OmniWM moves it to the matching edge "
                        + "of the neighboring display."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if !draft.mouseWarpEnabled {
                    Label(
                        "With the macOS staircase, the pointer may not move naturally between displays without Mouse Warp.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            MonitorSetupCard {
                Label("Ready to apply", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                LabeledContent("Routing") {
                    Text("Custom — matches your desk")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Workspace Homes") {
                    Text("Every display covered")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Mouse Warp") {
                    Text(draft.mouseWarpEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                Text("Cursor containment and other advanced options remain available in Monitors settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monitorConfigurationChangedContent: some View {
        ContentUnavailableView {
            Label("Displays Changed", systemImage: "display.trianglebadge.exclamationmark")
        } description: {
            Text("A display was connected or disconnected while setup was open.")
        } actions: {
            Button("Restart with Current Displays", action: restartWithCurrentDisplays)
        }
        .frame(minHeight: 260)
    }

    @ViewBuilder
    private var routingStatus: some View {
        switch routingReadiness {
        case .ready:
            Label("Every display is connected", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .disconnected:
            Label(
                "Move the tiles so every display connects through a left, right, up, or down path.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        case .monitorConfigurationChanged:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip for Now") {
                identificationOverlayController.hide()
                onSkip()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if step != .macOSArrangement {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .macOSArrangement
                }
            }

            if step == .mouseWarp {
                Button("Finish", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            } else {
                Button("Continue") {
                    step = Step(rawValue: step.rawValue + 1) ?? .mouseWarp
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func explanation(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.bold())
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func displayName(for monitor: Monitor) -> String {
        let number = displayNumbers[monitor.id] ?? 0
        let name = draftDisplayLabels[monitor.id]?.accessibilityName ?? monitor.name
        return "Display \(number), \(name)"
    }

    private func monitorAssignmentBinding(
        for workspaceID: WorkspaceConfiguration.ID
    ) -> Binding<MonitorAssignment> {
        Binding(
            get: { draft.monitorAssignment(for: workspaceID) ?? .main },
            set: { draft.setMonitorAssignment($0, for: workspaceID) }
        )
    }

    private func refreshLiveMonitors() {
        let monitors = MonitorSettingsTabModel.sortedMonitors(Monitor.current())
        liveMonitors = monitors
        if draft.readiness(for: monitors) == .monitorConfigurationChanged {
            identificationOverlayController.hide()
        }
    }

    private func restartWithCurrentDisplays() {
        let monitors = liveMonitors
        draftMonitors = monitors
        draft = MonitorSetupDraft(
            monitors: monitors,
            routingMode: settings.monitorRoutingMode,
            routingSettings: settings.monitorRoutingSettings,
            mouseWarpEnabled: draft.mouseWarpEnabled,
            workspaceConfigurations: settings.workspaceConfigurations
        )
        selectedMonitor = monitors.first?.id
        confirmedMacOSArrangement = false
        step = .macOSArrangement
        identificationOverlayController.hide()
    }

    private func finish() {
        guard routingReadiness == .ready,
              hasWorkspaceCoverage,
              let routingSettings = draft.routingSettings(
                  preserving: settings.monitorRoutingSettings,
                  monitors: liveMonitors
              )
        else { return }

        let workspaceConfigurationsChanged = settings.workspaceConfigurations != draft.workspaceConfigurations
        settings.applyMonitorSetup(
            routingSettings: routingSettings,
            mouseWarpEnabled: draft.mouseWarpEnabled,
            workspaceConfigurations: draft.workspaceConfigurations
        )
        if workspaceConfigurationsChanged {
            controller.updateWorkspaceConfig()
        }
        controller.resetMouseWarpTransientState()
        settings.monitorSetupStatus = .completed
        identificationOverlayController.hide()
        onFinish()
    }
}

private struct MonitorSetupWorkspaceRow: View {
    let configuration: WorkspaceConfiguration
    @Binding var monitorAssignment: MonitorAssignment
    let connectedMonitors: [Monitor]
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace \(configuration.name)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if configuration.effectiveDisplayName != configuration.name {
                    Text(configuration.effectiveDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 110, alignment: .leading)

            Spacer(minLength: 12)

            WorkspaceHomeMonitorPicker(
                selection: $monitorAssignment,
                connectedMonitors: connectedMonitors
            )
            .labelsHidden()
            .frame(width: 260)
            .accessibilityLabel("Home monitor for workspace \(configuration.name)")

            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Workspace \(configuration.name)", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove workspace \(configuration.name)")
                .help("Remove this newly added workspace")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct MonitorSetupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.14))
            )
    }
}

private struct MonitorSetupInstructionRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.callout.bold())
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorSetupMapLabel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MonitorSetupBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

private struct MonitorSetupStaircaseIllustration: View {
    let displayCount: Int
    let animationsEnabled: Bool

    @State private var arranged = false
    @State private var replayID = 0

    var body: some View {
        MonitorSetupCard {
            GeometryReader { proxy in
                let transition = MonitorSetupStaircaseGeometry.transition(
                    displayCount: displayCount,
                    in: proxy.size,
                    padding: 8
                )
                let rects = !animationsEnabled || arranged
                    ? transition.staircase
                    : transition.sideBySide

                ZStack(alignment: .topLeading) {
                    ForEach(rects.indices, id: \.self) { index in
                        MonitorSetupExampleDisplay(index: index, count: rects.count)
                            .frame(width: rects[index].width, height: rects[index].height)
                            .position(x: rects[index].midX, y: rects[index].midY)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            .task(id: replayID) {
                guard animationsEnabled else { return }
                arranged = false
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 1.0)) {
                    arranged = true
                }
            }

            HStack {
                Text(
                    "The largest example stays at the bottom; every smaller display continues from the top-right corner."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Replay") {
                    replayID += 1
                }
                .controlSize(.small)
                .disabled(!animationsEnabled)
            }
        }
    }
}

private struct MonitorSetupExampleDisplay: View {
    let index: Int
    let count: Int

    private var color: Color {
        let colors: [Color] = [.accentColor, .indigo, .mint, .orange, .pink, .cyan]
        return colors[index % colors.count]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.75), color.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.35))
            Text(index == 0 ? "Largest" : "\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.6))
                .frame(width: max(10, 30 - CGFloat(index) * 3), height: 2)
                .padding(.top, 4)
        }
    }
}

private struct MonitorSetupMouseWarpIllustration: View {
    let animationsEnabled: Bool

    @State private var warped = false

    var body: some View {
        MonitorSetupCard {
            ZStack(alignment: .topLeading) {
                monitor(x: 20, label: "Display 1")
                monitor(x: 365, label: "Display 2")

                Path { path in
                    path.move(to: CGPoint(x: 305, y: 90))
                    path.addLine(to: CGPoint(x: 375, y: 90))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

                Image(systemName: "cursorarrow")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .shadow(radius: 2)
                    .offset(x: !animationsEnabled || warped ? 370 : 275, y: 70)
                    .animation(
                        animationsEnabled ? .smooth(duration: 0.9) : nil,
                        value: warped
                    )
            }
            .frame(height: 165)
            .accessibilityHidden(true)
            .task {
                guard animationsEnabled else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                warped = true
            }

            Text("At the right edge of Display 1, the pointer appears at the left edge of Display 2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monitor(x: CGFloat, label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.35))
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 285, height: 150)
        .offset(x: x)
    }
}

enum MonitorSetupMacOSAssessment {
    static func warning(for monitors: [Monitor]) -> String? {
        guard monitors.count > 1 else {
            return "Connect at least two displays to continue."
        }
        guard monitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else {
            return "macOS is still updating the display layout. Wait a moment and try again."
        }

        for firstIndex in monitors.indices {
            for secondIndex in monitors.indices where secondIndex > firstIndex {
                let first = monitors[firstIndex].frame
                let second = monitors[secondIndex].frame
                let overlap = first.intersection(second)
                if overlap.width > 1 && overlap.height > 1 {
                    return "Two displays overlap or may be mirrored. Turn off mirroring before continuing."
                }

                let xOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
                let yOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                if xOverlap > 1 || yOverlap > 1 {
                    return "Some displays still share an edge. The recommended staircase touches only at the corners."
                }
            }
        }
        return nil
    }
}
