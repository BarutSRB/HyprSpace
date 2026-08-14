// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriScrollVisibilityTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let area: WorkingAreaContext
    }

    private struct NeighborFixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let tokens: [WindowToken]
        let sourceMonitor: HiddenPlacementMonitorContext
        let neighborMonitor: HiddenPlacementMonitorContext?
        let area: WorkingAreaContext
        let orientation: Monitor.Orientation
    }

    private func makeFiveColumnFixture() -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        var tokens: [WindowToken] = []
        for index in 0 ..< 5 {
            let token = WindowToken(pid: 1, windowId: index + 1)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            tokens.append(token)
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 1000
        }
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let area = WorkingAreaContext(
            workingFrame: frame,
            fullscreenLayoutFrame: frame,
            viewFrame: frame,
            scale: 1
        )
        return Fixture(engine: engine, workspaceId: workspaceId, tokens: tokens, area: area)
    }

    private func hiddenHandles(
        _ fixture: Fixture,
        viewOffsetOverride: CGFloat?,
        settledVisibilityOffset: CGFloat?
    ) -> [WindowToken: HideSide] {
        fixture.engine.calculateLayoutWithVisibility(
            state: ViewportState(),
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.area.workingFrame,
            screenFrame: fixture.area.viewFrame,
            gaps: (horizontal: 0, vertical: 0),
            scale: 1,
            workingArea: fixture.area,
            orientation: .horizontal,
            viewOffsetOverride: viewOffsetOverride,
            settledVisibilityOffset: settledVisibilityOffset
        ).hiddenHandles
    }

    private func makeNeighborFixture(
        orientation: Monitor.Orientation,
        neighborOrigin: CGFloat?
    ) -> NeighborFixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let tokens = [
            WindowToken(pid: 1, windowId: 101),
            WindowToken(pid: 1, windowId: 102)
        ]
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for container in engine.columns(in: workspaceId) {
            switch orientation {
            case .horizontal:
                container.cachedWidth = 1_000
            case .vertical:
                container.cachedHeight = 800
            }
        }

        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let sourceMonitor = HiddenPlacementMonitorContext(
            id: .init(displayId: 101),
            frame: frame,
            visibleFrame: frame
        )
        let neighborMonitor = neighborOrigin.map {
            let neighborFrame = switch orientation {
            case .horizontal:
                CGRect(x: $0, y: 0, width: 1_000, height: 800)
            case .vertical:
                CGRect(x: 0, y: $0, width: 1_000, height: 800)
            }
            return HiddenPlacementMonitorContext(
                id: .init(displayId: 102),
                frame: neighborFrame,
                visibleFrame: neighborFrame
            )
        }
        let area = WorkingAreaContext(
            workingFrame: frame,
            fullscreenLayoutFrame: frame,
            viewFrame: frame,
            scale: 1
        )
        return NeighborFixture(
            engine: engine,
            workspaceId: workspaceId,
            tokens: tokens,
            sourceMonitor: sourceMonitor,
            neighborMonitor: neighborMonitor,
            area: area,
            orientation: orientation
        )
    }

    private func makeVerticalNeighborFixture(neighborY: CGFloat?) -> NeighborFixture {
        makeNeighborFixture(
            orientation: .vertical,
            neighborOrigin: neighborY
        )
    }

    private func makeHorizontalNeighborFixture(neighborX: CGFloat?) -> NeighborFixture {
        makeNeighborFixture(
            orientation: .horizontal,
            neighborOrigin: neighborX
        )
    }

    private func neighborLayout(
        _ fixture: NeighborFixture,
        liveOffset: CGFloat
    ) -> LayoutResult {
        let monitors = [fixture.sourceMonitor, fixture.neighborMonitor].compactMap(\.self)
        return fixture.engine.calculateLayoutWithVisibility(
            state: ViewportState(),
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.area.workingFrame,
            screenFrame: fixture.area.viewFrame,
            gaps: (horizontal: 0, vertical: 0),
            scale: 1,
            workingArea: fixture.area,
            orientation: fixture.orientation,
            hiddenPlacementMonitor: fixture.sourceMonitor,
            hiddenPlacementMonitors: monitors,
            viewOffsetOverride: liveOffset,
            settledVisibilityOffset: 0
        )
    }

    private func verticalNeighborLayout(
        _ fixture: NeighborFixture,
        liveOffset: CGFloat
    ) -> LayoutResult {
        neighborLayout(fixture, liveOffset: liveOffset)
    }

    private func horizontalNeighborLayout(
        _ fixture: NeighborFixture,
        liveOffset: CGFloat
    ) -> LayoutResult {
        neighborLayout(fixture, liveOffset: liveOffset)
    }

    func testLiveVisibleColumnStaysVisibleMidTransit() {
        let fixture = makeFiveColumnFixture()

        let handles = hiddenHandles(
            fixture,
            viewOffsetOverride: 2000,
            settledVisibilityOffset: 4000
        )

        XCTAssertNil(handles[fixture.tokens[2]])
        XCTAssertNil(handles[fixture.tokens[4]])
        XCTAssertEqual(handles[fixture.tokens[0]], .left)
        XCTAssertNil(handles[fixture.tokens[1]])
        XCTAssertNil(handles[fixture.tokens[3]])
    }

    func testRevealMarginUnparksJustOffscreenColumns() {
        let fixture = makeFiveColumnFixture()

        let handles = hiddenHandles(
            fixture,
            viewOffsetOverride: -1200,
            settledVisibilityOffset: nil
        )

        XCTAssertNil(handles[fixture.tokens[0]])
        XCTAssertEqual(handles[fixture.tokens[1]], .right)
        XCTAssertEqual(handles[fixture.tokens[2]], .right)
        XCTAssertEqual(handles[fixture.tokens[4]], .right)
    }

    func testNoSettledOffsetKeepsLiveVisibilityForGestures() {
        let fixture = makeFiveColumnFixture()

        let handles = hiddenHandles(
            fixture,
            viewOffsetOverride: 2000,
            settledVisibilityOffset: nil
        )

        XCTAssertNil(handles[fixture.tokens[2]])
        XCTAssertEqual(handles[fixture.tokens[0]], .left)
        XCTAssertEqual(handles[fixture.tokens[4]], .right)
    }

    func testVerticalLiveOverflowOntoUpperNeighborStaysHiddenDuringSettledReveal() {
        let fixture = makeVerticalNeighborFixture(neighborY: 800)
        let layout = verticalNeighborLayout(fixture, liveOffset: -200)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[0]], .right)
    }

    func testVerticalLiveOverflowOntoLowerNeighborStaysHiddenDuringSettledReveal() {
        let fixture = makeVerticalNeighborFixture(neighborY: -800)
        let layout = verticalNeighborLayout(fixture, liveOffset: 200)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[0]], .left)
    }

    func testVerticalPlaneClampedUpperOverflowStaysHiddenDuringSettledReveal() {
        let fixture = makeVerticalNeighborFixture(neighborY: 800)
        let layout = verticalNeighborLayout(fixture, liveOffset: -2_000)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[0]], .right)
    }

    func testVerticalPlaneClampedLowerOverflowStaysHiddenDuringSettledReveal() {
        let fixture = makeVerticalNeighborFixture(neighborY: -800)
        let layout = verticalNeighborLayout(fixture, liveOffset: 2_000)

        XCTAssertEqual(layout.hiddenHandles[fixture.tokens[0]], .left)
    }

    func testVerticalSettledRevealRemainsVisibleAtOpenScreenEdge() throws {
        let fixture = makeVerticalNeighborFixture(neighborY: nil)
        let layout = verticalNeighborLayout(fixture, liveOffset: -200)
        let frame = try XCTUnwrap(layout.frames[fixture.tokens[0]])

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[0]])
        XCTAssertGreaterThan(frame.maxY, fixture.area.viewFrame.maxY)
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            fixture.area.viewFrame.minY - frame.height + 1
        )
        XCTAssertLessThanOrEqual(frame.minY, fixture.area.viewFrame.maxY - 1)
    }

    func testVerticalPlaneClampedSettledRevealRemainsVisibleAtOpenScreenEdge() throws {
        let fixture = makeVerticalNeighborFixture(neighborY: nil)
        let layout = verticalNeighborLayout(fixture, liveOffset: -2_000)
        let frame = try XCTUnwrap(layout.frames[fixture.tokens[0]])

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[0]])
        XCTAssertEqual(frame.minY, fixture.area.viewFrame.maxY - 1)
    }

    func testVerticalSettledRevealRemainsVisibleAtOpenLowerScreenEdge() throws {
        let fixture = makeVerticalNeighborFixture(neighborY: nil)
        let layout = verticalNeighborLayout(fixture, liveOffset: 200)
        let frame = try XCTUnwrap(layout.frames[fixture.tokens[0]])

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[0]])
        XCTAssertLessThan(frame.minY, fixture.area.viewFrame.minY)
        XCTAssertGreaterThan(frame.maxY, fixture.area.viewFrame.minY)
    }

    func testVerticalPlaneClampedSettledRevealRemainsVisibleAtOpenLowerScreenEdge() throws {
        let fixture = makeVerticalNeighborFixture(neighborY: nil)
        let layout = verticalNeighborLayout(fixture, liveOffset: 2_000)
        let frame = try XCTUnwrap(layout.frames[fixture.tokens[0]])

        XCTAssertNil(layout.hiddenHandles[fixture.tokens[0]])
        XCTAssertEqual(
            frame.minY,
            fixture.area.viewFrame.minY - frame.height + 1
        )
    }

    func testHorizontalNeighborOverflowStaysHiddenWhileOpenEdgesRemainVisible() throws {
        let scenarios: [(neighborX: CGFloat, liveOffset: CGFloat, side: HideSide)] = [
            (1_000, -200, .right),
            (-1_000, 200, .left)
        ]

        for scenario in scenarios {
            let neighboringFixture = makeHorizontalNeighborFixture(neighborX: scenario.neighborX)
            let neighboringLayout = horizontalNeighborLayout(
                neighboringFixture,
                liveOffset: scenario.liveOffset
            )
            XCTAssertEqual(
                neighboringLayout.hiddenHandles[neighboringFixture.tokens[0]],
                scenario.side
            )

            let openFixture = makeHorizontalNeighborFixture(neighborX: nil)
            let openLayout = horizontalNeighborLayout(
                openFixture,
                liveOffset: scenario.liveOffset
            )
            let frame = try XCTUnwrap(openLayout.frames[openFixture.tokens[0]])
            XCTAssertNil(openLayout.hiddenHandles[openFixture.tokens[0]])
            if scenario.neighborX > 0 {
                XCTAssertGreaterThan(frame.maxX, openFixture.area.viewFrame.maxX)
            } else {
                XCTAssertLessThan(frame.minX, openFixture.area.viewFrame.minX)
            }
        }
    }

    func testHorizontalPlaneClampedOverflowPreservesNeighborAndOpenEdgeVisibility() throws {
        let scenarios: [(neighborX: CGFloat, liveOffset: CGFloat, side: HideSide)] = [
            (1_000, -2_000, .right),
            (-1_000, 2_000, .left)
        ]

        for scenario in scenarios {
            let neighboringFixture = makeHorizontalNeighborFixture(neighborX: scenario.neighborX)
            let neighboringLayout = horizontalNeighborLayout(
                neighboringFixture,
                liveOffset: scenario.liveOffset
            )
            XCTAssertEqual(
                neighboringLayout.hiddenHandles[neighboringFixture.tokens[0]],
                scenario.side
            )

            let openFixture = makeHorizontalNeighborFixture(neighborX: nil)
            let openLayout = horizontalNeighborLayout(
                openFixture,
                liveOffset: scenario.liveOffset
            )
            let frame = try XCTUnwrap(openLayout.frames[openFixture.tokens[0]])
            XCTAssertNil(openLayout.hiddenHandles[openFixture.tokens[0]])
            if scenario.neighborX > 0 {
                XCTAssertEqual(frame.minX, openFixture.area.viewFrame.maxX - 1)
            } else {
                XCTAssertEqual(
                    frame.minX,
                    openFixture.area.viewFrame.minX - frame.width + 1
                )
            }
        }
    }

    func testLayoutDiffReassertsHideOnSettlePass() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            layoutReason: .standard
        )

        let steady = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false
        )
        XCTAssertTrue(steady.visibilityChanges.isEmpty)

        let settle = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: true
        )
        XCTAssertEqual(settle.visibilityChanges.count, 1)
        guard case let .hide(hiddenToken, side) = settle.visibilityChanges[0] else {
            return XCTFail("expected hide re-assertion on settle pass")
        }
        XCTAssertEqual(hiddenToken, token)
        XCTAssertEqual(side, .left)
    }

    func testLayoutDiffReemitsHideForPendingPark() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            layoutReason: .standard
        )

        let pending = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false,
            pendingParkWindowIds: [token.windowId]
        )
        XCTAssertEqual(pending.visibilityChanges.count, 1)
        guard case let .hide(pendingToken, pendingSide) = pending.visibilityChanges[0] else {
            return XCTFail("expected hide re-emission for pending park")
        }
        XCTAssertEqual(pendingToken, token)
        XCTAssertEqual(pendingSide, .left)

        let confirmed = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [token: .left],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false,
            pendingParkWindowIds: [999]
        )
        XCTAssertTrue(confirmed.visibilityChanges.isEmpty)
    }

    func testAnimatedFramesNeverLeaveTheMonitorPlane() {
        let fixture = makeFiveColumnFixture()

        let layout = fixture.engine.calculateLayoutWithVisibility(
            state: ViewportState(),
            workspaceId: fixture.workspaceId,
            monitorFrame: fixture.area.workingFrame,
            screenFrame: fixture.area.viewFrame,
            gaps: (horizontal: 0, vertical: 0),
            scale: 1,
            workingArea: fixture.area,
            orientation: .horizontal,
            viewOffsetOverride: 2000,
            settledVisibilityOffset: 4000
        )

        let viewFrame = fixture.area.viewFrame
        for (token, frame) in layout.frames {
            XCTAssertGreaterThanOrEqual(
                frame.origin.x,
                viewFrame.minX - frame.width + 1,
                "window \(token.windowId) left the monitor plane at \(frame)"
            )
            XCTAssertLessThanOrEqual(
                frame.origin.x,
                viewFrame.maxX - 1,
                "window \(token.windowId) left the monitor plane at \(frame)"
            )
        }
    }

    func testVerticalWindowMoveContainmentClampsBothMonitorEdges() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let area = WorkingAreaContext(
            workingFrame: frame,
            fullscreenLayoutFrame: frame,
            viewFrame: frame,
            scale: 1
        )

        for displacement in [-600.0, 600.0] {
            let engine = NiriLayoutEngine()
            let animationTime = CACurrentMediaTime()
            engine.animationClock = AnimationClock(time: animationTime)
            let workspaceId = WorkspaceDescriptor.ID()
            let token = WindowToken(pid: 1, windowId: displacement < 0 ? 201 : 202)
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            let settledFrame = try XCTUnwrap(
                engine.calculateLayoutWithVisibility(
                    state: ViewportState(),
                    workspaceId: workspaceId,
                    monitorFrame: frame,
                    screenFrame: frame,
                    gaps: (horizontal: 0, vertical: 0),
                    scale: 1,
                    workingArea: area,
                    orientation: .vertical,
                    animationTime: animationTime
                ).frames[token]
            )

            XCTAssertTrue(
                engine.triggerMoveAnimations(
                    in: workspaceId,
                    oldFrames: [token: settledFrame.offsetBy(dx: 0, dy: displacement)],
                    newFrames: [token: settledFrame],
                    motion: .enabled,
                    yContainmentFrame: frame
                )
            )
            let animatedFrame = try XCTUnwrap(
                engine.calculateLayoutWithVisibility(
                    state: ViewportState(),
                    workspaceId: workspaceId,
                    monitorFrame: frame,
                    screenFrame: frame,
                    gaps: (horizontal: 0, vertical: 0),
                    scale: 1,
                    workingArea: area,
                    orientation: .vertical,
                    animationTime: animationTime
                ).frames[token]
            )

            XCTAssertGreaterThanOrEqual(animatedFrame.minY, frame.minY)
            XCTAssertLessThanOrEqual(animatedFrame.maxY, frame.maxY)
        }
    }

    func testVerticalWindowMoveContainmentDoesNotClampPartialViewportSweeps() throws {
        let scenarios: [(liveOffset: CGFloat, displacement: CGFloat)] = [
            (-200, 100),
            (200, -100)
        ]

        for scenario in scenarios {
            let fixture = makeVerticalNeighborFixture(neighborY: nil)
            let animationTime = CACurrentMediaTime()
            fixture.engine.animationClock = AnimationClock(time: animationTime)
            let window = try XCTUnwrap(
                fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId)
            )
            window.animateMoveFrom(
                displacement: CGPoint(x: 0, y: scenario.displacement),
                yContainmentFrame: fixture.area.viewFrame,
                clock: fixture.engine.animationClock,
                animated: true
            )

            let layout = fixture.engine.calculateLayoutWithVisibility(
                state: ViewportState(),
                workspaceId: fixture.workspaceId,
                monitorFrame: fixture.area.workingFrame,
                screenFrame: fixture.area.viewFrame,
                gaps: (horizontal: 0, vertical: 0),
                scale: 1,
                workingArea: fixture.area,
                orientation: .vertical,
                animationTime: animationTime,
                viewOffsetOverride: scenario.liveOffset
            )
            let frame = try XCTUnwrap(layout.frames[fixture.tokens[0]])

            XCTAssertNil(layout.hiddenHandles[fixture.tokens[0]])
            if scenario.liveOffset < 0 {
                XCTAssertGreaterThan(frame.maxY, fixture.area.viewFrame.maxY)
            } else {
                XCTAssertLessThan(frame.minY, fixture.area.viewFrame.minY)
            }
        }
    }

    func testLayoutDiffWithholdsShowWithoutPlacementFrame() {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let token = WindowToken(pid: 1, windowId: 1)
        let window = LayoutWindowSnapshot(
            token: token,
            constraints: WindowSizeConstraints(minSize: .zero, maxSize: .zero, isFixed: false),
            hiddenState: HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: nil,
                reason: .layoutTransient(.left)
            ),
            layoutReason: .standard
        )

        let withoutFrame = handler.layoutDiff(
            windows: [window],
            frames: [:],
            hiddenHandles: [:],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false
        )
        XCTAssertTrue(withoutFrame.visibilityChanges.isEmpty)

        let withFrame = handler.layoutDiff(
            windows: [window],
            frames: [token: CGRect(x: 100, y: 16, width: 500, height: 500)],
            hiddenHandles: [:],
            engine: engine,
            workspaceId: WorkspaceDescriptor.ID(),
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false
        )
        XCTAssertEqual(withFrame.visibilityChanges.count, 1)
        guard case let .show(shownToken) = withFrame.visibilityChanges[0] else {
            return XCTFail("expected show once a placement frame exists")
        }
        XCTAssertEqual(shownToken, token)
        XCTAssertEqual(withFrame.frameChanges.count, 1)
    }

    func testLayoutDiffProjectsEverySuspendedSlotWithExactVisibility() throws {
        let handler = NiriLayoutHandler(controller: nil)
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let visibleToken = WindowToken(pid: 31, windowId: 41)
        let hiddenToken = WindowToken(pid: 32, windowId: 42)
        let visibleOriginalToken = WindowToken(pid: 31, windowId: 401)
        let hiddenOriginalToken = WindowToken(pid: 32, windowId: 402)
        let visibleFrame = CGRect(x: 100.5, y: 200.5, width: 320, height: 240)
        let hiddenFrame = CGRect(x: -320, y: 200.5, width: 320, height: 240)
        let windows = [
            LayoutWindowSnapshot(
                token: visibleToken,
                constraints: .unconstrained,
                hiddenState: nil,
                layoutReason: .nativeFullscreen,
                nativeFullscreenOriginalToken: visibleOriginalToken
            ),
            LayoutWindowSnapshot(
                token: hiddenToken,
                constraints: .unconstrained,
                hiddenState: nil,
                layoutReason: .nativeFullscreen,
                nativeFullscreenOriginalToken: hiddenOriginalToken
            )
        ]

        let diff = handler.layoutDiff(
            windows: windows,
            frames: [visibleToken: visibleFrame, hiddenToken: hiddenFrame],
            hiddenHandles: [hiddenToken: .left],
            engine: engine,
            workspaceId: workspaceId,
            canRestoreHiddenWorkspaceWindows: true,
            reassertHidden: false
        )

        XCTAssertTrue(diff.frameChanges.isEmpty)
        XCTAssertEqual(diff.nativeFullscreenSlots.count, 2)
        let visible = try XCTUnwrap(diff.nativeFullscreenSlots[visibleOriginalToken])
        XCTAssertEqual(visible.currentToken, visibleToken)
        XCTAssertEqual(visible.frame, visibleFrame)
        XCTAssertTrue(visible.visible)
        let hidden = try XCTUnwrap(diff.nativeFullscreenSlots[hiddenOriginalToken])
        XCTAssertEqual(hidden.currentToken, hiddenToken)
        XCTAssertEqual(hidden.frame, hiddenFrame)
        XCTAssertFalse(hidden.visible)
    }
}
