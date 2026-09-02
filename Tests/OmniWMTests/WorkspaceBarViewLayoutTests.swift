// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

private struct NarrowWidthLayout: Layout {
    let width: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        subviews.first?.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        ) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }
}

@MainActor
final class WorkspaceBarViewLayoutTests: XCTestCase {
    func testWindowPresentationDistinguishesAppHiddenAndPartialGroups() {
        let hiddenWindow = makeWindowItem(
            appName: "Mail",
            windowCount: 1,
            hiddenWindowCount: 1,
            isFocused: true
        )
        let hiddenPresentation = WorkspaceBarWindowPresentation(
            window: hiddenWindow,
            context: .tiled,
            isFocused: true,
            isInFocusedWorkspace: true
        )

        XCTAssertEqual(hiddenPresentation.hiddenIndicatorStyle, .appHidden)
        XCTAssertTrue(hiddenPresentation.appliesHiddenTint)
        XCTAssertEqual(hiddenPresentation.iconOpacity, 0.9)
        XCTAssertEqual(hiddenPresentation.accessibilityLabel, "Mail window")
        XCTAssertEqual(hiddenPresentation.accessibilityValue, "Focused, App hidden")
        XCTAssertEqual(hiddenPresentation.accessibilityHint, "Unhides the app and focuses this window")
        XCTAssertEqual(hiddenPresentation.help, "Unhide and focus Mail")

        let partialGroup = makeWindowItem(
            appName: "Browser",
            windowCount: 3,
            hiddenWindowCount: 1
        )
        let partialPresentation = WorkspaceBarWindowPresentation(
            window: partialGroup,
            context: .floating,
            isFocused: false,
            isInFocusedWorkspace: true
        )

        XCTAssertEqual(partialPresentation.hiddenIndicatorStyle, .partiallyHidden)
        XCTAssertFalse(partialPresentation.appliesHiddenTint)
        XCTAssertEqual(partialPresentation.iconOpacity, 0.4)
        XCTAssertEqual(partialPresentation.accessibilityLabel, "Browser, 3 floating windows")
        XCTAssertEqual(partialPresentation.accessibilityValue, "1 of 3 windows hidden")
        XCTAssertEqual(partialPresentation.accessibilityHint, "Opens the window list")
        XCTAssertEqual(partialPresentation.help, "Show Browser windows — 1 of 3 hidden")
    }

    func testWindowPresentationUsesExactVisibleAndAllHiddenGroupActions() {
        let visibleWindow = makeWindowItem(appName: "Notes", windowCount: 1, hiddenWindowCount: 0)
        let visiblePresentation = WorkspaceBarWindowPresentation(
            window: visibleWindow,
            context: .tiled,
            isFocused: false,
            isInFocusedWorkspace: false
        )

        XCTAssertNil(visiblePresentation.hiddenIndicatorStyle)
        XCTAssertFalse(visiblePresentation.appliesHiddenTint)
        XCTAssertEqual(visiblePresentation.iconOpacity, 0.5)
        XCTAssertEqual(visiblePresentation.accessibilityValue, "")
        XCTAssertEqual(visiblePresentation.accessibilityHint, "Focuses this window")
        XCTAssertEqual(visiblePresentation.help, "Focus Notes window")

        let visibleGroup = makeWindowItem(appName: "Terminal", windowCount: 2, hiddenWindowCount: 0)
        let visibleGroupPresentation = WorkspaceBarWindowPresentation(
            window: visibleGroup,
            context: .tiled,
            isFocused: false,
            isInFocusedWorkspace: false
        )

        XCTAssertEqual(visibleGroupPresentation.help, "Show Terminal windows")

        let hiddenGroup = makeWindowItem(appName: "Terminal", windowCount: 2, hiddenWindowCount: 2)
        let hiddenGroupPresentation = WorkspaceBarWindowPresentation(
            window: hiddenGroup,
            context: .tiled,
            isFocused: false,
            isInFocusedWorkspace: false
        )

        XCTAssertEqual(hiddenGroupPresentation.accessibilityValue, "All 2 windows hidden")
        XCTAssertEqual(hiddenGroupPresentation.help, "Show Terminal windows — app hidden")
    }

    func testWindowListRowPresentationDescribesRevealAction() {
        let token = WindowToken(pid: 42, windowId: 1)
        let hiddenInfo = WorkspaceBarWindowInfo(
            id: token,
            handle: WindowHandle(id: token),
            windowId: token.windowId,
            title: "Compose",
            isFocused: true,
            isAppHidden: true
        )
        let hiddenPresentation = WorkspaceBarWindowListRowPresentation(window: hiddenInfo)

        XCTAssertEqual(hiddenPresentation.accessibilityValue, "Focused, App hidden")
        XCTAssertEqual(hiddenPresentation.accessibilityHint, "Unhides the app and focuses this window")
        XCTAssertEqual(hiddenPresentation.help, "Unhide and focus Compose")

        let visibleToken = WindowToken(pid: 42, windowId: 2)
        let visibleInfo = WorkspaceBarWindowInfo(
            id: visibleToken,
            handle: WindowHandle(id: visibleToken),
            windowId: visibleToken.windowId,
            title: "Inbox",
            isFocused: false,
            isAppHidden: false
        )
        let visiblePresentation = WorkspaceBarWindowListRowPresentation(window: visibleInfo)

        XCTAssertEqual(visiblePresentation.accessibilityValue, "")
        XCTAssertEqual(visiblePresentation.accessibilityHint, "Focuses this window")
        XCTAssertEqual(visiblePresentation.help, "Focus Inbox")
    }

    func testHiddenIndicatorsPreserveWorkspaceBarMeasurement() {
        let widths = [
            makeWindowItem(appName: "Browser", windowCount: 3, hiddenWindowCount: 0),
            makeWindowItem(appName: "Browser", windowCount: 3, hiddenWindowCount: 1),
            makeWindowItem(appName: "Browser", windowCount: 3, hiddenWindowCount: 3)
        ].map { window in
            let snapshot = makeSnapshot(windows: [window], barHeight: 24)
            let hostingView = NSHostingView(
                rootView: WorkspaceBarMeasurementView(snapshot: snapshot)
            )
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize
        }

        XCTAssertEqual(widths[1].width, widths[0].width, accuracy: 0.5)
        XCTAssertEqual(widths[2].width, widths[0].width, accuracy: 0.5)
        XCTAssertEqual(widths[1].height, widths[0].height, accuracy: 0.5)
        XCTAssertEqual(widths[2].height, widths[0].height, accuracy: 0.5)
    }

    func testWorkspaceLabelsKeepIntrinsicWidthUnderNarrowProposal() {
        let proposalWidth: CGFloat = 40
        let barHeight: CGFloat = 24

        for (name, windowCount) in [
            ("Sync", 1),
            ("Ship", 5),
            ("Lab", 0),
            ("Sandbox", 0),
            ("Chill", 3)
        ] {
            let windows = (0 ..< windowCount).map { index in
                let token = WindowToken(pid: 1, windowId: index + 1)
                let handle = WindowHandle(id: token)
                return WorkspaceBarWindowItem(
                    id: token,
                    handle: handle,
                    windowId: token.windowId,
                    appName: "App \(index + 1)",
                    bundleId: nil,
                    icon: nil,
                    isFocused: false,
                    windowCount: 1,
                    hiddenWindowCount: 0,
                    allWindows: [
                        WorkspaceBarWindowInfo(
                            id: token,
                            handle: handle,
                            windowId: token.windowId,
                            title: "Window \(index + 1)",
                            isFocused: false,
                            isAppHidden: false
                        )
                    ]
                )
            }
            let item = WorkspaceBarItem(
                id: UUID(),
                name: name,
                rawName: name,
                isFocused: false,
                tiledWindows: windows,
                floatingWindows: []
            )
            let snapshot = WorkspaceBarSnapshot(
                projection: WorkspaceBarProjection(items: [item], scratchpads: []),
                showLabels: true,
                showSystemStatsButton: false,
                backgroundOpacity: 0.6,
                barHeight: barHeight,
                accentColor: nil,
                textColor: nil
            )
            let measurementView = NSHostingView(
                rootView: WorkspaceBarMeasurementView(snapshot: snapshot)
            )
            let hostingView = NSHostingView(
                rootView: NarrowWidthLayout(width: proposalWidth) {
                    WorkspaceBarView(
                        model: WorkspaceBarModel(snapshot: snapshot),
                        motionPolicy: MotionPolicy(animationsEnabled: false),
                        onFocusWorkspace: { _ in },
                        onFocusWindow: { _ in },
                        onActivateScratchpad: { _ in }
                    )
                }
            )

            measurementView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(hostingView.fittingSize.width, proposalWidth, name)
            XCTAssertEqual(
                hostingView.fittingSize.width,
                measurementView.fittingSize.width,
                accuracy: 0.5,
                name
            )
            XCTAssertEqual(hostingView.fittingSize.height, barHeight, name)
        }
    }

    func testLongRevealedScratchpadFallsBackToAllCompactWithinSplitSegment() throws {
        let monitor = splitMonitor()
        let resolved = splitBarSettings()
        let activeWorkspace = WorkspaceBarItem(
            id: UUID(),
            name: "1",
            rawName: "1",
            isFocused: true,
            tiledWindows: [],
            floatingWindows: []
        )
        let secondaryWorkspace = WorkspaceBarItem(
            id: UUID(),
            name: "Secondary workspace",
            rawName: "Secondary workspace",
            isFocused: false,
            tiledWindows: [],
            floatingWindows: []
        )
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? String(repeating: "Long revealed scratchpad ", count: 20) : nil,
                windows: (0 ..< 5).map { appIndex in
                    makeWindowItem(
                        appName: "App \(appIndex)",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index * 100 + appIndex
                    )
                },
                isVisible: false,
                isRevealed: index == 1
            )
        }
        let baseSnapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [activeWorkspace, secondaryWorkspace],
                scratchpads: []
            ),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        let baseView = NSHostingView(
            rootView: WorkspaceBarMeasurementView(snapshot: baseSnapshot, slice: .secondary)
        )
        baseView.layoutSubtreeIfNeeded()
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let availableWidth = try XCTUnwrap(
            geometry.splitAvailableWidths(monitor: monitor, resolved: resolved)
        ).secondary
        let compacted = WorkspaceBarScratchpadLayout.compactedItems(
            scratchpads,
            availableWidth: availableWidth,
            baseWidth: baseView.fittingSize.width,
            barHeight: 24,
            hasAdjacentContent: true
        )
        let snapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(
                items: [activeWorkspace, secondaryWorkspace],
                scratchpads: compacted
            ),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        let hostingView = NSHostingView(
            rootView: WorkspaceBarMeasurementView(snapshot: snapshot, slice: .secondary)
        )

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(compacted.allSatisfy { $0.presentation == .compact })
        XCTAssertGreaterThan(baseView.fittingSize.width, 0)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, availableWidth)
    }

    func testDefaultScratchpadsCompactBeforeSplitPanelClips() throws {
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: nil,
                windows: [
                    makeWindowItem(
                        appName: "App",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index
                    )
                ],
                isVisible: false
            )
        }
        let result = try splitCompactionResult(for: scratchpads)

        XCTAssertGreaterThan(result.expandedWidth, result.availableWidth)
        XCTAssertTrue(result.compacted.allSatisfy { $0.presentation == .compact })
        XCTAssertLessThanOrEqual(result.compactedWidth, result.availableWidth)
    }

    func testMixedScratchpadsCompactBeforeFractionalRoundingClips() throws {
        let label = "A practical scratchpad label for notes and terminal work. A practica"
        let scratchpads = (1 ... 8).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? label : nil,
                windows: [
                    makeWindowItem(
                        appName: "App",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index
                    )
                ],
                isVisible: false,
                isRevealed: index == 1
            )
        }
        let result = try splitCompactionResult(for: scratchpads)

        XCTAssertGreaterThan(result.mixedWidth, result.availableWidth)
        XCTAssertTrue(result.compacted.allSatisfy { $0.presentation == .compact })
        XCTAssertLessThanOrEqual(result.compactedWidth, result.availableWidth)
    }

    func testImpossibleScratchpadWidthUsesAllCompactAsTheFloor() {
        let scratchpads = (1 ... 10).map { index in
            WorkspaceBarScratchpadItem(
                index: index,
                label: index == 1 ? String(repeating: "Long label ", count: 20) : nil,
                windows: [
                    makeWindowItem(
                        appName: "App",
                        windowCount: 1,
                        hiddenWindowCount: 0,
                        tokenOffset: index
                    )
                ],
                isVisible: false,
                isRevealed: index == 1
            )
        }

        let compacted = WorkspaceBarScratchpadLayout.compactedItems(
            scratchpads,
            availableWidth: 40,
            baseWidth: 100,
            barHeight: 24,
            hasAdjacentContent: true
        )

        XCTAssertTrue(compacted.allSatisfy { $0.presentation == .compact })
        XCTAssertGreaterThan(
            100 + 8 + WorkspaceBarScratchpadLayout.estimatedWidth(of: compacted, barHeight: 24),
            40
        )
    }

    private func makeWindowItem(
        appName: String,
        windowCount: Int,
        hiddenWindowCount: Int,
        isFocused: Bool = false,
        tokenOffset: Int = 0
    ) -> WorkspaceBarWindowItem {
        let infos = (0 ..< windowCount).map { index in
            let token = WindowToken(
                pid: 42 + Int32(tokenOffset + index),
                windowId: tokenOffset + index + 1
            )
            return WorkspaceBarWindowInfo(
                id: token,
                handle: WindowHandle(id: token),
                windowId: token.windowId,
                title: "Window \(index + 1)",
                isFocused: isFocused && index == 0,
                isAppHidden: index < hiddenWindowCount
            )
        }
        let first = infos[0]
        return WorkspaceBarWindowItem(
            id: first.id,
            handle: first.handle,
            windowId: first.windowId,
            appName: appName,
            bundleId: nil,
            icon: nil,
            isFocused: isFocused,
            windowCount: windowCount,
            hiddenWindowCount: hiddenWindowCount,
            allWindows: infos
        )
    }

    private func splitMonitor() -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 7_001),
            displayId: 7_001,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            notchRange: 656 ... 856,
            name: "Test"
        )
    }

    private func splitBarSettings() -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: .splitActiveLeft,
            notchActiveZoneWidth: 180,
            systemStatsButton: false,
            position: .overlappingMenuBar,
            windowLevel: .popup,
            height: 24,
            backgroundOpacity: 0.1,
            xOffset: 0,
            yOffset: 0,
            accentColor: nil,
            textColor: nil
        )
    }

    private func splitCompactionResult(
        for scratchpads: [WorkspaceBarScratchpadItem]
    ) throws -> (
        compacted: [WorkspaceBarScratchpadItem],
        availableWidth: CGFloat,
        expandedWidth: CGFloat,
        mixedWidth: CGFloat,
        compactedWidth: CGFloat
    ) {
        let activeWorkspace = WorkspaceBarItem(
            id: UUID(),
            name: "1",
            rawName: "1",
            isFocused: true,
            tiledWindows: [],
            floatingWindows: []
        )
        let baseSnapshot = WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [activeWorkspace], scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: 24,
            accentColor: nil,
            textColor: nil
        )
        let baseView = NSHostingView(
            rootView: WorkspaceBarMeasurementView(snapshot: baseSnapshot, slice: .secondary)
        )
        baseView.layoutSubtreeIfNeeded()
        let monitor = splitMonitor()
        let resolved = splitBarSettings()
        let availableWidth = try XCTUnwrap(
            WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
                .splitAvailableWidths(monitor: monitor, resolved: resolved)
        ).secondary
        let compacted = WorkspaceBarScratchpadLayout.compactedItems(
            scratchpads,
            availableWidth: availableWidth,
            baseWidth: baseView.fittingSize.width,
            barHeight: 24,
            hasAdjacentContent: false
        )
        let mixed = scratchpads.map {
            $0.presented(as: $0.isRevealed ? .expanded : .compact)
        }

        func measuredWidth(_ items: [WorkspaceBarScratchpadItem]) -> CGFloat {
            let view = NSHostingView(
                rootView: WorkspaceBarMeasurementView(
                    snapshot: baseSnapshot.replacingScratchpads(items),
                    slice: .secondary
                )
            )
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.width
        }

        return (
            compacted,
            availableWidth,
            measuredWidth(scratchpads),
            measuredWidth(mixed),
            measuredWidth(compacted)
        )
    }

    private func makeSnapshot(
        windows: [WorkspaceBarWindowItem],
        barHeight: CGFloat
    ) -> WorkspaceBarSnapshot {
        let item = WorkspaceBarItem(
            id: UUID(),
            name: "Workspace",
            rawName: "Workspace",
            isFocused: true,
            tiledWindows: windows,
            floatingWindows: []
        )
        return WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [item], scratchpads: []),
            showLabels: true,
            showSystemStatsButton: false,
            backgroundOpacity: 0.6,
            barHeight: barHeight,
            accentColor: nil,
            textColor: nil
        )
    }
}
