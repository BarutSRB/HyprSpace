// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

enum WorkspaceBarWindowLevel: String, CaseIterable, Codable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .floating: "Floating"
        case .status: "Status Bar"
        case .popup: "Popup"
        case .screensaver: "Screen Saver"
        }
    }

    var nsWindowLevel: NSWindow.Level {
        switch self {
        case .normal: .normal
        case .floating: .floating
        case .status: .statusBar
        case .popup: .popUpMenu
        case .screensaver: .screenSaver
        }
    }
}

enum WorkspaceBarPosition: String, CaseIterable, Codable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: "Overlapping Menu Bar"
        case .belowMenuBar: "Below Menu Bar"
        }
    }
}

enum WorkspaceBarNotchMode: String, CaseIterable, Codable, Identifiable {
    case off
    case moveBelowMenuBar
    case splitActiveLeft
    case splitActiveRight

    var id: String {
        rawValue
    }

    var isSplit: Bool {
        self == .splitActiveLeft || self == .splitActiveRight
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .moveBelowMenuBar: "Move Below Menu Bar"
        case .splitActiveLeft: "Split — Active Left"
        case .splitActiveRight: "Split — Active Right"
        }
    }
}

@MainActor
final class WorkspaceBarManager {
    struct IslandPanel {
        let panel: WorkspaceBarPanel
        let hostingView: NSHostingView<WorkspaceBarView>
        var slice: WorkspaceBarIslandSlice
        var showsSystemStatsButton: Bool
        var lastAppliedFrame: NSRect?
    }

    struct WorkspaceBarMeasurementKey: Hashable {
        let slice: WorkspaceBarIslandSlice
        let showsSystemStatsButton: Bool
    }

    struct SplitLayoutResult {
        let layout: WorkspaceBarSplitLayout
        let primaryShowsSystemStatsButton: Bool
        let secondaryShowsSystemStatsButton: Bool
    }

    struct ScratchpadCompactionContext: Equatable {
        let availableWidth: CGFloat
        let slice: WorkspaceBarIslandSlice
    }

    final class MonitorBarInstance {
        let monitorId: Monitor.ID
        let measurementView: NSHostingView<WorkspaceBarMeasurementView>
        let model: WorkspaceBarModel

        var primary: IslandPanel
        var secondary: IslandPanel?
        var monitor: Monitor
        var measuredWidths: [WorkspaceBarMeasurementKey: CGFloat] = [:]
        var statsAnchor: CGPoint?
        var screenDisplayId: CGDirectDisplayID?
        var uncompactedSnapshot: WorkspaceBarSnapshot?
        var scratchpadCompactionContext: ScratchpadCompactionContext?
        var compactedScratchpads: [WorkspaceBarScratchpadItem]?

        init(
            monitor: Monitor,
            primary: IslandPanel,
            measurementView: NSHostingView<WorkspaceBarMeasurementView>,
            model: WorkspaceBarModel,
            screenDisplayId: CGDirectDisplayID?
        ) {
            monitorId = monitor.id
            self.monitor = monitor
            self.primary = primary
            self.measurementView = measurementView
            self.model = model
            self.screenDisplayId = screenDisplayId
        }
    }

    var screenProvider: @MainActor (CGDirectDisplayID) -> NSScreen? = { displayId in
        NSScreen.screens.first(where: { $0.displayId == displayId })
    }

    var panelFactory: @MainActor @Sendable () -> WorkspaceBarPanel = {
        WorkspaceBarManager.defaultPanel()
    }

    var frameApplier: @MainActor @Sendable (WorkspaceBarPanel, NSRect) -> Void = { panel, frame in
        panel.setFrame(frame, display: true)
    }

    private var barsByMonitor: [Monitor.ID: MonitorBarInstance] = [:]
    private weak var controller: WMController?
    private weak var settings: SettingsStore?
    private let motionPolicy: MotionPolicy
    private let surfaceCoordinator = SurfaceCoordinator.shared

    init(motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
    }

    func setup(controller: WMController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
    }

    func apply(_ bars: [DesiredBarSurface]) {
        guard controller != nil, settings != nil else { return }

        var staleMonitorIds = Set(barsByMonitor.keys)
        for bar in bars where bar.visible {
            staleMonitorIds.remove(bar.monitor.id)
            if let existing = barsByMonitor[bar.monitor.id] {
                if !updateBarForMonitor(bar.monitor, snapshot: bar.snapshot, instance: existing) {
                    removeBarForMonitor(bar.monitor.id)
                    createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
                }
            } else {
                createBarForMonitor(bar.monitor, snapshot: bar.snapshot)
            }
        }

        for monitorId in staleMonitorIds {
            removeBarForMonitor(monitorId)
        }
    }

    func updateAppearance() {
        guard settings != nil else { return }

        for instance in barsByMonitor.values {
            refreshBarAppearance(instance: instance)
        }
    }

    private func createBarForMonitor(_ monitor: Monitor, snapshot: WorkspaceBarSnapshot) {
        guard let controller, let settings else { return }

        let resolved = settings.resolvedBarSettings(for: monitor)
        let model = WorkspaceBarModel(snapshot: snapshot)
        let measurementView = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot))
        let screen = screenProvider(monitor.displayId)
        let primary = makeIslandPanel(
            slice: .all,
            showsSystemStatsButton: snapshot.showSystemStatsButton,
            monitorId: monitor.id,
            model: model,
            screen: screen,
            resolved: resolved,
            controller: controller
        )

        let instance = MonitorBarInstance(
            monitor: monitor,
            primary: primary,
            measurementView: measurementView,
            model: model,
            screenDisplayId: screen?.displayId
        )
        let preparedSnapshot = scratchpadCompactedSnapshot(
            snapshot,
            monitor: monitor,
            resolved: resolved,
            instance: instance
        )
        model.snapshot = preparedSnapshot
        barsByMonitor[monitor.id] = instance

        applyCurrentAppearance(to: instance)
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: preparedSnapshot,
            instance: instance
        )
        surfaceCoordinator.register(
            window: primary.panel,
            id: surfaceId(for: monitor.id),
            policy: Self.barSurfacePolicy
        )
        primary.panel.orderFrontRegardless()
    }

    private func updateBarForMonitor(
        _ monitor: Monitor,
        snapshot: WorkspaceBarSnapshot,
        instance: MonitorBarInstance
    ) -> Bool {
        guard let settings else { return false }

        let screen = screenProvider(monitor.displayId)
        let nextScreenDisplayId = screen?.displayId

        if let currentScreenDisplayId = instance.screenDisplayId,
           nextScreenDisplayId != currentScreenDisplayId
        {
            return false
        }

        if nextScreenDisplayId == nil, instance.screenDisplayId != nil {
            return false
        }

        instance.monitor = monitor
        instance.screenDisplayId = nextScreenDisplayId
        instance.primary.panel.targetScreen = screen
        instance.secondary?.panel.targetScreen = screen

        let resolved = settings.resolvedBarSettings(for: monitor)
        let preparedSnapshot = scratchpadCompactedSnapshot(
            snapshot,
            monitor: monitor,
            resolved: resolved,
            instance: instance
        )
        if instance.model.snapshot != preparedSnapshot {
            instance.model.snapshot = preparedSnapshot
            instance.measuredWidths = [:]
        }
        applyCurrentAppearance(to: instance)
        applySettingsToPanel(instance.primary.panel, resolved: resolved)
        if let secondary = instance.secondary {
            applySettingsToPanel(secondary.panel, resolved: resolved)
        }
        updateBarFrameAndPosition(
            for: monitor,
            resolved: resolved,
            snapshot: preparedSnapshot,
            instance: instance
        )
        return true
    }

    private func makeIslandPanel(
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID,
        model: WorkspaceBarModel,
        screen: NSScreen?,
        resolved: ResolvedBarSettings,
        controller: WMController
    ) -> IslandPanel {
        let panel = panelFactory()
        panel.targetScreen = screen
        let hostingView = NSHostingView(
            rootView: makeBarView(
                model: model,
                slice: slice,
                showsSystemStatsButton: showsSystemStatsButton,
                monitorId: monitorId,
                controller: controller
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        applySettingsToPanel(panel, resolved: resolved)
        return IslandPanel(
            panel: panel,
            hostingView: hostingView,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            lastAppliedFrame: nil
        )
    }

    private func makeBarView(
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID,
        controller: WMController
    ) -> WorkspaceBarView {
        WorkspaceBarView(
            model: model,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            motionPolicy: motionPolicy,
            onFocusWorkspace: { [weak controller] item in
                controller?.focusWorkspaceFromBar(id: item.id)
            },
            onFocusWindow: { [weak controller] handle in
                controller?.focusWindowFromBar(handle: handle)
            },
            onActivateScratchpad: { [weak controller] index in
                guard let index = ScratchpadIndex(index) else { return }
                controller?.activateScratchpadFromBar(index: index, on: monitorId)
            },
            onToggleSystemStats: { [weak controller] in
                controller?.toggleSystemStatsFromBar(on: monitorId)
            },
            onSystemStatsAnchorChange: { [weak self] anchor in
                self?.updateStatsAnchor(anchor, on: monitorId)
            }
        )
    }

    private func refreshBarAppearance(instance: MonitorBarInstance) {
        guard let settings else { return }

        let resolved = settings.resolvedBarSettings(for: instance.monitor)
        let current = instance.model.snapshot
        let snapshot = WorkspaceBarSnapshot(
            projection: current.projection,
            showLabels: current.showLabels,
            showSystemStatsButton: current.showSystemStatsButton,
            backgroundOpacity: current.backgroundOpacity,
            barHeight: current.barHeight,
            accentColor: resolved.accentColor,
            textColor: resolved.textColor
        )

        if snapshot != current {
            instance.model.snapshot = snapshot
        }
    }

    private func removeBarForMonitor(_ monitorId: Monitor.ID) {
        if let instance = barsByMonitor[monitorId] {
            controller?.dismissSystemStatsPopup(anchoredTo: monitorId)
            removeSecondaryPanel(from: instance)
            surfaceCoordinator.unregister(id: surfaceId(for: monitorId))
            instance.primary.panel.orderOut(nil)
            instance.primary.panel.close()
            barsByMonitor.removeValue(forKey: monitorId)
        }
    }

    func removeAllBars() {
        for monitorId in Array(barsByMonitor.keys) {
            removeBarForMonitor(monitorId)
        }
    }

    private func surfaceId(for monitorId: Monitor.ID) -> String {
        "workspace-bar-\(String(describing: monitorId))"
    }

    private func secondarySurfaceId(for monitorId: Monitor.ID) -> String {
        "workspace-bar-secondary-\(String(describing: monitorId))"
    }

    private func updateBarFrameAndPosition(
        for monitor: Monitor,
        resolved: ResolvedBarSettings,
        snapshot: WorkspaceBarSnapshot,
        instance: MonitorBarInstance
    ) {
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        if let split = splitLayout(
            geometry: geometry,
            snapshot: snapshot,
            monitor: monitor,
            resolved: resolved,
            instance: instance
        ) {
            updateIslandView(
                &instance.primary,
                model: instance.model,
                slice: .active,
                showsSystemStatsButton: split.primaryShowsSystemStatsButton,
                monitorId: instance.monitorId
            )
            applyFrame(split.layout.activeFrame, to: &instance.primary)
            if let secondaryFrame = split.layout.secondaryFrame,
               var secondary = instance.secondary ?? makeSecondaryPanel(
                   for: instance,
                   resolved: resolved,
                   showsSystemStatsButton: split.secondaryShowsSystemStatsButton
               )
            {
                updateIslandView(
                    &secondary,
                    model: instance.model,
                    slice: .secondary,
                    showsSystemStatsButton: split.secondaryShowsSystemStatsButton,
                    monitorId: instance.monitorId
                )
                applyFrame(secondaryFrame, to: &secondary)
                instance.secondary = secondary
            } else {
                removeSecondaryPanel(from: instance)
            }
        } else {
            updateIslandView(
                &instance.primary,
                model: instance.model,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                monitorId: instance.monitorId
            )
            removeSecondaryPanel(from: instance)
            let width = measuredWidth(
                for: snapshot,
                slice: .all,
                showsSystemStatsButton: snapshot.showSystemStatsButton,
                instance: instance
            )
            let frame = geometry.frame(fittingWidth: width, monitor: monitor, resolved: resolved)
            applyFrame(frame, to: &instance.primary)
        }
        if !snapshot.showSystemStatsButton {
            instance.statsAnchor = nil
            controller?.dismissSystemStatsPopup(anchoredTo: instance.monitorId)
        }
    }

    func statsAnchor(on monitorId: Monitor.ID) -> CGPoint? {
        barsByMonitor[monitorId]?.statsAnchor
    }

    func primaryBarFrame(on monitorId: Monitor.ID) -> CGRect? {
        barsByMonitor[monitorId]?.primary.lastAppliedFrame
    }

    func isWorkspaceBarWindow(_ window: NSWindow) -> Bool {
        barsByMonitor.values.contains {
            $0.primary.panel === window || $0.secondary?.panel === window
        }
    }

    private func splitLayout(
        geometry: WorkspaceBarGeometry,
        snapshot: WorkspaceBarSnapshot,
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        instance: MonitorBarInstance
    ) -> SplitLayoutResult? {
        guard resolved.notchMode.isSplit,
              snapshot.items.contains(where: \.isFocused)
        else {
            return nil
        }
        let hasSecondaryContent = !WorkspaceBarIslandSlice.secondary.items(in: snapshot).isEmpty
            || !WorkspaceBarIslandSlice.secondary.scratchpads(in: snapshot).isEmpty
        let activeShowsSystemStatsButton = snapshot.showSystemStatsButton && !hasSecondaryContent
        let secondaryShowsSystemStatsButton = snapshot.showSystemStatsButton && hasSecondaryContent
        guard let layout = geometry.splitFrame(
            activeWidth: measuredWidth(
                for: snapshot,
                slice: .active,
                showsSystemStatsButton: activeShowsSystemStatsButton,
                instance: instance
            ),
            secondaryWidth: hasSecondaryContent
                ? measuredWidth(
                    for: snapshot,
                    slice: .secondary,
                    showsSystemStatsButton: secondaryShowsSystemStatsButton,
                    instance: instance
                )
                : nil,
            monitor: monitor,
            resolved: resolved
        ) else {
            return nil
        }
        return SplitLayoutResult(
            layout: layout,
            primaryShowsSystemStatsButton: activeShowsSystemStatsButton,
            secondaryShowsSystemStatsButton: secondaryShowsSystemStatsButton
        )
    }

    private func updateStatsAnchor(_ anchor: CGPoint?, on monitorId: Monitor.ID) {
        guard let instance = barsByMonitor[monitorId] else { return }
        instance.statsAnchor = anchor
    }

    private func updateIslandView(
        _ island: inout IslandPanel,
        model: WorkspaceBarModel,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        monitorId: Monitor.ID
    ) {
        guard (island.slice != slice || island.showsSystemStatsButton != showsSystemStatsButton),
              let controller
        else {
            return
        }
        island.slice = slice
        island.showsSystemStatsButton = showsSystemStatsButton
        island.hostingView.rootView = makeBarView(
            model: model,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            monitorId: monitorId,
            controller: controller
        )
    }

    private func makeSecondaryPanel(
        for instance: MonitorBarInstance,
        resolved: ResolvedBarSettings,
        showsSystemStatsButton: Bool
    ) -> IslandPanel? {
        guard let controller else { return nil }
        let island = makeIslandPanel(
            slice: .secondary,
            showsSystemStatsButton: showsSystemStatsButton,
            monitorId: instance.monitorId,
            model: instance.model,
            screen: screenProvider(instance.monitor.displayId),
            resolved: resolved,
            controller: controller
        )
        surfaceCoordinator.register(
            window: island.panel,
            id: secondarySurfaceId(for: instance.monitorId),
            policy: Self.barSurfacePolicy
        )
        island.panel.orderFrontRegardless()
        return island
    }

    private func removeSecondaryPanel(from instance: MonitorBarInstance) {
        guard let secondary = instance.secondary else { return }
        surfaceCoordinator.unregister(id: secondarySurfaceId(for: instance.monitorId))
        secondary.panel.orderOut(nil)
        secondary.panel.close()
        instance.secondary = nil
    }

    private func applyFrame(_ frame: NSRect, to island: inout IslandPanel) {
        guard island.lastAppliedFrame != frame else { return }
        frameApplier(island.panel, frame)
        island.lastAppliedFrame = frame
    }

    private func measuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        instance: MonitorBarInstance
    ) -> CGFloat {
        let key = WorkspaceBarMeasurementKey(
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        if let cached = instance.measuredWidths[key] {
            return cached
        }
        instance.measurementView.rootView = WorkspaceBarMeasurementView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        instance.measurementView.layoutSubtreeIfNeeded()
        let width = instance.measurementView.fittingSize.width
        instance.measuredWidths[key] = width
        return width
    }

    private func scratchpadCompactedSnapshot(
        _ snapshot: WorkspaceBarSnapshot,
        monitor: Monitor,
        resolved: ResolvedBarSettings,
        instance: MonitorBarInstance
    ) -> WorkspaceBarSnapshot {
        guard !snapshot.scratchpads.isEmpty else {
            instance.uncompactedSnapshot = snapshot
            instance.scratchpadCompactionContext = nil
            instance.compactedScratchpads = nil
            return snapshot
        }

        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let splitAvailableWidths = geometry.splitAvailableWidths(monitor: monitor, resolved: resolved)
        let usesSplitLayout = resolved.notchMode.isSplit
            && snapshot.items.contains(where: \.isFocused)
            && splitAvailableWidths != nil
        let slice: WorkspaceBarIslandSlice = usesSplitLayout ? .secondary : .all
        let availableWidth = if usesSplitLayout {
            splitAvailableWidths?.secondary ?? monitor.frame.width
        } else {
            monitor.frame.width
        }
        let context = ScratchpadCompactionContext(
            availableWidth: availableWidth,
            slice: slice
        )
        if instance.uncompactedSnapshot == snapshot,
           instance.scratchpadCompactionContext == context,
           let compactedScratchpads = instance.compactedScratchpads
        {
            return snapshot.replacingScratchpads(compactedScratchpads)
        }
        instance.uncompactedSnapshot = snapshot
        instance.scratchpadCompactionContext = context
        let showsSystemStatsButton = snapshot.showSystemStatsButton
        let baseSnapshot = snapshot.replacingScratchpads([])
        let baseWidth = uncachedMeasuredWidth(
            for: baseSnapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton,
            instance: instance
        )
        let hasAdjacentContent = !slice.items(in: baseSnapshot).isEmpty || showsSystemStatsButton
        let scratchpads = WorkspaceBarScratchpadLayout.compactedItems(
            snapshot.scratchpads,
            availableWidth: availableWidth,
            baseWidth: baseWidth,
            barHeight: snapshot.barHeight,
            hasAdjacentContent: hasAdjacentContent
        )
        instance.compactedScratchpads = scratchpads
        return snapshot.replacingScratchpads(scratchpads)
    }

    private func uncachedMeasuredWidth(
        for snapshot: WorkspaceBarSnapshot,
        slice: WorkspaceBarIslandSlice,
        showsSystemStatsButton: Bool,
        instance: MonitorBarInstance
    ) -> CGFloat {
        instance.measurementView.rootView = WorkspaceBarMeasurementView(
            snapshot: snapshot,
            slice: slice,
            showsSystemStatsButton: showsSystemStatsButton
        )
        instance.measurementView.layoutSubtreeIfNeeded()
        return instance.measurementView.fittingSize.width
    }

    private func applyCurrentAppearance(to instance: MonitorBarInstance) {
        let appearance = NSApplication.shared.appearance
        instance.primary.panel.appearance = appearance
        instance.primary.hostingView.appearance = appearance
        instance.secondary?.panel.appearance = appearance
        instance.secondary?.hostingView.appearance = appearance
        instance.measurementView.appearance = appearance
    }

    private static let barSurfacePolicy = SurfacePolicy(
        kind: .workspaceBar,
        hitTestPolicy: .interactive,
        capturePolicy: .included,
        suppressesManagedFocusRecovery: false
    )

    static func defaultPanel() -> WorkspaceBarPanel {
        let panel = WorkspaceBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        return panel
    }

    func cleanup() {
        removeAllBars()
    }

    private func applySettingsToPanel(_ panel: NSPanel, resolved: ResolvedBarSettings) {
        panel.level = resolved.windowLevel.nsWindowLevel
    }
}
