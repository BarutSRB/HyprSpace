// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class StatusMenuPanelTests: XCTestCase {
    func testContentIsCappedToScreenAndAnchoredAtEdges() {
        let screen = CGRect(x: -1280, y: 100, width: 1280, height: 700)
        let size = StatusMenuHost.panelSize(
            contentSize: CGSize(width: 280, height: 1200),
            visibleFrame: screen
        )
        let frame = NonactivatingPanel.frame(
            anchor: CGPoint(x: screen.maxX, y: screen.maxY),
            size: size,
            screenVisibleFrame: screen
        )

        XCTAssertEqual(size, CGSize(width: 280, height: 684))
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.maxX, screen.maxX - 8)
    }

    func testSubmenuOpensRightWhenSpaceIsAvailable() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let root = CGRect(x: 100, y: 300, width: 280, height: 600)
        let row = CGRect(x: root.minX, y: 620, width: root.width, height: 30)
        let frame = StatusMenuHost.submenuFrame(
            rootFrame: root,
            rowFrame: row,
            size: CGSize(width: 280, height: 300),
            visibleFrame: screen
        )

        XCTAssertGreaterThan(frame.minX, root.maxX)
        XCTAssertEqual(frame.maxY, row.maxY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testSubmenuOpensLeftAtRightScreenEdge() {
        let screen = CGRect(x: -1280, y: 100, width: 1280, height: 900)
        let root = CGRect(x: screen.maxX - 288, y: 350, width: 280, height: 600)
        let row = CGRect(x: root.minX, y: 650, width: root.width, height: 30)
        let frame = StatusMenuHost.submenuFrame(
            rootFrame: root,
            rowFrame: row,
            size: CGSize(width: 280, height: 300),
            visibleFrame: screen
        )

        XCTAssertLessThan(frame.maxX, root.minX)
        XCTAssertEqual(frame.maxY, row.maxY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testSubmenuClampsToScreenWithoutMovingRoot() {
        let screen = CGRect(x: 0, y: 100, width: 500, height: 500)
        let root = CGRect(x: 200, y: 108, width: 280, height: 484)
        let frame = StatusMenuHost.submenuFrame(
            rootFrame: root,
            rowFrame: CGRect(x: root.minX, y: 120, width: root.width, height: 30),
            size: CGSize(width: 280, height: 400),
            visibleFrame: screen
        )

        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.minY, screen.minY + 8)
    }

    func testBothPanelsSurviveKeyLossAndDismissalReleasesOnlyTheirLease() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.controller.focusPolicyEngine.beginLease(owner: .nativeMenu, reason: "menu_anywhere", duration: nil)
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.openSubmenu(.advanced, enterKeyboard: true)
        let root = try XCTUnwrap(fixture.host.panel)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)

        for panel in [root, submenu] {
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertEqual(panel.level, .popUpMenu)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertGreaterThan(panel.frame.height, 40)
            XCTAssertTrue(fixture.controller.ownedWindowRegistry.contains(windowNumber: panel.windowNumber))
            XCTAssertFalse(fixture.controller.ownedWindowRegistry.isCaptureEligible(windowNumber: panel.windowNumber))
            panel.resignKey()
        }
        XCTAssertFalse(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        XCTAssertTrue(fixture.host.isVisible)
        XCTAssertTrue(root.isVisible)
        XCTAssertTrue(submenu.isVisible)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)
        fixture.host.dismiss()
        fixture.host.dismiss()

        for panel in [root, submenu] {
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(fixture.controller.ownedWindowRegistry.contains(windowNumber: panel.windowNumber))
        }
        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertTrue(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
        XCTAssertFalse(fixture.controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange)
        XCTAssertEqual(fixture.controller.focusPolicyEngine.activeLease?.owner, .nativeMenu)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 2)
    }

    func testBranchesReuseSubmenuWithoutChangingRootFrameDocumentOrScroll() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show(visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 400))
        let root = try XCTUnwrap(fixture.host.panel)
        let scrollView = try XCTUnwrap(root.contentView as? NSScrollView)
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(document.frame.height, scrollView.contentSize.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 40))
        fixture.seedSubmenuRows()
        let rootFrame = root.frame
        let scrollOrigin = scrollView.contentView.bounds.origin
        fixture.host.openSubmenu(.advanced, enterKeyboard: false)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)

        for page: StatusMenuPage in [.diagnostics, .help, .advanced] {
            fixture.host.openSubmenu(page, enterKeyboard: false)
            XCTAssertTrue(fixture.host.panel === root)
            XCTAssertTrue(fixture.host.submenuPanel === submenu)
            XCTAssertTrue(scrollView.documentView === document)
            XCTAssertEqual(root.frame, rootFrame)
            XCTAssertEqual(scrollView.contentView.bounds.origin, scrollOrigin)
            XCTAssertEqual(fixture.host.presentation.expandedPage, page)
            XCTAssertTrue(root.isVisible)
            XCTAssertTrue(submenu.isVisible)
        }
        fixture.host.closeSubmenu(returnKeyboard: false)

        XCTAssertTrue(root.isVisible)
        XCTAssertFalse(submenu.isVisible)
        XCTAssertEqual(root.frame, rootFrame)
        XCTAssertEqual(scrollView.contentView.bounds.origin, scrollOrigin)
        XCTAssertTrue(fixture.controller.ownedWindowRegistry.contains(windowNumber: root.windowNumber))
        XCTAssertFalse(fixture.controller.ownedWindowRegistry.contains(windowNumber: submenu.windowNumber))
        XCTAssertFalse(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)
        fixture.host.dismiss()
        fixture.show()

        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertTrue(fixture.host.panel === root)
        XCTAssertFalse(submenu.isVisible)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 3)
    }

    func testRootScrollClosesSubmenuAndKeepsRootOpen() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show(visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 400))
        fixture.seedSubmenuRows()
        fixture.host.openSubmenu(.advanced, enterKeyboard: false)
        let root = try XCTUnwrap(fixture.host.panel)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)
        let scrollView = try XCTUnwrap(root.contentView as? NSScrollView)
        let origin = scrollView.contentView.bounds.origin

        scrollView.contentView.scroll(to: CGPoint(x: origin.x, y: origin.y == 0 ? 40 : 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertFalse(submenu.isVisible)
        XCTAssertTrue(root.isVisible)
        XCTAssertFalse(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)
    }

    func testHoverCancellationPreventsDelayedOpening() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.hoverSubmenu(.advanced, hovered: true)
        fixture.host.hoverSubmenu(.advanced, hovered: false)

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertNotEqual(fixture.host.submenuPanel?.isVisible, true)
        fixture.host.hoverSubmenu(.help, hovered: true)
        fixture.host.dismiss()

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertFalse(fixture.host.isVisible)
        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertNotEqual(fixture.host.submenuPanel?.isVisible, true)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 2)
    }

    func testHoverSwitchesBranchesAndUnrelatedControlClosesSubmenu() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.hoverSubmenu(.advanced, hovered: true)

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertEqual(fixture.host.presentation.expandedPage, .advanced)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)
        fixture.host.hoverSubmenu(.help, hovered: true)

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertEqual(fixture.host.presentation.expandedPage, .help)
        XCTAssertTrue(fixture.host.submenuPanel === submenu)
        fixture.host.hoverSubmenu(nil, hovered: true)

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertFalse(submenu.isVisible)
        XCTAssertTrue(fixture.host.isVisible)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)
    }

    func testEnteringSubmenuCancelsPendingHoverClose() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.openSubmenu(.advanced, enterKeyboard: false)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)
        fixture.host.hoverSubmenu(nil, hovered: true)
        fixture.host.submenuEntered()

        try await Task.sleep(for: .milliseconds(225))

        XCTAssertEqual(fixture.host.presentation.expandedPage, .advanced)
        XCTAssertTrue(submenu.isVisible)
        XCTAssertEqual(fixture.model.menuPresentationGeneration, 1)
    }

    func testEscapeClosesChildFirstWithoutReclaimingLostKeyFocus() throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.openSubmenu(.advanced, enterKeyboard: true)
        let root = try XCTUnwrap(fixture.host.panel)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)
        root.resignKey()
        submenu.resignKey()
        let focusGeneration = fixture.host.presentation.rootFocusGeneration

        fixture.host.handleEscape()

        XCTAssertTrue(root.isVisible)
        XCTAssertFalse(submenu.isVisible)
        XCTAssertNil(fixture.host.presentation.expandedPage)
        XCTAssertEqual(fixture.host.presentation.rootFocusGeneration, focusGeneration)
        XCTAssertFalse(root.isKeyWindow)
        XCTAssertFalse(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
        fixture.host.handleEscape()

        XCTAssertFalse(root.isVisible)
        XCTAssertFalse(fixture.host.isVisible)
        XCTAssertTrue(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
    }

    func testActionRunsAfterBothPanelsAndFocusProtectionAreDismissed() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.show()
        fixture.seedSubmenuRows()
        fixture.host.openSubmenu(.advanced, enterKeyboard: false)
        let root = try XCTUnwrap(fixture.host.panel)
        let submenu = try XCTUnwrap(fixture.host.submenuPanel)
        let completed = expectation(description: "action ran after group dismissal")
        let dismiss = StatusMenuDismissAction(dismiss: { fixture.host.dismiss() })

        dismiss {
            XCTAssertFalse(fixture.host.isVisible)
            XCTAssertFalse(root.isVisible)
            XCTAssertFalse(submenu.isVisible)
            XCTAssertTrue(fixture.controller.focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 1)
    }

    private func makeFixture() -> StatusMenuPanelFixture {
        StatusMenuPanelFixture()
    }
}

@MainActor
private final class StatusMenuPanelFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OmniWMStatusPanelTests-\(UUID())")
    let controller: WMController
    let model: StatusMenuModel
    let host: StatusMenuHost

    init() {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics")
        )
        model = StatusMenuModel(settings: settings, controller: controller)
        host = StatusMenuHost(model: model, controller: controller)
    }

    func show(visibleFrame: CGRect? = nil) {
        let frame = visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        host.show(anchor: CGPoint(x: frame.maxX - 160, y: frame.maxY), visibleFrame: frame)
    }

    func seedSubmenuRows() {
        guard let scrollView = host.panel?.contentView as? NSScrollView,
              let document = scrollView.documentView
        else { return }
        let top = document.isFlipped
            ? scrollView.contentView.bounds.minY
            : document.bounds.height - scrollView.contentView.bounds.maxY
        for (index, page) in [StatusMenuPage.advanced, .diagnostics, .help].enumerated() {
            host.updateSubmenuRowFrame(
                page,
                frame: CGRect(x: 0, y: top + 100 + CGFloat(index) * 30, width: 280, height: 30)
            )
        }
    }

    func cleanup() {
        host.dismiss()
        controller.focusPolicyEngine.endLease(owner: .nativeMenu)
        try? FileManager.default.removeItem(at: root)
    }
}
