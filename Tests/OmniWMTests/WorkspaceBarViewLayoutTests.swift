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
                projection: WorkspaceBarProjection(items: [item], scratchpad: nil),
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
                        onActivateScratchpad: {}
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
}
