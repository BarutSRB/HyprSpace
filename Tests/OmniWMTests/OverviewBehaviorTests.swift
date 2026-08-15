// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class OverviewBehaviorTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testRevealPreservesAlreadyVisibleOffset() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 200, width: 300, height: 200),
            currentOffset: -50,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -50)
    }

    func testRevealChoosesNearestEdgeAboveAndBelow() {
        let layout = makeGeometryLayout()

        let below = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: -200, width: 300, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let above = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 100, y: 150, width: 300, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(below, -216)
        XCTAssertEqual(above, -434)
    }

    func testRevealBoundsPaddingForNearlyViewportSizedCard() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -100, width: 900, height: 694)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -103)
        assertVisible(target, in: layout, offset: offset)
    }

    func testRevealAlignsOversizedCardToContentTop() {
        let layout = makeGeometryLayout()
        let target = CGRect(x: 0, y: -500, width: 900, height: 800)

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: target,
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -400)
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        XCTAssertEqual(target.maxY, viewport.maxY)
    }

    func testRevealClampsAtBothScrollBounds() {
        let layout = makeGeometryLayout()

        let bottom = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -2200, width: 200, height: 100),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )
        let top = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: 1200, width: 200, height: 100),
            currentOffset: -600,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(bottom, -1300)
        XCTAssertEqual(top, 0)
    }

    func testRevealPreservesFractionalCoordinates() {
        let layout = makeGeometryLayout()

        let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: CGRect(x: 0, y: -10.25, width: 200, height: 99.5),
            currentOffset: 0,
            layout: layout,
            screenFrame: screenFrame
        )

        XCTAssertEqual(offset, -26.25, accuracy: 0.0001)
    }

    func testRevealAtEverySupportedZoomStepRemainsBoundedAndVisible() {
        for percentage in stride(from: 50, through: 150, by: 5) {
            let scale = CGFloat(percentage) / 100
            let layout = makeGeometryLayout(scale: scale)
            let target = CGRect(x: 0, y: -250, width: 300, height: 80)

            let offset = OverviewLayoutCalculator.scrollOffsetRevealing(
                targetFrame: target,
                currentOffset: 0,
                layout: layout,
                screenFrame: screenFrame
            )

            XCTAssertTrue(
                OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
                    .contains(offset),
                "zoom \(percentage)%"
            )
            assertVisible(target, in: layout, offset: offset, message: "zoom \(percentage)%")
        }
    }

    func testNavigationRevealsThirdWorkspaceAndKeepsSingleWindowRowSelection() throws {
        let fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)
        layout.setSelected(handle: first)

        let second = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .down)
        )
        layout.setSelected(handle: second)
        let third = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: second, direction: .down)
        )
        layout.setSelected(handle: third)
        let thirdWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: thirdWindow.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )

        assertVisible(thirdWindow.overviewFrame, in: layout, offset: layout.scrollOffset)
        XCTAssertTrue(layout.scrollOffset < 0)
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: third, direction: .right),
            third
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .left),
            first
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findCycledWindow(in: layout, from: third, forward: true),
            first
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findCycledWindow(in: layout, from: first, forward: false),
            third
        )
    }

    func testHorizontalWrapStaysInsideCurrentWorkspaceRow() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 3, 3])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "")

        for (rowIndex, row) in fixture.rowHandles.enumerated() {
            let leftEdge = try XCTUnwrap(row.first)
            let rightEdge = try XCTUnwrap(row.last)

            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(in: layout, from: leftEdge, direction: .left),
                rightEdge,
                "left edge of workspace row \(rowIndex) must wrap to the row's right-most window"
            )
            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(in: layout, from: rightEdge, direction: .right),
                leftEdge,
                "right edge of workspace row \(rowIndex) must wrap to the row's left-most window"
            )
        }

        let firstRow = fixture.rowHandles[0]
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: firstRow[0], direction: .right),
            firstRow[1]
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: firstRow[2], direction: .left),
            firstRow[1]
        )
    }

    func testHorizontalNavigationKeepsLoneWindowRowSelectionInPlace() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 1, 2])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let loneWindow = try XCTUnwrap(fixture.rowHandles[1].first)

        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: loneWindow, direction: .right),
            loneWindow
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: loneWindow, direction: .left),
            loneWindow
        )

        let multiWindowRow = fixture.rowHandles[0]
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: multiWindowRow.first, direction: .left),
            multiWindowRow.last
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: multiWindowRow.last, direction: .right),
            multiWindowRow.first
        )
    }

    func testHorizontalNavigationDoesNotCrossVerticallyOverlappingWorkspaces() throws {
        let tallDescriptor = WorkspaceDescriptor(name: "Tall")
        let shortDescriptor = WorkspaceDescriptor(name: "Short")
        let workspaces: [OverviewWorkspaceLayoutItem] = [
            (id: tallDescriptor.id, name: tallDescriptor.name, isActive: true),
            (id: shortDescriptor.id, name: shortDescriptor.name, isActive: false)
        ]
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        let tallToken = WindowToken(pid: 1, windowId: 1)
        let tallHandle = WindowHandle(id: tallToken)
        windows[tallHandle] = (
            token: tallToken,
            workspaceId: tallDescriptor.id,
            title: "Tall 1",
            appName: "App 1",
            appIcon: nil,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        var shortHandles: [WindowHandle] = []
        for slot in 0 ..< 2 {
            let token = WindowToken(pid: pid_t(2 + slot), windowId: 2 + slot)
            let handle = WindowHandle(id: token)
            windows[handle] = (
                token: token,
                workspaceId: shortDescriptor.id,
                title: "Short \(slot + 1)",
                appName: "App \(2 + slot)",
                appIcon: nil,
                frame: CGRect(x: CGFloat(slot) * 500, y: 0, width: 500, height: 233)
            )
            shortHandles.append(handle)
        }
        let layout = projectedLayout(
            fixture: ProjectionFixture(workspaces: workspaces, windows: windows),
            scale: 1,
            query: ""
        )

        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: tallHandle, direction: .left),
            tallHandle
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: tallHandle, direction: .right),
            tallHandle
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: shortHandles[0], direction: .right),
            shortHandles[1]
        )
    }

    func testHorizontalNavigationKeepsLoneRowMatchSelectionWhileSearching() throws {
        let fixture = makeProjectionFixture(windowCountsPerWorkspace: [3, 3, 3])
        let layout = projectedLayout(fixture: fixture, scale: 1, query: "2")

        for (rowIndex, row) in fixture.rowHandles.enumerated() {
            let loneMatch = row[1]

            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(in: layout, from: loneMatch, direction: .right),
                loneMatch,
                "workspace row \(rowIndex)"
            )
            XCTAssertEqual(
                OverviewLayoutCalculator.findNextWindow(in: layout, from: loneMatch, direction: .left),
                loneMatch,
                "workspace row \(rowIndex)"
            )
        }

        let matchingHandles = fixture.rowHandles.map { $0[1] }
        XCTAssertEqual(
            OverviewLayoutCalculator.findCycledWindow(
                in: layout,
                from: matchingHandles[0],
                forward: true
            ),
            matchingHandles[1]
        )
        XCTAssertEqual(
            OverviewLayoutCalculator.findCycledWindow(
                in: layout,
                from: matchingHandles[0],
                forward: false
            ),
            matchingHandles[2]
        )
    }

    func testZoomPreservesSelectedMidpointsIndependentlyUntilClamped() throws {
        let fixture = makeProjectionFixture()
        var firstMonitor = projectedLayout(fixture: fixture, scale: 1, query: "")
        var secondMonitor = firstMonitor
        let selected = try XCTUnwrap(firstMonitor.allWindows.last?.handle)
        firstMonitor.setSelected(handle: selected)
        secondMonitor.setSelected(handle: selected)
        firstMonitor.scrollOffset = -500
        secondMonitor.scrollOffset = -700
        let firstMidpoint = try XCTUnwrap(firstMonitor.window(for: selected)).overviewFrame.midY
            - firstMonitor.scrollOffset
        let secondMidpoint = try XCTUnwrap(secondMonitor.window(for: selected)).overviewFrame.midY
            - secondMonitor.scrollOffset

        var zoomedFirst = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        var zoomedSecond = zoomedFirst
        zoomedFirst.setSelected(handle: selected)
        zoomedSecond.setSelected(handle: selected)
        let zoomedWindow = try XCTUnwrap(zoomedFirst.window(for: selected))
        let firstDesiredOffset = zoomedWindow.overviewFrame.midY - firstMidpoint
        let secondDesiredOffset = zoomedWindow.overviewFrame.midY - secondMidpoint
        zoomedFirst.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            firstDesiredOffset,
            layout: zoomedFirst,
            screenFrame: screenFrame
        )
        zoomedSecond.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            secondDesiredOffset,
            layout: zoomedSecond,
            screenFrame: screenFrame
        )

        XCTAssertNotEqual(zoomedFirst.scrollOffset, zoomedSecond.scrollOffset)
        XCTAssertEqual(
            zoomedWindow.overviewFrame.midY - zoomedFirst.scrollOffset,
            firstMidpoint,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            OverviewLayoutCalculator.scrollOffsetBounds(layout: zoomedSecond, screenFrame: screenFrame)
                .contains(secondDesiredOffset)
        )
        XCTAssertEqual(
            zoomedSecond.scrollOffset,
            OverviewLayoutCalculator.clampedScrollOffset(
                secondDesiredOffset,
                layout: zoomedSecond,
                screenFrame: screenFrame
            )
        )
    }

    func testSelectionSearchZoomRemovalSequenceMaintainsViewportInvariants() throws {
        var fixture = makeProjectionFixture()
        var layout = projectedLayout(fixture: fixture, scale: 1, query: "")
        let first = try XCTUnwrap(layout.allWindows.first?.handle)
        layout.setSelected(handle: first)
        assertViewportInvariant(layout)

        let second = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: first, direction: .down)
        )
        let third = try XCTUnwrap(
            OverviewLayoutCalculator.findNextWindow(in: layout, from: second, direction: .down)
        )
        layout.setSelected(handle: third)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        let previousOffset = layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1, query: "third")
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            previousOffset,
            layout: layout,
            screenFrame: screenFrame
        )
        layout.setSelected(handle: third)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        let midpoint = try XCTUnwrap(layout.window(for: third)).overviewFrame.midY - layout.scrollOffset
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "third")
        layout.setSelected(handle: third)
        let zoomedWindow = try XCTUnwrap(layout.window(for: third))
        layout.scrollOffset = OverviewLayoutCalculator.clampedScrollOffset(
            zoomedWindow.overviewFrame.midY - midpoint,
            layout: layout,
            screenFrame: screenFrame
        )
        revealSelection(in: &layout)
        assertViewportInvariant(layout)

        fixture.windows.removeValue(forKey: third)
        layout = projectedLayout(fixture: fixture, scale: 1.5, query: "")
        layout.setSelected(handle: layout.allWindows.first?.handle)
        revealSelection(in: &layout)
        assertViewportInvariant(layout)
    }

    func testActivationAndDismissalDoNotRepeatWhileNavigationAndCyclingDo() {
        let repeatedReturn = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [],
            charactersIgnoringModifiers: "\r",
            searchQuery: "",
            isRepeat: true
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: true
        )
        let repeatedArrow = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_DownArrow),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )
        let repeatedTab = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Tab),
            modifierFlags: .shift,
            charactersIgnoringModifiers: "\t",
            searchQuery: "",
            isRepeat: true
        )
        let forwardTab = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Tab),
            modifierFlags: [],
            charactersIgnoringModifiers: "\t",
            searchQuery: ""
        )

        XCTAssertEqual(repeatedReturn.action, .consume)
        XCTAssertTrue(repeatedReturn.shouldConsume)
        XCTAssertEqual(repeatedEscape.action, .consume)
        XCTAssertTrue(repeatedEscape.shouldConsume)
        XCTAssertEqual(repeatedArrow.action, .navigate(.down))
        XCTAssertEqual(repeatedTab.action, .cycleSelection(forward: false))
        XCTAssertEqual(forwardTab.action, .cycleSelection(forward: true))
    }

    func testEscapeDismissesSelectionEvenWithSearch() {
        let firstEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "query",
            isRepeat: false
        )
        let repeatedEscape = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_Escape),
            modifierFlags: [],
            charactersIgnoringModifiers: nil,
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(firstEscape.action, .dismissSelection)
        XCTAssertEqual(repeatedEscape.action, .consume)
    }

    func testCommandWClosesSelectionWithoutRepeating() {
        let commandW = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: .command,
            charactersIgnoringModifiers: "w",
            searchQuery: "",
            isRepeat: false
        )
        let repeatedCommandW = OverviewInputHandler.keyHandlingResult(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: .command,
            charactersIgnoringModifiers: "w",
            searchQuery: "",
            isRepeat: true
        )

        XCTAssertEqual(commandW.action, .closeSelection)
        XCTAssertEqual(repeatedCommandW.action, .consume)
    }

    func testRegisteredEscapeUsesPhysicalDismissalBeforeAssignedCommand() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        let disposition = overview.handleHotkeyInvocation(
            HotkeyInvocation(
                command: .toggleFullscreen,
                trigger: PhysicalHotkeyTrigger(
                    keyCode: UInt32(kVK_Escape),
                    modifiers: UInt32(optionKey),
                    isRepeat: false
                )
            )
        )

        XCTAssertEqual(disposition, .handled)
        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertFalse(overview.state.isOpen)
    }

    func testOverviewToggleCloseFocusesCurrentSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        XCTAssertEqual(overview.handleHotkeyCommand(.toggleOverview), .handled)

        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertFalse(overview.state.isOpen)
    }

    func testRegisteredCommandWConsumesRepeatAndClosesOnce() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        var closeCount = 0
        overview.onCloseWindow = { _ in
            closeCount += 1
            return true
        }

        let repeated = HotkeyInvocation(
            command: .toggleFullscreen,
            trigger: PhysicalHotkeyTrigger(
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(cmdKey),
                isRepeat: true
            )
        )
        let initial = HotkeyInvocation(
            command: .toggleFullscreen,
            trigger: PhysicalHotkeyTrigger(
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(cmdKey),
                isRepeat: false
            )
        )

        XCTAssertEqual(overview.handleHotkeyInvocation(repeated), .handled)
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(overview.handleHotkeyInvocation(initial), .handled)
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(overview.state.isOpen)
    }

    func testRepeatedRegisteredOverviewToggleIsConsumedWhileClosed() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        let result = fixture.controller.commandHandler.handleHotkeyInvocation(
            HotkeyInvocation(
                command: .toggleOverview,
                trigger: PhysicalHotkeyTrigger(
                    keyCode: UInt32(kVK_ANSI_O),
                    modifiers: UInt32(optionKey),
                    isRepeat: true
                )
            )
        )

        XCTAssertEqual(result, .executed)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
    }

    func testRemovalSelectionChoosesNextThenPrevious() {
        let handles = (1 ... 3).map { index in
            WindowHandle(id: WindowToken(pid: pid_t(index), windowId: index))
        }

        XCTAssertEqual(
            OverviewController.selectionAfterRemoving(
                handles[1],
                from: handles,
                availableHandles: [handles[0], handles[2]]
            ),
            handles[2]
        )
        XCTAssertEqual(
            OverviewController.selectionAfterRemoving(
                handles[2],
                from: handles,
                availableHandles: [handles[0], handles[1]]
            ),
            handles[1]
        )
        XCTAssertNil(
            OverviewController.selectionAfterRemoving(
                handles[0],
                from: handles,
                availableHandles: []
            )
        )
    }

    func testSelectionDismissalFocusesCurrentOverviewSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        var activatedHandle: WindowHandle?
        var activatedWorkspaceId: WorkspaceDescriptor.ID?
        overview.onActivateWindow = { handle, workspaceId in
            activatedHandle = handle
            activatedWorkspaceId = workspaceId
        }

        overview.dismissToSelection(animated: false)

        XCTAssertEqual(activatedHandle, selectedHandle)
        XCTAssertEqual(activatedWorkspaceId, fixture.workspaceId)
        XCTAssertEqual(overview.state.isOpen, false)
    }

    func testClosingStateFreezesKeyboardAndMouseSelection() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let originalSelection = try XCTUnwrap(overview.selectedWindowHandle)
        overview.cycleSelection(forward: true)

        let closingSelection = try XCTUnwrap(overview.selectedWindowHandle)
        XCTAssertNotEqual(closingSelection, originalSelection)
        overview.updateAnimationProgress(
            0,
            state: .closing(targetWindow: closingSelection, progress: 0)
        )

        overview.cycleSelection(forward: false)
        overview.selectAndActivateWindow(originalSelection)

        XCTAssertEqual(overview.selectedWindowHandle, closingSelection)
    }

    func testDismissalCancelsDragBeforeAnimatedCloseCompletes() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 1)
        fixture.controller.motionPolicy.animationsEnabled = true
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let selectedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let monitorId = try XCTUnwrap(fixture.controller.workspaceManager.monitors.first?.id)
        var activatedHandle: WindowHandle?
        overview.onActivateWindow = { handle, _ in activatedHandle = handle }

        overview.beginDrag(on: monitorId, handle: selectedHandle, startPoint: .zero)
        XCTAssertTrue(overview.hasActiveDragSession)

        overview.dismissToSelection(animated: true)

        XCTAssertFalse(overview.hasActiveDragSession)
        guard case .closing = overview.state else {
            return XCTFail("Expected animated dismissal to remain in closing state")
        }
        overview.endDrag(on: monitorId, at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(
            fixture.controller.workspaceManager.workspace(for: selectedHandle.id),
            fixture.workspaceId
        )

        overview.completeCloseTransition(targetWindow: selectedHandle)
        XCTAssertEqual(activatedHandle, selectedHandle)
    }

    func testCloseSelectionWaitsForAuthoritativeRemovalBeforeAdvancing() throws {
        let fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let removedHandle = try XCTUnwrap(overview.selectedWindowHandle)
        let expectedSuccessorToken = try XCTUnwrap(
            fixture.handles.first { $0.id != removedHandle.id }
        ).id
        var closeAccepted = false
        overview.onCloseWindow = { handle in
            XCTAssertEqual(handle, removedHandle)
            return closeAccepted
        }
        fixture.controller.workspaceManager.onWindowRemoved = { entry in
            XCTAssertNil(fixture.controller.workspaceManager.entry(for: entry.token))
            overview.handleManagedWindowRemoved(entry)
        }

        overview.closeSelectedWindow()
        XCTAssertEqual(overview.selectedWindowHandle, removedHandle)

        closeAccepted = true
        overview.closeSelectedWindow()
        XCTAssertEqual(overview.selectedWindowHandle, removedHandle)

        _ = fixture.controller.workspaceManager.removeWindow(
            pid: removedHandle.id.pid,
            windowId: removedHandle.id.windowId
        )

        XCTAssertEqual(overview.selectedWindowHandle?.id, expectedSuccessorToken)
    }

    func testOverviewSnapshotExcludesHiddenApplicationWindows() throws {
        var titleReads = 0
        var frameReads = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        fixture.environment.windowFrame = { _ in
            frameReads += 1
            return CGRect(x: 10, y: 10, width: 500, height: 400)
        }
        let hiddenToken = fixture.handles[0].id
        let visibleToken = fixture.handles[1].id
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: hiddenToken.pid,
            source: .service
        )
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )

        overview.prepareOpenState()

        XCTAssertEqual(overview.selectedWindowHandle?.id, visibleToken)
        XCTAssertEqual(titleReads, 1)
        XCTAssertEqual(frameReads, 1)
    }

    func testCachedProjectionRemovesAndRestoresHiddenNiriWindow() throws {
        var titleReads = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        let hiddenHandle = try XCTUnwrap(overview.selectedWindowHandle)

        titleReads = 0
        fixture.controller.workspaceManager.setAppHidden(
            true,
            pid: hiddenHandle.pid,
            source: .service
        )
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])

        XCTAssertNotEqual(overview.selectedWindowHandle, hiddenHandle)
        XCTAssertEqual(titleReads, 0)

        fixture.controller.workspaceManager.setAppHidden(
            false,
            pid: hiddenHandle.pid,
            source: .service
        )
        overview.refreshCachedOverviewProjection(
            affectedWorkspaceIds: [fixture.workspaceId],
            selectedHandle: hiddenHandle
        )

        XCTAssertEqual(overview.selectedWindowHandle, hiddenHandle)
        XCTAssertEqual(titleReads, 1)
    }

    func testCachedProjectionRefreshDoesNotRereadWindowMetadataOrRestartCapture() throws {
        var titleReads = 0
        var frameReads = 0
        var captureStarts = 0
        var fixture = try makeRuntimeOverviewFixture(windowCount: 2)
        fixture.environment.windowTitle = { _ in
            titleReads += 1
            return "Window"
        }
        fixture.environment.windowFrame = { _ in
            frameReads += 1
            return CGRect(x: 10, y: 10, width: 500, height: 400)
        }
        fixture.environment.onThumbnailCaptureStarted = {
            captureStarts += 1
        }
        let overview = OverviewController(
            wmController: fixture.controller,
            motionPolicy: fixture.controller.motionPolicy,
            environment: fixture.environment
        )
        overview.prepareOpenState()
        overview.updateAnimationProgress(1, state: .open)
        XCTAssertEqual(titleReads, 2)
        XCTAssertEqual(frameReads, 2)

        titleReads = 0
        frameReads = 0
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])
        overview.refreshCachedOverviewProjection(affectedWorkspaceIds: [fixture.workspaceId])

        XCTAssertEqual(titleReads, 0)
        XCTAssertEqual(frameReads, 0)
        XCTAssertEqual(captureStarts, 0)
    }

    private func makeGeometryLayout(scale: CGFloat = 1) -> OverviewLayout {
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = CGRect(x: 250, y: 720, width: 500, height: 44)
        layout.totalContentHeight = 2000
        return layout
    }

    private struct ProjectionFixture {
        var workspaces: [OverviewWorkspaceLayoutItem]
        var windows: [WindowHandle: OverviewWindowLayoutData]
        var rowHandles: [[WindowHandle]] = []
    }

    private struct RuntimeOverviewFixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let handles: [WindowHandle]
        var environment: OverviewEnvironment
    }

    private func makeRuntimeOverviewFixture(windowCount: Int) throws -> RuntimeOverviewFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.motionPolicy.animationsEnabled = false
        let monitor = Monitor(
            id: .init(displayId: 91_001),
            displayId: 91_001,
            frame: screenFrame,
            visibleFrame: screenFrame,
            hasNotch: false,
            name: "Overview"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let handles = (0 ..< windowCount).map { index in
            let pid = pid_t(91_100 + index)
            let windowId = 91_200 + index
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            return WindowHandle(id: token)
        }
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in "Window" }
        environment.windowFrame = { _ in CGRect(x: 10, y: 10, width: 500, height: 400) }
        return RuntimeOverviewFixture(
            controller: controller,
            workspaceId: workspaceId,
            handles: handles,
            environment: environment
        )
    }

    private func makeProjectionFixture() -> ProjectionFixture {
        makeProjectionFixture(windowCountsPerWorkspace: [1, 1, 1])
    }

    private func makeProjectionFixture(windowCountsPerWorkspace: [Int]) -> ProjectionFixture {
        let descriptors = ["First", "Second", "Third"].map { WorkspaceDescriptor(name: $0) }
        precondition(windowCountsPerWorkspace.count == descriptors.count)
        let workspaces = descriptors.enumerated().map { index, descriptor in
            (id: descriptor.id, name: descriptor.name, isActive: index == 0)
        }
        var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
        var rowHandles: [[WindowHandle]] = []
        var tokenSeed = 0
        for (index, descriptor) in descriptors.enumerated() {
            let windowCount = windowCountsPerWorkspace[index]
            let columnWidth = 1000.0 / CGFloat(windowCount)
            var row: [WindowHandle] = []
            for slot in 0 ..< windowCount {
                tokenSeed += 1
                let token = WindowToken(pid: pid_t(tokenSeed), windowId: tokenSeed)
                let handle = WindowHandle(id: token)
                windows[handle] = (
                    token: token,
                    workspaceId: descriptor.id,
                    title: "\(descriptor.name) \(slot + 1)",
                    appName: "App \(tokenSeed)",
                    appIcon: nil,
                    frame: CGRect(x: columnWidth * CGFloat(slot), y: 0, width: columnWidth, height: 700)
                )
                row.append(handle)
            }
            rowHandles.append(row)
        }
        return ProjectionFixture(workspaces: workspaces, windows: windows, rowHandles: rowHandles)
    }

    private func projectedLayout(
        fixture: ProjectionFixture,
        scale: CGFloat,
        query: String
    ) -> OverviewLayout {
        OverviewLayoutCalculator.calculateLayout(
            workspaces: fixture.workspaces,
            windows: fixture.windows,
            screenFrame: screenFrame,
            searchQuery: query,
            scale: scale
        )
    }

    private func revealSelection(in layout: inout OverviewLayout) {
        guard let selected = layout.selectedWindow() else { return }
        layout.scrollOffset = OverviewLayoutCalculator.scrollOffsetRevealing(
            targetFrame: selected.overviewFrame,
            currentOffset: layout.scrollOffset,
            layout: layout,
            screenFrame: screenFrame
        )
    }

    private func assertViewportInvariant(_ layout: OverviewLayout, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(layout: layout, screenFrame: screenFrame)
        XCTAssertTrue(bounds.contains(layout.scrollOffset), file: file, line: line)
        if let selected = layout.selectedWindow(), selected.matchesSearch {
            assertVisible(selected.overviewFrame, in: layout, offset: layout.scrollOffset, file: file, line: line)
        }
    }

    private func assertVisible(
        _ target: CGRect,
        in layout: OverviewLayout,
        offset: CGFloat,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = OverviewLayoutCalculator.visibleContentFrame(
            layout: layout,
            screenFrame: screenFrame,
            scrollOffset: offset
        )
        guard target.height <= viewport.height else { return }
        let padding = min(
            OverviewLayoutMetrics.windowSpacing * OverviewLayoutCalculator.clampedScale(layout.scale),
            max(0, (viewport.height - target.height) / 2)
        )
        let paddedViewport = viewport.insetBy(dx: 0, dy: padding)
        XCTAssertGreaterThanOrEqual(target.minY + 0.0001, paddedViewport.minY, message, file: file, line: line)
        XCTAssertLessThanOrEqual(target.maxY - 0.0001, paddedViewport.maxY, message, file: file, line: line)
    }
}
