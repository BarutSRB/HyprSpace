// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa
import GhosttyKit

enum QuakeTerminalRestoreTarget: Equatable {
    case managed(WindowToken)
    case external(KeyboardFocusTarget)
}

@MainActor
private final class GhosttyAppCallbackContext {
    weak var controller: QuakeTerminalController?

    init(controller: QuakeTerminalController) {
        self.controller = controller
    }
}

@MainActor
final class QuakeTerminalController: NSObject, NSWindowDelegate, QuakeTerminalTabBarDelegate {
    private enum HideBehavior {
        case restoreLatestTarget
        case preserveCurrentFocus
    }

    private(set) var window: QuakeTerminalWindow?
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var retainedAppCallbackContext: Unmanaged<GhosttyAppCallbackContext>?

    private var tabs: [QuakeTerminalTab] = []
    private var activeTabIndex: Int = 0

    private var containerView: NSView?
    private var tabBar: QuakeTerminalTabBar?
    private var glassEffectView: QuakeTerminalGlassView?
    private var ghosttyAppearance: QuakeGhosttyAppearance?

    private var activeTab: QuakeTerminalTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    private var surfaceView: GhosttySurfaceView? {
        activeTab?.focusedSurfaceView
    }

    private(set) var visible: Bool = false
    private var restoreTarget: QuakeTerminalRestoreTarget?
    private var pendingRestoreTarget: QuakeTerminalRestoreTarget?
    private var isHandlingResize: Bool = false
    private var isTransitioning = false
    private var animationGeneration: UInt64 = 0
    private var appearanceObserver: NSKeyValueObservation?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var appliedBackgroundBlurRadius: Int?

    private let settings: SettingsStore
    private let motionPolicy: MotionPolicy
    private let clipboardPrompts = QuakeClipboardPromptCoordinator()
    private let ghosttyConfigBuilder: QuakeGhosttyConfigBuilder
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private let captureRestoreTarget: @MainActor () -> QuakeTerminalRestoreTarget?
    private let restoreFocusTarget: @MainActor (QuakeTerminalRestoreTarget) -> Void
    private let isWindowFocused: @MainActor (NSWindow) -> Bool
    private let focusedWindowScreenProvider: @MainActor () -> NSScreen?

    private static var ghosttyInitialized = false

    init(
        settings: SettingsStore,
        motionPolicy: MotionPolicy,
        captureRestoreTarget: @escaping @MainActor () -> QuakeTerminalRestoreTarget? = { nil },
        restoreFocusTarget: @escaping @MainActor (QuakeTerminalRestoreTarget) -> Void = { _ in },
        isWindowFocused: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
        focusedWindowScreenProvider: @escaping @MainActor () -> NSScreen? = { nil },
        ghosttyConfigBuilder: QuakeGhosttyConfigBuilder = QuakeGhosttyConfigBuilder()
    ) {
        self.settings = settings
        self.motionPolicy = motionPolicy
        self.ghosttyConfigBuilder = ghosttyConfigBuilder
        self.captureRestoreTarget = captureRestoreTarget
        self.restoreFocusTarget = restoreFocusTarget
        self.isWindowFocused = isWindowFocused
        self.focusedWindowScreenProvider = focusedWindowScreenProvider
        super.init()
    }

    isolated deinit {
        cleanup()
    }

    private func initializeGhosttyIfNeeded() {
        guard !Self.ghosttyInitialized else { return }
        let result = ghostty_init(0, nil)
        if result == GHOSTTY_SUCCESS {
            Self.ghosttyInitialized = true
        } else {
            Log.terminal.error("ghostty_init failed with code \(result)")
        }
    }

    func setup() {
        guard ghosttyApp == nil else { return }

        initializeGhosttyIfNeeded()
        guard Self.ghosttyInitialized else {
            Log.terminal.error("GhosttyKit not initialized")
            return
        }

        guard let config = makeGhosttyConfig() else {
            Log.terminal.error("Failed to create ghostty config")
            return
        }
        ghosttyConfig = config
        updateGhosttyAppearance(QuakeGhosttyAppearance(config: config))

        let retainedAppContext = Unmanaged.passRetained(GhosttyAppCallbackContext(controller: self))
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = retainedAppContext.toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let controller = context.controller else { return }
                controller.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            guard let app, let userdata = ghostty_app_userdata(app) else { return false }
            switch action.tag {
            case GHOSTTY_ACTION_CONFIG_CHANGE:
                guard target.tag == GHOSTTY_TARGET_APP,
                      let config = action.action.config_change.config else { return false }
                let appearance = QuakeGhosttyAppearance(config: config)
                return MainActor.assumeIsolated {
                    let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    guard let controller = context.controller else { return false }
                    controller.receiveGhosttyAppearance(appearance)
                    return true
                }
            case GHOSTTY_ACTION_RELOAD_CONFIG:
                guard target.tag == GHOSTTY_TARGET_APP else { return false }
                return MainActor.assumeIsolated {
                    let context = Unmanaged<GhosttyAppCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                    guard let controller = context.controller else { return false }
                    controller.reloadGhosttyConfig(soft: action.action.reload_config.soft)
                    return true
                }
            default:
                return false
            }
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state, mimes, mimesLength, list in
            guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            return MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let controller = context.controller, let view = context.view else {
                    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
                }
                return controller.readClipboard(
                    for: view,
                    location: location,
                    state: state,
                    mimes: mimes,
                    mimesLength: mimesLength,
                    list: list
                )
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, confirmation, state, kind in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = context.view, let surface = view.ghosttySurface else { return }
                guard let controller = context.controller,
                      let confirmation,
                      let promptKind = ClipboardPromptKind(kind)
                else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                controller.promptForProtectedClipboardRead(
                    on: view,
                    payload: GhosttyClipboardPayload(confirmation.pointee),
                    state: state,
                    kind: promptKind
                )
            }
        }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            guard let userdata, let content, len > 0 else { return }
            let contents = (0 ..< len).compactMap { GhosttyClipboardContent(content[$0]) }
            guard !contents.isEmpty else { return }
            MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let controller = context.controller, let view = context.view else { return }
                if confirm {
                    controller.promptForProtectedClipboardWrite(on: view, location: location, contents: contents)
                } else {
                    controller.writeClipboard(location: location, contents: contents)
                }
            }
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let controller = context.controller, let view = context.view else { return }
                controller.surfaceClosed(view: view, processAlive: processAlive)
            }
        }

        ghosttyApp = ghostty_app_new(&runtimeConfig, config)
        guard ghosttyApp != nil else {
            retainedAppContext.release()
            Log.terminal.error("Failed to create ghostty app")
            ghostty_config_free(config)
            ghosttyConfig = nil
            updateGhosttyAppearance(nil)
            return
        }
        retainedAppCallbackContext = retainedAppContext

        startGhosttyAppearanceSync()
        applyCurrentGhosttyColorScheme()
        createWindow()
    }

    func cleanup() {
        stopGhosttyAppearanceSync()
        clipboardPrompts.cancelActivePrompt()
        for tab in tabs {
            for view in tab.splitContainer.allSurfaceViews() {
                view.releaseSurface()
            }
        }
        tabs.removeAll()
        activeTabIndex = 0

        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let retainedAppCallbackContext {
            retainedAppCallbackContext.release()
            self.retainedAppCallbackContext = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
        surfaceCoordinator.unregister(id: surfaceID)
        window?.close()
        window = nil
        appliedBackgroundBlurRadius = nil
        glassEffectView = nil
        ghosttyAppearance = nil
        containerView = nil
        tabBar = nil
        restoreTarget = nil
        pendingRestoreTarget = nil
        visible = false
        isTransitioning = false
        animationGeneration &+= 1
    }

    private func makeGhosttyConfig() -> ghostty_config_t? {
        ghosttyConfigBuilder.build(
            opacity: settings.quakeTerminalOpacity,
            backgroundEffect: settings.quakeTerminalBackgroundEffect
        )
    }

    func reloadOpacityConfig() {
        guard let ghosttyApp else { return }
        guard let newConfig = makeGhosttyConfig() else { return }

        if settings.quakeTerminalBackgroundEffect != .standardBlur {
            applyBackgroundBlurRadius(QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius)
        }
        ghostty_app_update_config(ghosttyApp, newConfig)
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
        }
        ghosttyConfig = newConfig
        applyCurrentGhosttyColorScheme()
    }

    private func reloadGhosttyConfig(soft: Bool) {
        guard let ghosttyApp else { return }
        guard soft, let ghosttyConfig else {
            reloadOpacityConfig()
            return
        }
        ghostty_app_update_config(ghosttyApp, ghosttyConfig)
    }

    func reloadBackgroundBlur() {
        reconcileBackgroundEffect()
    }

    private func receiveGhosttyAppearance(_ appearance: QuakeGhosttyAppearance) {
        guard ghosttyApp != nil else { return }
        updateGhosttyAppearance(appearance, deferred: true)
    }

    private func updateGhosttyAppearance(_ appearance: QuakeGhosttyAppearance?, deferred: Bool = false) {
        guard ghosttyAppearance != appearance else { return }
        ghosttyAppearance = appearance
        if deferred {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileBackgroundEffect()
            }
        } else {
            reconcileBackgroundEffect()
        }
    }

    private func reconcileBackgroundEffect() {
        if let appearance = ghosttyAppearance,
           let glassStyle = appearance.glassStyle,
           let containerView
        {
            let effectView = makeGlassEffectView(in: containerView)
            let style: NSGlassEffectView.Style = switch glassStyle {
            case .regular:
                .regular
            case .clear:
                .clear
            }
            let color = ghosttyBackgroundColor(for: appearance)
            effectView.configure(
                style: style,
                backgroundColor: color,
                backgroundOpacity: appearance.opacity,
                isKeyWindow: window?.isKeyWindow == true
            )
        } else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
        }

        applyBackgroundBlur()
    }

    private func ghosttyBackgroundColor(for appearance: QuakeGhosttyAppearance) -> NSColor {
        guard let backgroundColor = appearance.backgroundColor else {
            return .windowBackgroundColor
        }
        return NSColor(
            srgbRed: CGFloat(backgroundColor.red) / 255,
            green: CGFloat(backgroundColor.green) / 255,
            blue: CGFloat(backgroundColor.blue) / 255,
            alpha: 1
        )
    }

    private func updateGlassKeyStatus(_ isKeyWindow: Bool) {
        guard let ghosttyAppearance else { return }
        glassEffectView?.updateKeyStatus(
            isKeyWindow,
            backgroundColor: ghosttyBackgroundColor(for: ghosttyAppearance)
        )
    }

    private func makeGlassEffectView(in containerView: NSView) -> QuakeTerminalGlassView {
        if let glassEffectView {
            return glassEffectView
        }

        let effectView = QuakeTerminalGlassView(frame: containerView.bounds)
        effectView.autoresizingMask = [.width, .height]
        if let bottomSubview = containerView.subviews.first {
            containerView.addSubview(effectView, positioned: .below, relativeTo: bottomSubview)
        } else {
            containerView.addSubview(effectView)
        }
        glassEffectView = effectView
        return effectView
    }

    private func applyBackgroundBlur() {
        let radius = QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(
            settings.quakeTerminalBackgroundBlurRadius,
            glassEffectActive: ghosttyAppearance?.glassStyle != nil
        )
        applyBackgroundBlurRadius(radius)
    }

    private func applyBackgroundBlurRadius(_ radius: Int) {
        guard let window, window.isVisible else { return }
        let windowNumber = window.windowNumber
        guard windowNumber > 0 else { return }
        guard appliedBackgroundBlurRadius != radius else { return }
        guard SkyLight.shared.setWindowBackgroundBlurRadius(UInt32(windowNumber), radius: radius) else { return }
        appliedBackgroundBlurRadius = radius
    }

    private func startGhosttyAppearanceSync() {
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyCurrentGhosttyColorScheme()
            }
        }
    }

    private func stopGhosttyAppearanceSync() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        appliedColorScheme = nil
    }

    private func applyCurrentGhosttyColorScheme() {
        applyGhosttyColorScheme(for: NSApplication.shared.effectiveAppearance)
    }

    private func applyGhosttyColorScheme(for appearance: NSAppearance) {
        guard let ghosttyApp else { return }
        let scheme = Self.ghosttyColorScheme(for: appearance)
        guard appliedColorScheme != scheme else { return }
        ghostty_app_set_color_scheme(ghosttyApp, scheme)
        appliedColorScheme = scheme
    }

    static func ghosttyColorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func applyGeometryToVisibleWindow() {
        guard let window, visible else { return }
        let screen = targetScreen()

        if let customFrame = customFrameForShow(on: screen) {
            window.setFrame(customFrame, display: true)
            refreshSurfacesForCurrentScreen()
            return
        }

        settings.quakeTerminalPosition.setFinal(
            in: window,
            on: screen,
            widthPercent: settings.quakeTerminalWidthPercent,
            heightPercent: settings.quakeTerminalHeightPercent
        )
        refreshSurfacesForCurrentScreen()
    }

    private func tick() {
        guard let ghosttyApp else { return }
        ghostty_app_tick(ghosttyApp)
    }

    private func createWindow() {
        let win = QuakeTerminalWindow()
        win.delegate = self
        win.tabController = self
        self.window = win
        surfaceCoordinator.register(
            window: win,
            id: surfaceID,
            policy: SurfacePolicy(
                kind: .quake,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            )
        )

        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        self.containerView = container

        let bar = QuakeTerminalTabBar()
        bar.delegate = self
        bar.isHidden = true
        bar.autoresizingMask = [.width]
        bar.frame = NSRect(
            x: 0,
            y: container.bounds.height - QuakeTerminalTabBar.barHeight,
            width: container.bounds.width,
            height: QuakeTerminalTabBar.barHeight
        )
        container.addSubview(bar)
        self.tabBar = bar

        reconcileBackgroundEffect()
    }

    private var surfaceID: String {
        "quake-terminal"
    }

    private func createSurfaceView() -> GhosttySurfaceView? {
        guard let ghosttyApp else { return nil }
        let context = GhosttySurfaceCallbackContext(controller: self)
        let view = GhosttySurfaceView(ghosttyApp: ghosttyApp, callbackContext: context)
        guard view.ghosttySurface != nil else { return nil }
        view.onFrameChanged = { [weak self] frame in
            self?.persistCustomFrame(frame)
        }
        return view
    }

    @discardableResult
    private func createTab() -> QuakeTerminalTab? {
        guard let view = createSurfaceView() else { return nil }

        let splitContainer = QuakeSplitContainer(initialView: view)
        let tab = QuakeTerminalTab(splitContainer: splitContainer)
        tabs.append(tab)
        switchToTab(at: tabs.count - 1)
        return tab
    }

    func splitActivePane(direction: SplitDirection) {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView,
              let newView = createSurfaceView() else { return }
        tab.splitContainer.split(view: focused, direction: direction, newView: newView)
        window?.makeFirstResponder(newView)
    }

    func closeActivePane() {
        guard let tab = activeTab,
              let focused = tab.focusedSurfaceView else { return }

        if tab.splitContainer.root.leafCount() <= 1 {
            closeTab(at: activeTabIndex)
            return
        }

        if tab.splitContainer.remove(view: focused) {
            focused.releaseSurface()
            if let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
        }
    }

    func navigatePane(direction: NavigationDirection) {
        activeTab?.splitContainer.navigate(direction: direction)
    }

    func equalizeSplits() {
        activeTab?.splitContainer.equalize()
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        let tab = tabs[index]
        for view in tab.splitContainer.allSurfaceViews() {
            view.releaseSurface()
        }
        tab.splitContainer.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            updateTabBarVisibility()
            if visible {
                animateOut()
            }
            return
        }

        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        } else if activeTabIndex == index {
            activeTabIndex = min(activeTabIndex, tabs.count - 1)
        }

        switchToTab(at: activeTabIndex)
    }

    func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        if activeTabIndex < tabs.count {
            tabs[activeTabIndex].splitContainer.removeFromSuperview()
        }

        activeTabIndex = index
        let tab = tabs[index]

        guard let containerView else { return }
        let showBar = tabs.count > 1
        let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
        let surfaceFrame = NSRect(
            x: 0, y: 0,
            width: containerView.bounds.width,
            height: containerView.bounds.height - barHeight
        )
        tab.splitContainer.frame = surfaceFrame
        tab.splitContainer.autoresizingMask = [.width, .height]
        containerView.addSubview(tab.splitContainer)

        if let focused = tab.focusedSurfaceView {
            window?.makeFirstResponder(focused)
        }

        updateTabBarVisibility()
        tab.splitContainer.relayout()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        switchToTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        switchToTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    func selectTab(at index: Int) {
        switchToTab(at: index)
    }

    func requestNewTab() {
        createTab()
    }

    func requestCloseActiveTab() {
        guard !tabs.isEmpty else { return }
        closeTab(at: activeTabIndex)
    }

    private func updateTabBarVisibility() {
        guard let tabBar, let containerView else { return }
        let showBar = tabs.count > 1
        tabBar.isHidden = !showBar

        if showBar {
            tabBar.frame = NSRect(
                x: 0,
                y: containerView.bounds.height - QuakeTerminalTabBar.barHeight,
                width: containerView.bounds.width,
                height: QuakeTerminalTabBar.barHeight
            )
            tabBar.update(
                titles: tabs.map { $0.title },
                selectedIndex: activeTabIndex
            )
        }

        if let activeContainer = activeTab?.splitContainer {
            let barHeight = showBar ? QuakeTerminalTabBar.barHeight : 0
            activeContainer.frame = NSRect(
                x: 0, y: 0,
                width: containerView.bounds.width,
                height: containerView.bounds.height - barHeight
            )
            activeContainer.relayout()
        }
    }

    private func createInitialSurface() {
        guard tabs.isEmpty else { return }
        createTab()

        if let window {
            let screen = targetScreen()
            let position = settings.quakeTerminalPosition
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: settings.quakeTerminalWidthPercent,
                heightPercent: settings.quakeTerminalHeightPercent
            )
        }
    }

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window else { return }
        guard !visible else { return }

        restoreTarget = captureRestoreTarget()
        pendingRestoreTarget = nil
        visible = true

        if tabs.isEmpty {
            createInitialSurface()
        }

        animateWindowIn(window: window)
    }

    func animateOut() {
        animateOut(hideBehavior: .restoreLatestTarget)
    }

    private func animateOut(hideBehavior: HideBehavior) {
        guard let window else { return }
        guard visible else { return }

        clipboardPrompts.cancelActivePrompt()
        pendingRestoreTarget = switch hideBehavior {
        case .restoreLatestTarget:
            if isWindowFocused(window) {
                restoreTarget
            } else {
                nil
            }
        case .preserveCurrentFocus:
            nil
        }
        restoreTarget = nil
        visible = false
        animateWindowOut(window: window)
    }

    private func persistCustomFrame(_ frame: NSRect) {
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(frame) else {
            settings.resetQuakeTerminalCustomFrame()
            return
        }

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = customFrame
    }

    private func animateWindowIn(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        let screen = targetScreen()
        let generation = beginAnimationTransition()

        if let customFrame = customFrameForShow(on: screen) {
            window.setFrame(customFrame, display: false)
            window.level = .popUpMenu
            orderFront(window)

            if !motionPolicy.animationsEnabled {
                finishWindowIn(window)
                return
            }

            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation, self.visible else { return }
                    self.finishWindowIn(window)
                }
            })
            return
        }

        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        position.setInitial(
            in: window,
            on: screen,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )

        window.level = .popUpMenu
        orderFront(window)

        if !motionPolicy.animationsEnabled {
            position.setFinal(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishWindowIn(window)
            return
        }

        quakeWindow?.isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setFinal(
                in: window.animator(),
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, self.visible else { return }
                self.finishWindowIn(window)
            }
        })
    }

    private func animateWindowOut(window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        let generation = beginAnimationTransition()

        window.level = .popUpMenu

        if settings.quakeTerminalUseCustomFrame {
            if !motionPolicy.animationsEnabled {
                finishWindowOut(window)
                return
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = settings.quakeTerminalAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.animationGeneration == generation, !self.visible else { return }
                    self.finishWindowOut(window)
                }
            })
            return
        }

        let screen = window.screen ?? targetScreen()
        let position = settings.quakeTerminalPosition
        let widthPercent = settings.quakeTerminalWidthPercent
        let heightPercent = settings.quakeTerminalHeightPercent

        if !motionPolicy.animationsEnabled {
            position.setInitial(
                in: window,
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
            finishWindowOut(window)
            return
        }

        quakeWindow?.isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = settings.quakeTerminalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setInitial(
                in: window.animator(),
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, !self.visible else { return }
                quakeWindow?.isAnimating = false
                self.finishWindowOut(window)
            }
        })
    }

    private func beginAnimationTransition() -> UInt64 {
        animationGeneration &+= 1
        isTransitioning = true
        return animationGeneration
    }

    private func refreshSurfacesForCurrentScreen() {
        guard let container = activeTab?.splitContainer else { return }
        for view in container.allSurfaceViews() {
            view.refreshDisplayStateForCurrentScreen()
        }
    }

    private func finishWindowIn(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        isTransitioning = false
        window.alphaValue = 1
        window.level = .floating
        makeWindowKey(window)
        refreshSurfacesForCurrentScreen()

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, !window.isKeyWindow else { return }
                self.makeWindowKey(window, retries: 10)
            }
        }
    }

    private func finishWindowOut(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        isTransitioning = false
        window.orderOut(nil)
        window.alphaValue = 1

        if let pendingRestoreTarget {
            self.pendingRestoreTarget = nil
            restoreFocusTarget(pendingRestoreTarget)
        }
    }

    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        guard visible else { return }
        orderFront(window)

        if let surfaceView {
            window.makeFirstResponder(surfaceView)
        }

        guard !window.isKeyWindow, retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func orderFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        reconcileBackgroundEffect()
    }

    private func readClipboard(
        for view: GhosttySurfaceView,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLength: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = view.ghosttySurface,
              let pasteboard = NSPasteboard.ghostty(location)
        else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        var contents: [GhosttyClipboardContent] = []
        var seen: Set<String> = []
        if let mimes {
            for index in 0 ..< mimesLength {
                guard let mimePointer = mimes[index] else { continue }
                let mime = String(cString: mimePointer)
                guard seen.insert(mime).inserted,
                      let data = pasteboard.ghosttyData(forMIME: mime) else { continue }
                contents.append(GhosttyClipboardContent(mime: mime, data: data))
            }
        }

        let available = list ? pasteboard.ghosttyAvailableMIMEs() : []
        guard !contents.isEmpty || list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        GhosttyClipboardPayload(contents: contents, available: available)
            .complete(on: surface, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private func promptForProtectedClipboardRead(
        on view: GhosttySurfaceView,
        payload: GhosttyClipboardPayload,
        state: UnsafeMutableRawPointer?,
        kind: ClipboardPromptKind
    ) {
        let request = GhosttyProtectedClipboardRequest(payload: payload, state: state)
        view.registerProtectedClipboardRequest(request)
        presentClipboardPrompt(
            for: view,
            kind: kind,
            contents: payload.preview,
            programName: payload.programName,
            canRemember: payload.canRemember,
            previewImage: payload.previewImage
        ) { [weak view] allowed, remember in
            view?.resolveProtectedClipboardRequest(request, allowing: allowed, remember: remember)
        }
    }

    private func writeClipboard(location: ghostty_clipboard_e, contents: [GhosttyClipboardContent]) {
        NSPasteboard.ghostty(location)?.replaceGhosttyContents(contents)
    }

    private func promptForProtectedClipboardWrite(
        on view: GhosttySurfaceView,
        location: ghostty_clipboard_e,
        contents: [GhosttyClipboardContent]
    ) {
        guard let text = contents.first(where: { $0.mime == "text/plain" })?.string else { return }
        presentClipboardPrompt(
            for: view,
            kind: .write,
            contents: text
        ) { [weak self] allowed, _ in
            guard allowed else { return }
            self?.writeClipboard(location: location, text: text)
        }
    }

    private func writeClipboard(location: ghostty_clipboard_e, text: String) {
        guard let pasteboard = NSPasteboard.ghostty(location) else { return }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    enum ClipboardPromptKind: Equatable {
        case read
        case write
        case unsafePaste

        init?(_ request: ghostty_clipboard_request_e) {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                 GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
                self = .read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
                 GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
                self = .write
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                self = .unsafePaste
            default:
                return nil
            }
        }
    }

    private func presentClipboardPrompt(
        for view: GhosttySurfaceView,
        kind: ClipboardPromptKind,
        contents: String,
        programName: String? = nil,
        canRemember: Bool = false,
        previewImage: NSImage? = nil,
        resolve: @escaping @MainActor (Bool, Bool) -> Void
    ) {
        let alert = Self.protectedClipboardAlert(
            kind: kind,
            contents: contents,
            programName: programName,
            canRemember: canRemember,
            previewImage: previewImage
        )
        let rememberButton = alert.accessoryView as? NSButton
        clipboardPrompts.request(
            origin: view,
            isOriginAttached: { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.canPromptForClipboard(from: view)
            },
            present: { [weak self] completion in
                guard let self, let window = self.window else {
                    completion(false)
                    return
                }
                alert.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated {
                        completion(Self.clipboardPromptResponseAllows(response))
                    }
                }
            },
            dismiss: {
                guard let sheetParent = alert.window.sheetParent else { return }
                sheetParent.endSheet(alert.window, returnCode: .cancel)
            },
            resolve: { allowed in
                resolve(allowed, allowed && rememberButton?.state == .on)
            }
        )
    }

    private func canPromptForClipboard(from view: GhosttySurfaceView) -> Bool {
        guard let window, visible, window.isVisible else { return false }
        return view.ghosttySurface != nil && view.window === window && surfaceView === view
    }

    func cancelClipboardPrompt(for view: GhosttySurfaceView) {
        clipboardPrompts.cancelPrompt(for: view)
    }

    static func protectedClipboardAlert(
        kind: ClipboardPromptKind,
        contents: String,
        programName: String? = nil,
        canRemember: Bool = false,
        previewImage: NSImage? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let requester = programName.map { "\"\($0)\"" } ?? "A terminal application"
        switch kind {
        case .read:
            alert.messageText = "Allow Clipboard Read?"
            alert.informativeText = "\(requester) wants to read the contents of the clipboard."
        case .write:
            alert.messageText = "Allow Clipboard Write?"
            alert.informativeText = "\(requester) wants to replace the contents of the clipboard."
        case .unsafePaste:
            alert.messageText = "Allow Potentially Unsafe Paste?"
            alert.informativeText = "The text being pasted contains characters that may run commands in the terminal."
        }

        let preview = protectedClipboardPreview(contents)
        if !preview.isEmpty {
            alert.informativeText += "\n\n" + preview
        }
        if let previewImage {
            alert.icon = previewImage
        }
        if canRemember {
            alert.accessoryView = NSButton(
                checkboxWithTitle: "Remember this choice for the session",
                target: nil,
                action: nil
            )
        }
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        return alert
    }

    static func clipboardPromptResponseAllows(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }

    private static func protectedClipboardPreview(_ contents: String) -> String {
        let limit = 200
        guard contents.count > limit else { return contents }
        return String(contents.prefix(limit)) + "…"
    }

    private func customFrameForShow(on screen: NSScreen) -> NSRect? {
        guard settings.quakeTerminalUseCustomFrame else { return nil }
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(settings.quakeTerminalCustomFrame)
        else {
            settings.resetQuakeTerminalCustomFrame()
            return nil
        }
        guard QuakeTerminalGeometryPolicy.customFrameFits(customFrame, in: screen.frame) else { return nil }
        return customFrame
    }

    private func targetScreen() -> NSScreen {
        let monitors = Monitor.current()

        switch settings.quakeTerminalMonitorMode {
        case .mouseCursor:
            let mouseLocation = NSEvent.mouseLocation
            if let monitor = mouseLocation.monitorApproximation(in: monitors),
               let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
            {
                return screen
            }

        case .focusedWindow:
            if let screen = focusedWindowScreenProvider() {
                return screen
            }
            if let screen = screenOfFocusedWindow(monitors: monitors) {
                return screen
            }

        case .mainMonitor:
            break
        }

        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func screenOfFocusedWindow(monitors: [Monitor]) -> NSScreen? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        if let displayId = Self.focusedWindowDisplayId(
            monitors: monitors,
            windowList: windowList,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) {
            return NSScreen.screens.first(where: { $0.displayId == displayId })
        }

        return nil
    }

    static func focusedWindowDisplayId(
        monitors: [Monitor],
        windowList: [[String: Any]],
        ownPID: pid_t,
        toAppKitRect: (CGRect) -> CGRect = ScreenCoordinateSpace.toAppKit(rect:)
    ) -> CGDirectDisplayID? {
        for windowInfo in windowList {
            guard let windowPID = int32Value(windowInfo[kCGWindowOwnerPID as String]),
                  windowPID != ownPID,
                  intValue(windowInfo[kCGWindowLayer as String]) == 0,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = cgFloatValue(boundsDict["X"]),
                  let y = cgFloatValue(boundsDict["Y"]),
                  let width = cgFloatValue(boundsDict["Width"]),
                  let height = cgFloatValue(boundsDict["Height"]),
                  x.isFinite,
                  y.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 50,
                  height > 50,
                  width <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints,
                  height <= QuakeTerminalGeometryPolicy.maximumCustomFrameDimensionPoints
            else {
                continue
            }

            let appKitFrame = toAppKitRect(CGRect(x: x, y: y, width: width, height: height))
            if let monitor = appKitFrame.center.monitorApproximation(in: monitors) {
                return monitor.displayId
            }
        }

        return nil
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        case let value as NSNumber:
            return CGFloat(truncating: value)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return Int(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        switch value {
        case let value as Int32:
            return value
        case let value as Int:
            return Int32(exactly: value)
        case let value as Int64:
            return Int32(exactly: value)
        case let value as NSNumber:
            guard let value = exactInt64Value(value) else { return nil }
            return Int32(exactly: value)
        default:
            return nil
        }
    }

    private static func exactInt64Value(_ value: NSNumber) -> Int64? {
        let type = CFNumberGetType(value)
        switch type {
        case .charType,
             .shortType,
             .intType,
             .longType,
             .longLongType,
             .sInt8Type,
             .sInt16Type,
             .sInt32Type,
             .sInt64Type,
             .cfIndexType,
             .nsIntegerType:
            var exact: Int64 = 0
            guard CFNumberGetValue(value, .sInt64Type, &exact) else { return nil }
            return exact
        default:
            var doubleValue = 0.0
            guard CFNumberGetValue(value, .doubleType, &doubleValue),
                  doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  doubleValue >= Double(Int64.min),
                  doubleValue <= Double(Int64.max)
            else {
                return nil
            }
            let exact = Int64(doubleValue)
            guard Double(exact) == doubleValue else { return nil }
            return exact
        }
    }

    private func surfaceClosed(view closedView: GhosttySurfaceView, processAlive: Bool) {
        guard !processAlive else {
            if visible { animateOut() }
            return
        }

        guard let tabIndex = tabs.firstIndex(where: { $0.splitContainer.contains(view: closedView) }) else {
            closedView.releaseSurface()
            return
        }

        let tab = tabs[tabIndex]
        if tab.splitContainer.root.leafCount() <= 1 {
            closeTab(at: tabIndex)
            return
        }

        if tab.splitContainer.remove(view: closedView) {
            closedView.releaseSurface()
            if tabIndex == activeTabIndex, let newFocus = tab.splitContainer.focusedView {
                window?.makeFirstResponder(newFocus)
            }
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow === window else { return }
            updateGlassKeyStatus(notificationWindow.isKeyWindow)
            guard visible else { return }
            guard window?.attachedSheet == nil else { return }

            await Task.yield()
            guard visible else { return }
            restoreTarget = captureRestoreTarget()

            if settings.quakeTerminalAutoHide {
                animateOut(hideBehavior: .preserveCurrentFocus)
            }
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow === window else { return }
            updateGlassKeyStatus(notificationWindow.isKeyWindow)
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow == self.window,
                  visible,
                  !isHandlingResize else { return }
            guard let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }

            isHandlingResize = true
            defer { isHandlingResize = false }

            if surfaceView?.isInteracting != true && !settings.quakeTerminalUseCustomFrame {
                let position = settings.quakeTerminalPosition
                switch position {
                case .top,
                     .bottom,
                     .center:
                    let newOrigin = position.centeredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                case .left,
                     .right:
                    let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                }
            }

            updateTabBarVisibility()
        }
    }

    // MARK: - QuakeTerminalTabBarDelegate

    func tabBarDidSelectTab(at index: Int) {
        switchToTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        createTab()
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }
}
