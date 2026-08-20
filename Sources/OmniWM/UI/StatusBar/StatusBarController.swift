// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    nonisolated static let mainAutosaveName = StatusItemPersistence.OwnedItem.main.autosaveName

    private var statusItem: NSStatusItem?
    private var menuModel: StatusMenuModel?
    private var menu: NSMenu?
    private var menus: [NSMenu] = []

    private let hiddenBarController: HiddenBarController
    private let settings: SettingsStore
    private let cliManager: AppCLIManager?
    private let updateCoordinator: (any AppUpdateCoordinating)?
    private let statusItemDefaults: UserDefaults
    private let recordingPulseKey = "omniwm.recordingPulse"
    private weak var controller: WMController?

    init(
        settings: SettingsStore,
        controller: WMController,
        hiddenBarController: HiddenBarController,
        cliManager: AppCLIManager? = nil,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        statusItemDefaults: UserDefaults = .standard
    ) {
        self.hiddenBarController = hiddenBarController
        self.settings = settings
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator
        self.statusItemDefaults = statusItemDefaults
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    static let maxStatusBarAppNameLength = 15

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        StatusItemPersistence.repairOwnedRestoreState(
            defaults: statusItemDefaults,
            screenFrames: NSScreen.screens.map(\.frame)
        )

        let ownedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        StatusItemPersistence.configureMandatoryItem(ownedStatusItem, as: .main)
        statusItem = ownedStatusItem

        guard let button = statusItem?.button else { return }
        button.image = OmniWMBrandMark.statusItemImage(pointSize: 18)
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityElement(true)

        let model = StatusMenuModel(settings: settings, controller: controller)
        model.ipcMenuEnabled = cliManager != nil
        model.cliManager = cliManager
        model.updateCoordinator = updateCoordinator
        model.checkForUpdatesAction = { [weak self] in
            self?.updateCoordinator?.checkForUpdatesManually()
        }
        menuModel = model
        installHostedMenu(model: model, motionPolicy: controller.motionPolicy)

        hiddenBarController.bind(omniButton: button, statusItem: ownedStatusItem)
        hiddenBarController.onFallbackIconClick = { [weak self] event, anchor in
            self?.routeClick(event: event, anchor: anchor)
        }
        hiddenBarController.setup()
        refreshWorkspaces()
    }

    enum StatusItemClickRoute {
        case hiddenIconsBar
        case menu
    }

    nonisolated static func clickRoute(isRightClick: Bool, optionHeld: Bool) -> StatusItemClickRoute {
        isRightClick || optionHeld ? .hiddenIconsBar : .menu
    }

    @objc private func handleClick(_ button: NSStatusBarButton) {
        if let event = NSApp.currentEvent {
            routeClick(event: event, anchor: button)
        } else {
            hiddenBarController.dismissPanel()
            showMenu(from: button)
        }
    }

    private func routeClick(event: NSEvent, anchor: NSView) {
        switch Self.clickRoute(
            isRightClick: event.type == .rightMouseUp,
            optionHeld: event.modifierFlags.contains(.option)
        ) {
        case .hiddenIconsBar:
            controller?.toggleHiddenBarPanel()
        case .menu:
            hiddenBarController.dismissPanel()
            showMenu(from: anchor)
        }
    }

    private func installHostedMenu(model: StatusMenuModel, motionPolicy: MotionPolicy) {
        let menu = StatusMenuHost.makeMenu()
        let advanced = StatusMenuHost.makeMenu()
        let diagnostics = StatusMenuHost.makeMenu()
        let helpLinks = StatusMenuHost.makeMenu()

        menu.addItem(StatusMenuHost.makeHostedItem(
            dismissing: menu,
            content: StatusMenuPrimaryView(model: model).environment(motionPolicy)
        ))
        advanced.addItem(StatusMenuHost.makeHostedItem(
            dismissing: menu,
            content: StatusMenuAdvancedView(model: model).environment(motionPolicy)
        ))
        diagnostics.addItem(StatusMenuHost.makeHostedItem(
            dismissing: menu,
            content: StatusMenuDiagnosticsView(model: model).environment(motionPolicy)
        ))
        helpLinks.addItem(StatusMenuHost.makeHostedItem(
            dismissing: menu,
            content: StatusMenuHelpLinksView(model: model).environment(motionPolicy)
        ))
        menu.addItem(submenuParent(title: "Advanced", icon: "slider.horizontal.3", submenu: advanced))
        menu.addItem(submenuParent(title: "Diagnostics", icon: "stethoscope", submenu: diagnostics))
        menu.addItem(submenuParent(title: "Help & Links", icon: "questionmark.circle", submenu: helpLinks))
        menu.addItem(StatusMenuHost.makeHostedItem(
            dismissing: menu,
            content: StatusMenuFooterView(model: model).environment(motionPolicy)
        ))

        self.menu = menu
        menus = [menu, advanced, diagnostics, helpLinks]
    }

    private func submenuParent(title: String, icon: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        item.submenu = submenu
        return item
    }

    private func showMenu(from anchor: NSView) {
        guard let menu, let menuModel else { return }
        menuModel.menuWillOpen()
        StatusMenuHost.prepareForDisplay(menus, appearance: NSApplication.shared.appearance)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 5), in: anchor)
        menuModel.menuDidClose()
    }

    func handleTraceCaptureStateChange() {
        updateButtonAppearance()
    }

    func updateButtonAppearance() {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        if controller?.traceCaptureStatus.profile == .problem {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "OmniWM, recording diagnostics"
            )?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.contentTintColor = nil
            button.toolTip = "OmniWM — recording diagnostics (auto-stops in 10 min)"
            applyRecordingPulse(to: button)
        } else if controller?.traceCaptureStatus.profile == .performance {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemBlue])
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "OmniWM, measuring performance"
            )?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.contentTintColor = nil
            button.toolTip = "OmniWM — measuring performance (auto-stops in 10 min)"
        } else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            button.image = OmniWMBrandMark.statusItemImage(pointSize: 18)
            button.contentTintColor = nil
            button.toolTip = nil
        }
        updateButtonAccessibility(button)
    }

    private func applyRecordingPulse(to button: NSStatusBarButton) {
        guard controller?.motionPolicy.animationsEnabled != false else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            return
        }
        guard button.layer?.animation(forKey: recordingPulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: recordingPulseKey)
    }

    static func truncatedStatusBarAppName(_ appName: String) -> String {
        guard appName.count > maxStatusBarAppNameLength else { return appName }
        return String(appName.prefix(maxStatusBarAppNameLength)) + "\u{2026}"
    }

    static func statusButtonTitle(workspaceLabel: String, focusedAppName: String?) -> String {
        var title = " \(workspaceLabel)"
        if let focusedAppName, !focusedAppName.isEmpty {
            title += " \u{2013} \(truncatedStatusBarAppName(focusedAppName))"
        }
        return title
    }

    nonisolated static func statusButtonAccessibilityValue(
        workspaceLabel: String?,
        focusedAppName: String?,
        isRecording: Bool
    ) -> String {
        var components: [String] = []
        if isRecording {
            components.append("Recording diagnostics")
        }
        if let workspaceLabel, !workspaceLabel.isEmpty {
            components.append("Workspace \(workspaceLabel)")
        }
        if let focusedAppName, !focusedAppName.isEmpty {
            components.append("Focused app \(focusedAppName)")
        }
        return components.isEmpty ? "Window manager controls" : components.joined(separator: ", ")
    }

    private func updateButtonAccessibility(_ button: NSStatusBarButton) {
        let summary = settings.statusBarShowWorkspaceName
            ? controller?.activeStatusBarWorkspaceSummary()
            : nil
        let workspaceLabel = summary.map {
            settings.statusBarUseWorkspaceId ? $0.workspaceRawName : $0.workspaceLabel
        }
        let focusedAppName = settings.statusBarShowAppNames ? summary?.focusedAppName : nil
        button.setAccessibilityLabel("OmniWM")
        button.setAccessibilityValue(
            Self.statusButtonAccessibilityValue(
                workspaceLabel: workspaceLabel,
                focusedAppName: focusedAppName,
                isRecording: controller?.isTraceCaptureActive == true
            )
        )
        button.setAccessibilityHelp("Press to open the OmniWM menu.")
    }

    func refreshWorkspaces() {
        guard let button = statusItem?.button else { return }

        updateButtonAppearance()

        guard settings.statusBarShowWorkspaceName,
              let summary = controller?.activeStatusBarWorkspaceSummary()
        else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }

        let workspaceLabel = settings.statusBarUseWorkspaceId ? summary.workspaceRawName : summary.workspaceLabel
        let focusedAppName = settings.statusBarShowAppNames ? summary.focusedAppName : nil
        button.title = Self.statusButtonTitle(workspaceLabel: workspaceLabel, focusedAppName: focusedAppName)
        button.imagePosition = .imageLeft
    }

    func cleanup() {
        cleanupOwnedStatusItems()
    }

    private func cleanupOwnedStatusItems() {
        hiddenBarController.cleanup()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menuModel = nil
        menu = nil
        menus = []
    }
}
