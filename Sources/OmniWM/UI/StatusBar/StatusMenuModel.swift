// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Observation
import SwiftUI

enum StatusMenuControlPreview: Equatable {
    case focusedWindow
    case workspaceBar
    case keepAwake
    case focusMouse
    case focusEdge
    case mouseToFocused
    case followMonitor
    case moveEdge
    case mouseWarp
    case hiddenMenuIcons
}

enum StatusMenuControl: String, CaseIterable, Identifiable {
    case bordersEnabled
    case workspaceBarEnabled
    case preventSleepEnabled
    case focusFollowsMouse
    case focusCrossesMonitorAtEdge
    case moveMouseToFocusedWindow
    case focusFollowsWindowToMonitor
    case moveCrossesMonitorAtEdge
    case mouseWarpEnabled
    case hiddenBarEnabled

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .bordersEnabled:
            "square.dashed"
        case .workspaceBarEnabled:
            "menubar.rectangle"
        case .preventSleepEnabled:
            "moon.zzz"
        case .focusFollowsMouse:
            "cursorarrow.motionlines"
        case .focusCrossesMonitorAtEdge:
            "display.2"
        case .moveMouseToFocusedWindow:
            "arrow.up.left.and.down.right.magnifyingglass"
        case .focusFollowsWindowToMonitor:
            "arrow.right.square"
        case .moveCrossesMonitorAtEdge:
            "macwindow.on.rectangle"
        case .mouseWarpEnabled:
            "arrow.left.arrow.right"
        case .hiddenBarEnabled:
            "eye.slash"
        }
    }

    var label: String {
        switch self {
        case .bordersEnabled:
            "Borders"
        case .workspaceBarEnabled:
            "Workspace Bar"
        case .preventSleepEnabled:
            "Keep Awake"
        case .focusFollowsMouse:
            "Focus Mouse"
        case .focusCrossesMonitorAtEdge:
            "Focus Edge"
        case .moveMouseToFocusedWindow:
            "Mouse to Focused"
        case .focusFollowsWindowToMonitor:
            "Follow Monitor"
        case .moveCrossesMonitorAtEdge:
            "Move Edge"
        case .mouseWarpEnabled:
            "Mouse Warp"
        case .hiddenBarEnabled:
            "Hide Menu Icons"
        }
    }

    var accessibilityName: String {
        switch self {
        case .bordersEnabled:
            "Window Borders"
        case .workspaceBarEnabled:
            "Workspace Bar"
        case .preventSleepEnabled:
            "Keep Awake"
        case .focusFollowsMouse:
            "Focus Follows Mouse"
        case .focusCrossesMonitorAtEdge:
            "Focus Across Monitor at Edge"
        case .moveMouseToFocusedWindow:
            "Mouse to Focused"
        case .focusFollowsWindowToMonitor:
            "Follow Window to Monitor"
        case .moveCrossesMonitorAtEdge:
            "Move Window Across Monitor at Edge"
        case .mouseWarpEnabled:
            "Mouse Warp"
        case .hiddenBarEnabled:
            "Hide Menu Bar Icons"
        }
    }

    var explanation: String {
        switch self {
        case .bordersEnabled:
            "Shows a colored outline around the currently focused managed window. Customize its appearance in Settings."
        case .workspaceBarEnabled:
            "Shows workspaces and their windows in a clickable bar on each display. Per-display overrides can change an individual bar."
        case .preventSleepEnabled:
            "Prevents idle display sleep while your user session is active. Manual sleep and closing the laptop lid still work."
        case .focusFollowsMouse:
            "Focuses a managed window when the pointer enters it—no click needed. Hold Focus Lock to cross windows without changing focus."
        case .focusCrossesMonitorAtEdge:
            "At the last window in any direction, Focus continues left, right, up, or down onto the adjacent display in OmniWM’s Routing Arrangement."
        case .moveMouseToFocusedWindow:
            "Moves the pointer into a window after OmniWM navigation changes focus. It stays put if already inside or the pointer caused the focus."
        case .focusFollowsWindowToMonitor:
            "After moving a window or column to another workspace, switches there and keeps it focused. When off, you stay in the source workspace."
        case .moveCrossesMonitorAtEdge:
            "At a workspace edge, Move Window sends the focused window left, right, up, or down to the adjacent routed display and follows it."
        case .mouseWarpEnabled:
            "Moves the pointer across matching display edges using OmniWM’s Routing Arrangement. Available only with multiple displays."
        case .hiddenBarEnabled:
            "Hides the menu-bar items selected in Settings. Right-click or Option-click OmniWM’s icon to reveal the hidden-icons bar."
        }
    }

    var preview: StatusMenuControlPreview {
        switch self {
        case .bordersEnabled:
            .focusedWindow
        case .workspaceBarEnabled:
            .workspaceBar
        case .preventSleepEnabled:
            .keepAwake
        case .focusFollowsMouse:
            .focusMouse
        case .focusCrossesMonitorAtEdge:
            .focusEdge
        case .moveMouseToFocusedWindow:
            .mouseToFocused
        case .focusFollowsWindowToMonitor:
            .followMonitor
        case .moveCrossesMonitorAtEdge:
            .moveEdge
        case .mouseWarpEnabled:
            .mouseWarp
        case .hiddenBarEnabled:
            .hiddenMenuIcons
        }
    }
}

struct ToggleTileSpec: Identifiable {
    let control: StatusMenuControl
    let isOn: Binding<Bool>

    var id: String {
        control.id
    }
}

@MainActor
@Observable
final class StatusMenuModel {
    let settings: SettingsStore
    private(set) weak var controller: WMController?
    var cliManager: AppCLIManager?
    var updateCoordinator: (any AppUpdateCoordinating)?
    var checkForUpdatesAction: (() -> Void)?
    var ipcMenuEnabled = false
    var infoAlertPresenter: (String, String) -> Void
    var confirmationAlertPresenter: (String, String, String, String) -> Bool
    var settingsFileActionPerformer: (SettingsFileAction, SettingsStore) throws -> SettingsFileStatus
    private(set) var cliStatus: AppCLIExposureStatus?
    private(set) var menuPresentationGeneration = 0

    init(settings: SettingsStore, controller: WMController) {
        self.settings = settings
        self.controller = controller
        infoAlertPresenter = { title, message in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = alert.runModal()
        }
        confirmationAlertPresenter = { title, message, confirmTitle, cancelTitle in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: cancelTitle)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        settingsFileActionPerformer = { action, settings in
            try SettingsFileWorkflow.perform(
                action,
                settings: settings
            )
        }
    }

    var diagnosticsIssues: [DiagnosticsIssue] {
        controller?.diagnosticsIssues ?? []
    }

    var displaySpacesMode: DisplaySpacesMode {
        controller?.displaySpacesMode ?? .enabled
    }

    var isTraceCaptureActive: Bool {
        controller?.isTraceCaptureActive ?? false
    }

    var traceCapturePhase: TraceCapturePhase {
        controller?.traceCaptureStatus.phase ?? .idle
    }

    var traceCaptureProfile: TraceCaptureProfile? {
        controller?.traceCaptureStatus.profile
    }

    var canShowHiddenIcons: Bool {
        settings.hiddenBarEnabled && controller?.isHiddenBarHidingAvailable == true
    }

    func menuWillOpen() {
        menuPresentationGeneration += 1
        controller?.refreshDiagnosticsIssues()
        cliStatus = cliManager?.exposureStatus()
    }

    func menuDidClose() {
        menuPresentationGeneration += 1
    }

    var toggleTiles: [ToggleTileSpec] {
        let settings = settings
        weak let controller = controller
        var tiles: [ToggleTileSpec] = [
            ToggleTileSpec(
                control: .bordersEnabled,
                isOn: Binding(
                    get: { settings.bordersEnabled },
                    set: {
                        settings.bordersEnabled = $0
                        controller?.borderSettingsChanged()
                    }
                )
            ),
            ToggleTileSpec(
                control: .workspaceBarEnabled,
                isOn: Binding(
                    get: { settings.workspaceBarEnabled },
                    set: {
                        settings.workspaceBarEnabled = $0
                        controller?.setWorkspaceBarEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .preventSleepEnabled,
                isOn: Binding(
                    get: { settings.preventSleepEnabled },
                    set: {
                        settings.preventSleepEnabled = $0
                        controller?.setPreventSleepEnabled($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusFollowsMouse,
                isOn: Binding(
                    get: { settings.focusFollowsMouse },
                    set: {
                        settings.focusFollowsMouse = $0
                        controller?.setFocusFollowsMouse($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusCrossesMonitorAtEdge,
                isOn: Binding(
                    get: { settings.focusCrossesMonitorAtEdge },
                    set: { settings.focusCrossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                control: .moveMouseToFocusedWindow,
                isOn: Binding(
                    get: { settings.moveMouseToFocusedWindow },
                    set: {
                        settings.moveMouseToFocusedWindow = $0
                        controller?.setMoveMouseToFocusedWindow($0)
                    }
                )
            ),
            ToggleTileSpec(
                control: .focusFollowsWindowToMonitor,
                isOn: Binding(
                    get: { settings.focusFollowsWindowToMonitor },
                    set: { settings.focusFollowsWindowToMonitor = $0 }
                )
            ),
            ToggleTileSpec(
                control: .moveCrossesMonitorAtEdge,
                isOn: Binding(
                    get: { settings.moveCrossesMonitorAtEdge },
                    set: { settings.moveCrossesMonitorAtEdge = $0 }
                )
            ),
            ToggleTileSpec(
                control: .mouseWarpEnabled,
                isOn: Binding(
                    get: { settings.mouseWarpEnabled },
                    set: { settings.mouseWarpEnabled = $0 }
                )
            )
        ]
        if controller?.isHiddenBarHidingAvailable == true {
            tiles.append(
                ToggleTileSpec(
                    control: .hiddenBarEnabled,
                    isOn: Binding(
                        get: { settings.hiddenBarEnabled },
                        set: { controller?.setHiddenBarEnabled($0) }
                    )
                )
            )
        }
        return tiles
    }

    func openSettings(section: SettingsSection? = nil) {
        guard let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator,
            section: section
        )
    }

    func showHiddenIcons() {
        guard canShowHiddenIcons else { return }
        controller?.toggleHiddenBarPanel()
    }

    func openAppRules() {
        guard let controller else { return }
        AppRulesWindowController.shared.show(settings: settings, controller: controller)
    }

    func openReportIssue() {
        openSettings(section: .reportIssue)
    }

    func checkForUpdates() {
        checkForUpdatesAction?()
    }

    func openSponsors() {
        controller?.openSponsorsWindow()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func toggleTraceRecording(profile: TraceCaptureProfile = .problem) {
        guard let controller else { return }
        let wasRecording = controller.isTraceCaptureActive
        Task {
            switch await controller.toggleTraceCaptureForUI(desiredState: .toggle, profile: profile) {
            case .noChange,
                 .started:
                break
            case let .stopped(artifact):
                NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            case let .writeFailed(reason):
                infoAlertPresenter(
                    wasRecording ? "Recording could not be saved" : "Recording could not be started",
                    reason
                )
            }
        }
    }

    func performSettingsFileAction(_ action: SettingsFileAction) {
        do {
            _ = try settingsFileActionPerformer(
                action,
                settings
            )
        } catch {
            Log.config.error("settings file action failed: \(error.localizedDescription)")
        }
    }

    func installCLI() {
        guard let cliManager else { return }
        let status = cliManager.exposureStatus()
        guard case let .notInstalled(linkURL, directoryOnPath) = status else {
            cliStatus = status
            return
        }

        let directoryURL = linkURL.deletingLastPathComponent()
        var message =
            "OmniWM will create a symlink at \(linkURL.path) pointing to its bundled omniwmctl binary."
        if !directoryOnPath {
            message += "\n\n\(directoryURL.path) is not currently in your PATH, so Terminal may not find `omniwmctl` until you add that directory."
        }

        guard confirmationAlertPresenter(
            "Install CLI to PATH?",
            message,
            "Install",
            "Cancel"
        ) else {
            return
        }

        do {
            let result = try cliManager.installCLIToPATH()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter("CLI Installed", installResultMessage(result))
        } catch {
            infoAlertPresenter("CLI Install Failed", error.localizedDescription)
        }
    }

    func removeCLI() {
        guard let cliManager else { return }
        guard confirmationAlertPresenter(
            "Remove CLI from PATH?",
            "OmniWM will remove the symlink it created for `omniwmctl`.",
            "Remove",
            "Cancel"
        ) else {
            return
        }

        do {
            let result = try cliManager.removeInstalledCLI()
            cliStatus = cliManager.exposureStatus()
            infoAlertPresenter("CLI Link Updated", installResultMessage(result))
        } catch {
            infoAlertPresenter("CLI Removal Failed", error.localizedDescription)
        }
    }

    func installResultMessage(_ result: AppCLIInstallResult) -> String {
        switch result {
        case let .installed(linkURL, directoryOnPath),
             let .alreadyInstalled(linkURL, directoryOnPath):
            let state = directoryOnPath
                ? "You can now run `omniwmctl` from Terminal."
                : "Add \(linkURL.deletingLastPathComponent().path) to PATH before using `omniwmctl` in Terminal."
            return "\(linkURL.path)\n\n\(state)"
        case let .homebrewManaged(linkURL):
            return "Homebrew already manages `omniwmctl` at \(linkURL.path)."
        case let .notInstalled(linkURL):
            return "No OmniWM-managed CLI symlink was found at \(linkURL.path)."
        case let .removed(linkURL):
            return "Removed OmniWM's CLI symlink at \(linkURL.path)."
        }
    }
}
