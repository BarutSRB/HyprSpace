// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let navigation: SettingsNavigationModel

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var isMonitorSetupPresented = false

    private var sortedMonitors: [Monitor] {
        MonitorSettingsTabModel.sortedMonitors(connectedMonitors)
    }

    private var displayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: sortedMonitors)
    }

    private var effectiveSelectedMonitorID: Monitor.ID? {
        MonitorSettingsTabModel.normalizedSelection(selectedMonitor, monitors: sortedMonitors)
    }

    private var selectedConnectedMonitor: Monitor? {
        guard let monitorID = effectiveSelectedMonitorID else { return nil }
        return sortedMonitors.first(where: { $0.id == monitorID })
    }

    private var routingEditorLayout: MonitorSettingsTabModel.RoutingEditorLayout {
        MonitorSettingsTabModel.routingEditorLayout(
            arrangements: settings.monitorArrangements,
            monitors: sortedMonitors
        )
    }

    private var routingTiles: [RoutingArrangementCanvas.Tile] {
        let layout = routingEditorLayout.settings
        return zip(sortedMonitors, layout).map { monitor, entry in
            RoutingArrangementCanvas.Tile(
                id: monitor.id,
                column: entry.gridColumn,
                row: entry.gridRow,
                displayLabel: displayLabels[monitor.id],
                fallbackName: monitor.name,
                isMain: monitor.isMain
            )
        }
    }

    private var routingRows: [RoutingAccessibleEditor.Row] {
        sortedMonitors.map { monitor in
            RoutingAccessibleEditor.Row(
                id: monitor.id,
                name: displayLabels[monitor.id]?.accessibilityName ?? monitor.name
            )
        }
    }

    private var routingNeighborPreview: [(direction: String, name: String)] {
        guard let monitor = selectedConnectedMonitor else { return [] }
        let directions: [(String, Direction)] = [("Left", .left), ("Right", .right), ("Up", .up), ("Down", .down)]
        return directions.map { label, direction in
            let neighbor = routingNeighbor(of: monitor, direction)
            let name = neighbor.flatMap { displayLabels[$0.id]?.name } ?? neighbor?.name ?? "None"
            return (label, name)
        }
    }

    private var routingModeSelection: Binding<MonitorRoutingMode> {
        Binding(
            get: { settings.monitorRoutingMode },
            set: { mode in
                settings.monitorRoutingMode = mode
                guard mode == .custom else { return }
                ensureRoutingSeeded()
            }
        )
    }

    var body: some View {
        SettingsPage(
            subtitle: "macOS controls where windows are placed. OmniWM can use a separate map that matches how "
                + "your displays are actually arranged on your desk."
        ) {
            Section("Guided Setup") {
                HStack(alignment: .center, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(settings.monitorSetupStatus == .completed
                                ? "Multi-monitor setup is complete"
                                : "Set up multiple displays")
                                .fontWeight(.medium)
                            Text(
                                settings.monitorSetupStatus == .completed
                                    ? "Run the guide again after moving, replacing, or adding a display."
                                    : "Follow four guided steps for display placement, workspace homes, and Mouse Warp."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: settings.monitorSetupStatus == .completed
                            ? "checkmark.circle.fill"
                            : "sparkles")
                            .foregroundStyle(
                                settings.monitorSetupStatus == .completed ? Color.green : Color.accentColor
                            )
                    }

                    Spacer()

                    Button("Run Monitor Setup…") {
                        isMonitorSetupPresented = true
                    }
                }
            }

            Section("macOS Arrangement") {
                if sortedMonitors.isEmpty {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                } else {
                    MonitorArrangementCanvas(
                        monitors: sortedMonitors,
                        displayLabels: displayLabels,
                        selected: effectiveSelectedMonitorID,
                        onSelect: { selectedMonitor = $0 }
                    )
                    SettingsCaption(
                        "This is the technical macOS map used for actual window placement. "
                            + "For multiple displays, the setup guide shows how to arrange them as a corner-to-corner staircase."
                    )
                }
            }

            Section("OmniWM Routing Arrangement") {
                Picker("Arrangement", selection: routingModeSelection) {
                    Text("Use macOS Arrangement").tag(MonitorRoutingMode.macOS)
                    Text("Custom Arrangement").tag(MonitorRoutingMode.custom)
                }
                .pickerStyle(.segmented)

                if settings.monitorRoutingMode == .custom {
                    if routingTiles.isEmpty {
                        Text(
                            connectedMonitors.isEmpty ?
                                "No monitors detected." :
                                "Custom routing does not match the connected monitors."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        RoutingArrangementCanvas(
                            tiles: routingTiles,
                            selected: effectiveSelectedMonitorID,
                            onSelect: { selectedMonitor = $0 },
                            onPlace: { placeRouting($0, column: $1, row: $2) }
                        )

                        if !routingNeighborPreview.isEmpty {
                            ForEach(routingNeighborPreview, id: \.direction) { entry in
                                LabeledContent(entry.direction) {
                                    Text(entry.name).foregroundStyle(.secondary)
                                }
                            }
                        }

                        RoutingAccessibleEditor(rows: routingRows, onMove: { moveRouting($0, $1) })
                    }

                    if !sortedMonitors.isEmpty {
                        switch routingEditorLayout.source {
                        case .exact:
                            SettingsCaption(
                                "This arrangement is saved for the connected displays. "
                                    + "Changes update only this arrangement."
                            )
                        case .inherited:
                            SettingsCaption(
                                "Using an arrangement saved with additional displays. "
                                    + "Editing or resetting saves a separate arrangement for the displays connected now."
                            )
                        case .macOS:
                            SettingsCaption(
                                "No valid saved arrangement covers the connected displays. "
                                    + "The macOS arrangement is shown without changing your saved arrangements. "
                                    + "Dragging a monitor or using the arrow controls saves an arrangement for these displays."
                            )
                        }
                    }

                    Button("Reset Custom Arrangement to macOS Layout") { seedFromMacOS() }

                    SettingsCaption(
                        "Make this look like your real desk. Displays in the same row or column can exchange focus, "
                            + "windows, and the pointer. OmniWM remembers an arrangement for each set of connected displays. "
                            + "This does not change where macOS places windows."
                    )
                } else {
                    SettingsCaption(
                        "Routing currently follows the technical macOS map. Run the setup guide to create a separate "
                            + "map that matches your desk."
                    )
                }
            }

            Section("Cross-Monitor Behavior") {
                Toggle("Focus Across Monitor at Edge", isOn: $settings.focusCrossesMonitorAtEdge)
                Toggle("Move Window Across Monitor at Edge", isOn: $settings.moveCrossesMonitorAtEdge)
                Toggle("Follow Window to Monitor", isOn: $settings.focusFollowsWindowToMonitor)
                Toggle(isOn: $settings.mouseWarpEnabled) {
                    HStack(spacing: 8) {
                        Text("Mouse Warp")
                        MonitorBadge(text: "Recommended")
                    }
                }
                Toggle("Constrain Cursor to Arrangement", isOn: $settings.cursorContainmentEnabled)
                    .disabled(!settings.mouseWarpEnabled || settings.monitorRoutingMode != .custom)

                LabeledContent("Mouse Warp Margin") {
                    Stepper(value: $settings.mouseWarpMargin, in: 1 ... 10) {
                        Text("\(settings.mouseWarpMargin) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.mouseWarpEnabled)

                SettingsCaption(
                    "Mouse Warp moves the pointer across matching display edges using the OmniWM routing arrangement. "
                        + "It is recommended when the macOS displays touch only at their corners."
                )
            }

            Section("Monitor Orientation") {
                if let monitor = selectedConnectedMonitor,
                   let displayLabel = displayLabels[monitor.id]
                {
                    SelectedMonitorDetails(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        displayLabel: displayLabel
                    )
                } else {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            refreshConnectedMonitors()
            presentRequestedMonitorSetupIfNeeded()
        }
        .onChange(of: navigation.hasPendingMonitorSetupPresentation) { _, pending in
            guard pending else { return }
            presentRequestedMonitorSetupIfNeeded()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refreshConnectedMonitors()
        }
        .sheet(isPresented: $isMonitorSetupPresented) {
            MonitorSetupGuide(
                settings: settings,
                controller: controller,
                monitors: sortedMonitors,
                onFinish: { isMonitorSetupPresented = false },
                onSkip: { isMonitorSetupPresented = false }
            )
        }
    }

    private func presentRequestedMonitorSetupIfNeeded() {
        guard navigation.consumeMonitorSetupPresentationRequest() else { return }
        isMonitorSetupPresented = true
    }

    private func refreshConnectedMonitors() {
        let monitors = Monitor.current()
        connectedMonitors = monitors
        selectedMonitor = MonitorSettingsTabModel.normalizedSelection(
            selectedMonitor,
            monitors: MonitorSettingsTabModel.sortedMonitors(monitors)
        )
    }

    private func routingNeighbor(of monitor: Monitor, _ direction: Direction) -> Monitor? {
        switch MonitorRouting.gridAdjacent(
            from: monitor,
            direction: direction,
            layout: routingEditorLayout.settings,
            monitors: sortedMonitors,
            wrapAround: false
        ) {
        case let .monitor(neighbor): neighbor
        case .edge,
             .fallBackToMacOS: nil
        }
    }

    private func ensureRoutingSeeded() {
        guard settings.monitorRoutingMode == .custom else { return }
        guard MonitorSettingsTabModel.shouldSeedRouting(
            arrangements: settings.monitorArrangements,
            monitors: connectedMonitors
        ) else { return }
        seedFromMacOS()
    }

    private func seedFromMacOS() {
        settings.storeRoutingLayout(MonitorRouting.seedLayout(from: connectedMonitors), for: connectedMonitors)
    }

    private func placeRouting(_ monitorID: Monitor.ID, column: Int, row: Int) {
        let monitors = sortedMonitors
        let layout = routingEditorLayout.settings
        var cells: [Monitor.ID: MonitorSetupDraft.Cell] = [:]
        for (monitor, entry) in zip(monitors, layout) {
            cells[monitor.id] = .init(column: entry.gridColumn, row: entry.gridRow)
        }
        MonitorRoutingGridEditor.place(
            monitorID,
            at: .init(column: column, row: row),
            cells: &cells
        )
        let updated = MonitorSettingsTabModel.routingSettingsAfterEdit(
            monitors: monitors,
            cells: cells.mapValues { (column: $0.column, row: $0.row) }
        )
        settings.storeRoutingLayout(updated, for: monitors)
    }

    private func moveRouting(_ monitorID: Monitor.ID, _ direction: Direction) {
        let monitors = sortedMonitors
        let layout = routingEditorLayout.settings
        guard let index = monitors.firstIndex(where: { $0.id == monitorID }),
              layout.indices.contains(index)
        else { return }
        let entry = layout[index]
        var column = entry.gridColumn
        var row = entry.gridRow
        switch direction {
        case .left: column -= 1
        case .right: column += 1
        case .up: row -= 1
        case .down: row += 1
        }
        placeRouting(monitorID, column: column, row: row)
    }
}

private struct MonitorBadgeRow: View {
    let displayLabel: MonitorDisplayLabel
    let isMain: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let duplicateBadge = displayLabel.badgeText {
                MonitorBadge(text: duplicateBadge)
            }

            if isMain {
                MonitorBadge(text: "Main")
            }
        }
    }
}

private struct MonitorBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct SelectedMonitorDetails: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel

    private var orientationOverride: Monitor.Orientation? {
        settings.orientationSettings(for: monitor)?.orientation
    }

    private var effectiveOrientation: Monitor.Orientation {
        settings.effectiveOrientation(for: monitor)
    }

    var body: some View {
        LabeledContent("Monitor") {
            HStack(spacing: 8) {
                Text(displayLabel.name)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)

                MonitorBadgeRow(displayLabel: displayLabel, isMain: monitor.isMain)
            }
        }

        LabeledContent("Auto-detected") {
            Text(monitor.autoOrientation.displayName)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Current") {
            Text(effectiveOrientation.displayName)
                .fontWeight(.medium)
        }

        Picker("Orientation Override", selection: Binding(
            get: { orientationOverride },
            set: { newValue in
                updateOrientation(newValue)
            }
        )) {
            Text("Auto").tag(nil as Monitor.Orientation?)
            Text("Horizontal").tag(Monitor.Orientation.horizontal as Monitor.Orientation?)
            Text("Vertical").tag(Monitor.Orientation.vertical as Monitor.Orientation?)
        }
        .pickerStyle(.segmented)

        if orientationOverride != nil {
            Button("Reset to Auto") {
                updateOrientation(nil)
            }
        }

        SettingsCaption(
            "Vertical monitors scroll windows top-to-bottom instead of left-to-right."
        )
    }

    private func updateOrientation(_ orientation: Monitor.Orientation?) {
        let newSettings = MonitorOrientationSettings(
            monitorName: monitor.name,
            orientation: orientation
        )

        if orientation == nil {
            settings.removeOrientationSettings(for: monitor)
        } else {
            settings.updateOrientationSettings(newSettings, for: monitor)
        }

        controller.updateMonitorOrientations()
    }
}

struct MonitorDisplayLabel: Equatable {
    let name: String
    let duplicateIndex: Int?

    var badgeText: String? {
        duplicateIndex.map { "#\($0)" }
    }

    var accessibilityName: String {
        if let duplicateIndex {
            return "\(name), duplicate \(duplicateIndex)"
        }
        return name
    }
}

enum MonitorSettingsTabModel {
    struct RoutingEditorLayout {
        enum Source: Equatable {
            case exact
            case inherited
            case macOS
        }

        let settings: [MonitorRoutingSettings]
        let source: Source

        var usesMacOSFallback: Bool {
            source == .macOS && !settings.isEmpty
        }
    }

    static func routingEditorLayout(
        arrangements: [MonitorArrangement],
        monitors: [Monitor]
    ) -> RoutingEditorLayout {
        if let index = MonitorRouting.arrangementIndex(for: monitors, in: arrangements),
           let completeLayout = MonitorRouting.completeLayout(arrangements[index].monitors, for: monitors)
        {
            return RoutingEditorLayout(
                settings: completeLayout,
                source: arrangements[index].monitors.count == monitors.count ? .exact : .inherited
            )
        }

        return RoutingEditorLayout(
            settings: MonitorRouting.seedLayout(from: monitors),
            source: .macOS
        )
    }

    static func routingSettingsAfterEdit(
        monitors: [Monitor],
        cells: [Monitor.ID: (column: Int, row: Int)]
    ) -> [MonitorRoutingSettings] {
        monitors.compactMap { monitor in
            guard let cell = cells[monitor.id] else { return nil }
            return MonitorRoutingSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: monitor.displayUUID,
                monitorDisplayId: monitor.displayId,
                gridColumn: cell.column,
                gridRow: cell.row
            )
        }
    }

    static func shouldSeedRouting(
        arrangements: [MonitorArrangement],
        monitors: [Monitor]
    ) -> Bool {
        !monitors.isEmpty && MonitorRouting.arrangementIndex(for: monitors, in: arrangements) == nil
    }

    static func sortedMonitors(_ monitors: [Monitor]) -> [Monitor] {
        Monitor.sortedByPosition(monitors)
    }

    static func normalizedSelection(_ selectedMonitor: Monitor.ID?, monitors: [Monitor]) -> Monitor.ID? {
        guard !monitors.isEmpty else { return nil }

        if let selectedMonitor,
           monitors.contains(where: { $0.id == selectedMonitor })
        {
            return selectedMonitor
        }

        return monitors.first?.id
    }

    static func displayLabels(for monitors: [Monitor]) -> [Monitor.ID: MonitorDisplayLabel] {
        let sorted = sortedMonitors(monitors)
        let totals = sorted.reduce(into: [String: Int]()) { counts, monitor in
            counts[monitor.name, default: 0] += 1
        }
        var nextIndexByName: [String: Int] = [:]
        var labels: [Monitor.ID: MonitorDisplayLabel] = [:]

        for monitor in sorted {
            nextIndexByName[monitor.name, default: 0] += 1
            let total = totals[monitor.name, default: 0]
            let duplicateIndex = total > 1 ? nextIndexByName[monitor.name] : nil
            labels[monitor.id] = MonitorDisplayLabel(name: monitor.name, duplicateIndex: duplicateIndex)
        }

        return labels
    }
}

extension Monitor.Orientation {
    var displayName: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }
}
