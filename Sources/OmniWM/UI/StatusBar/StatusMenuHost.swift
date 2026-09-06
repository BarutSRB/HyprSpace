// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct StatusMenuDismissAction: Sendable {
    let dismiss: @MainActor () -> Void

    @MainActor
    func callAsFunction(then action: @escaping @MainActor () -> Void) {
        dismiss()
        Task { @MainActor in
            action()
        }
    }
}

extension EnvironmentValues {
    @Entry var statusMenuDismiss = StatusMenuDismissAction(dismiss: {})
}

let statusMenuWidth: CGFloat = 280

@MainActor
final class StatusMenuHost {
    private struct HostedPanel {
        let window: NonactivatingPanel
        let view: NSHostingView<AnyView>
    }

    private static let surfaceId = "status-panel"
    private static let submenuSurfaceId = "status-submenu"

    let presentation = StatusMenuPresentation()
    private let model: StatusMenuModel
    private let motionPolicy: MotionPolicy
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let focusPolicyEngine: FocusPolicyEngine
    private let dismissalMonitor = PanelDismissalMonitor()
    private var root: HostedPanel?
    private var submenu: HostedPanel?
    private var placement: (anchor: CGPoint, visibleFrame: CGRect)?
    private var rowFrames: [StatusMenuPage: CGRect] = [:]
    private var hoverTask: Task<Void, Never>?
    private var hoverCandidate: StatusMenuPage?
    private var scrollObserver: NSObjectProtocol?
    private var rootScrollOrigin = CGPoint.zero
    private(set) var isVisible = false
    var isExemptWindow: (NSWindow) -> Bool = { _ in false }

    var panel: NonactivatingPanel? {
        root?.window
    }

    var submenuPanel: NonactivatingPanel? {
        submenu?.window
    }

    init(model: StatusMenuModel, controller: WMController) {
        self.model = model
        motionPolicy = controller.motionPolicy
        ownedWindowRegistry = controller.ownedWindowRegistry
        focusPolicyEngine = controller.focusPolicyEngine
    }

    func toggle(from anchor: NSView) {
        if isVisible {
            dismiss()
            return
        }
        guard let window = anchor.window, let screen = window.screen else { return }
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        show(anchor: CGPoint(x: anchorFrame.midX, y: anchorFrame.minY), visibleFrame: screen.visibleFrame)
    }

    func show(anchor: CGPoint, visibleFrame: CGRect) {
        guard !isVisible else { return }
        placement = (anchor, visibleFrame)
        presentation.expandedPage = nil
        presentation.rootFocusRequest = nil
        model.menuWillOpen()
        let root = self.root ?? makePanel()
        self.root = root
        isVisible = true
        updateContent(for: .root, in: root)
        register(root.window, surfaceId: Self.surfaceId)
        focusPolicyEngine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)
        root.window.makeKeyAndOrderFront(nil)
        dismissalMonitor.start(
            panels: [root.window],
            isExemptWindow: { [weak self] in self?.isExemptWindow($0) == true },
            onEscape: { [weak self] in self?.handleEscape() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        observeRootScroll()
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        dismissalMonitor.stop()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        closeSubmenu(returnKeyboard: false)
        root?.window.orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        focusPolicyEngine.endLease(owner: .statusPanel)
        placement = nil
        rowFrames.removeAll(keepingCapacity: true)
        model.menuDidClose()
        root?.view.rootView = AnyView(EmptyView())
    }

    func openSubmenu(_ page: StatusMenuPage, enterKeyboard: Bool) {
        cancelHover()
        guard isVisible, page != .root, let root, rowFrames[page] != nil else { return }
        let submenu = self.submenu ?? makePanel()
        self.submenu = submenu
        if presentation.expandedPage == page {
            if enterKeyboard { submenu.window.makeKeyAndOrderFront(nil) }
            return
        }
        presentation.expandedPage = page
        updateContent(for: page, in: submenu)
        register(submenu.window, surfaceId: Self.submenuSurfaceId)
        dismissalMonitor.updatePanels([root.window, submenu.window])
        if enterKeyboard {
            submenu.window.makeKeyAndOrderFront(nil)
        } else {
            submenu.window.orderFront(nil)
        }
    }

    func closeSubmenu(returnKeyboard: Bool = true) {
        cancelHover()
        guard let page = presentation.expandedPage else { return }
        let restoreKeyboard = returnKeyboard && submenu?.window.isKeyWindow == true
        presentation.expandedPage = nil
        submenu?.window.orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.submenuSurfaceId)
        submenu?.view.rootView = AnyView(EmptyView())
        if isVisible, let root {
            dismissalMonitor.updatePanels([root.window])
        }
        if restoreKeyboard, isVisible {
            presentation.rootFocusRequest = page
            presentation.rootFocusGeneration &+= 1
            root?.window.makeKeyAndOrderFront(nil)
        }
    }

    func handleEscape() {
        if presentation.expandedPage != nil {
            closeSubmenu()
        } else {
            dismiss()
        }
    }

    func hoverSubmenu(_ page: StatusMenuPage?, hovered: Bool) {
        if !hovered {
            if hoverCandidate == page { cancelHover() }
            return
        }
        cancelHover()
        guard isVisible, page != presentation.expandedPage else { return }
        hoverCandidate = page
        hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, isVisible else { return }
            if let page {
                openSubmenu(page, enterKeyboard: false)
            } else {
                closeSubmenu(returnKeyboard: false)
            }
        }
    }

    func submenuEntered() {
        cancelHover()
    }

    func updateSubmenuRowFrame(_ page: StatusMenuPage, frame: CGRect) {
        guard isVisible, !frame.isEmpty, rowFrames[page] != frame else { return }
        rowFrames[page] = frame
        if presentation.expandedPage == page, let submenu {
            applyContentSize(submenu.view.frame.size, for: page)
        }
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverCandidate = nil
    }

    nonisolated static func panelSize(contentSize: CGSize, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(statusMenuWidth, max(1, visibleFrame.width - 16)),
            height: min(max(1, ceil(contentSize.height)), max(1, visibleFrame.height - 16))
        )
    }

    nonisolated static func submenuFrame(
        rootFrame: CGRect,
        rowFrame: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let right = rootFrame.maxX + 4
        let left = rootFrame.minX - 4 - size.width
        let x: CGFloat
        if right + size.width <= bounds.maxX {
            x = right
        } else if left >= bounds.minX {
            x = left
        } else {
            x = bounds.maxX - rootFrame.maxX >= rootFrame.minX - bounds.minX ? right : left
        }
        return CGRect(
            x: max(bounds.minX, min(x, bounds.maxX - size.width)),
            y: max(bounds.minY, min(rowFrame.maxY - size.height, bounds.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func makePanel() -> HostedPanel {
        let panel = NonactivatingPanel(
            contentRect: CGRect(x: 0, y: 0, width: statusMenuWidth, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.title = "OmniWM Controls"
        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = [.intrinsicContentSize]
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = hostingView
        panel.contentView = scrollView
        return HostedPanel(window: panel, view: hostingView)
    }

    private func updateContent(for page: StatusMenuPage, in hosted: HostedPanel) {
        hosted.window.appearance = NSApp.appearance
        hosted.view.rootView = AnyView(
            StatusMenuPanelView(
                model: model,
                page: page,
                presentation: presentation,
                onOpenSubmenu: { [weak self] in self?.openSubmenu($0, enterKeyboard: $1) },
                onHoverSubmenu: { [weak self] in self?.hoverSubmenu($0, hovered: $1) },
                onSubmenuRowFrame: { [weak self] in self?.updateSubmenuRowFrame($0, frame: $1) },
                onSubmenuEnter: { [weak self] in self?.submenuEntered() },
                onCloseSubmenu: { [weak self] in self?.closeSubmenu() },
                onContentSizeChange: { [weak self] in self?.applyContentSize($0, for: page) }
            )
            .id(page)
            .environment(motionPolicy)
            .environment(\.statusMenuDismiss, StatusMenuDismissAction(dismiss: { [weak self] in
                self?.dismiss()
            }))
        )
        hosted.view.layoutSubtreeIfNeeded()
        applyContentSize(hosted.view.fittingSize, for: page)
        if let scrollView = hosted.window.contentView as? NSScrollView {
            let top = hosted.view.isFlipped ? 0 : max(0, hosted.view.frame.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func applyContentSize(_ size: CGSize, for page: StatusMenuPage) {
        guard isVisible, let root, let placement else { return }
        let hosted: HostedPanel
        if page == .root {
            hosted = root
        } else {
            guard presentation.expandedPage == page, let submenu else { return }
            hosted = submenu
        }
        let contentSize = CGSize(width: statusMenuWidth, height: max(1, ceil(size.height)))
        if hosted.view.frame.size != contentSize {
            hosted.view.setFrameSize(contentSize)
        }
        let panelSize = Self.panelSize(contentSize: contentSize, visibleFrame: placement.visibleFrame)
        let frame: CGRect
        if page == .root {
            frame = NonactivatingPanel.frame(
                anchor: placement.anchor,
                size: panelSize,
                screenVisibleFrame: placement.visibleFrame
            )
        } else {
            guard var rowFrame = rowFrames[page] else { return }
            if !root.view.isFlipped {
                rowFrame.origin.y = root.view.bounds.height - rowFrame.maxY
            }
            frame = Self.submenuFrame(
                rootFrame: root.window.frame,
                rowFrame: root.window.convertToScreen(root.view.convert(rowFrame, to: nil)),
                size: panelSize,
                visibleFrame: placement.visibleFrame
            )
        }
        if hosted.window.frame != frame {
            hosted.window.setFrame(frame, display: true)
        }
    }

    private func register(_ panel: NSPanel, surfaceId: String) {
        ownedWindowRegistry.register(
            panel,
            surfaceId: surfaceId,
            kind: .statusPanel,
            hitTestPolicy: .interactive,
            capturePolicy: .excluded,
            suppressesManagedFocusRecovery: true
        )
    }

    private func observeRootScroll() {
        guard let scrollView = root?.window.contentView as? NSScrollView else { return }
        let clipView = scrollView.contentView
        rootScrollOrigin = clipView.bounds.origin
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self, weak clipView] _ in
            MainActor.assumeIsolated {
                guard let self, let clipView, self.rootScrollOrigin != clipView.bounds.origin else { return }
                self.rootScrollOrigin = clipView.bounds.origin
                self.closeSubmenu(returnKeyboard: false)
            }
        }
    }
}
