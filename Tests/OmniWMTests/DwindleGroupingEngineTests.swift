// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

final class DwindleGroupingEngineTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testGroupingCollapsesSourceAndEmitsOnlyActiveMember() throws {
        let (engine, workspace, first, second) = makeTwoWindowEngine()
        let destinationId = try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace)?.id)

        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        XCTAssertEqual(engine.tileCount(in: workspace), 1)
        XCTAssertEqual(engine.windowCount(in: workspace), 2)

        let snapshot = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))
        XCTAssertEqual(snapshot.id, destinationId)
        XCTAssertEqual(snapshot.members.map(\.token), [first, second])
        XCTAssertEqual(snapshot.activeIndex, 1)
        XCTAssertEqual(engine.inactiveGroupTokens(in: workspace), [first])

        let frames = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertEqual(Set(frames.keys), [second])
        XCTAssertEqual(frames[second], CGRect(x: 12, y: 0, width: 988, height: 800))
        XCTAssertEqual(engine.tileFrame(for: first, in: workspace), screen)
        XCTAssertEqual(engine.contentFrame(for: first, in: workspace), frames[second])
    }

    func testExactActivationPreservesTileIdentity() throws {
        let (engine, workspace, first, second) = makeGroupedEngine()
        let tileId = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace)?.id)

        XCTAssertEqual(engine.activateWindowOutcome(first, in: workspace), .activated)
        XCTAssertEqual(engine.activateWindowOutcome(first, in: workspace), .selected)
        XCTAssertEqual(engine.calculateLayout(for: workspace, screen: screen).keys.sorted(by: tokenOrder), [first])
        XCTAssertEqual(engine.activateWindowOutcome(second, in: workspace), .activated)
        XCTAssertEqual(engine.activateWindowOutcome(first, in: workspace), .activated)
        XCTAssertEqual(engine.tileSnapshot(for: first, in: workspace)?.id, tileId)
        XCTAssertEqual(
            engine.activateWindowOutcome(WindowToken(pid: 90, windowId: 90), in: workspace),
            .missing
        )
    }

    func testReorderingIsBoundedWithActiveTokenAndRekeyPreservesMembership() throws {
        let (engine, workspace, first, second) = makeGroupedEngine()
        let replacement = WindowToken(pid: 22, windowId: 220)
        let tileId = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace)?.id)

        XCTAssertFalse(engine.moveGroupMember(direction: .down, in: workspace))
        XCTAssertEqual(engine.tileSnapshot(for: second, in: workspace)?.members.map(\.token), [first, second])
        XCTAssertTrue(engine.moveGroupMember(direction: .up, in: workspace))
        XCTAssertEqual(engine.tileSnapshot(for: second, in: workspace)?.members.map(\.token), [second, first])
        XCTAssertEqual(engine.activeToken(in: workspace), second)
        XCTAssertFalse(engine.moveGroupMember(direction: .up, in: workspace))
        XCTAssertEqual(engine.tileSnapshot(for: second, in: workspace)?.members.map(\.token), [second, first])
        XCTAssertTrue(engine.moveGroupMember(direction: .down, in: workspace))
        XCTAssertEqual(engine.tileSnapshot(for: second, in: workspace)?.members.map(\.token), [first, second])

        XCTAssertEqual(engine.toggleFullscreen(in: workspace), second)
        XCTAssertTrue(engine.rekeyWindow(from: second, to: replacement, in: workspace))
        let snapshot = try XCTUnwrap(engine.tileSnapshot(for: replacement, in: workspace))
        XCTAssertEqual(snapshot.id, tileId)
        XCTAssertEqual(snapshot.members.map(\.token), [first, replacement])
        XCTAssertEqual(snapshot.activeToken, replacement)
        XCTAssertTrue(engine.isWindowFullscreen(replacement, in: workspace))
        XCTAssertFalse(engine.containsWindow(second, in: workspace))
    }

    func testGroupingBetweenGroupsMovesOnlySourceActiveMember() throws {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let third = WindowToken(pid: 3, windowId: 3)
        let fourth = WindowToken(pid: 4, windowId: 4)
        _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        _ = engine.addWindow(token: third, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.setPreselection(.right, in: workspace))
        _ = engine.addWindow(token: fourth, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        _ = engine.calculateLayout(for: workspace, screen: screen)

        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        let destination = try XCTUnwrap(engine.tileSnapshot(for: fourth, in: workspace))
        XCTAssertEqual(destination.members.map(\.token), [first, second, fourth])
        XCTAssertEqual(destination.activeToken, fourth)
        XCTAssertEqual(engine.tileSnapshot(for: third, in: workspace)?.members.map(\.token), [third])
        XCTAssertEqual(engine.tileCount(in: workspace), 2)
    }

    func testUngroupExtractsActiveMemberInEveryDirectionAndPreservesState() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let (engine, workspace, first, second) = makeGroupedEngine()
            let remainingTileId = try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace)?.id)
            XCTAssertEqual(engine.toggleFullscreen(in: workspace), second)

            XCTAssertTrue(engine.ungroupWindow(direction: direction, in: workspace), direction.rawValue)
            XCTAssertEqual(engine.tileCount(in: workspace), 2, direction.rawValue)
            XCTAssertEqual(engine.tileSnapshot(for: first, in: workspace)?.id, remainingTileId, direction.rawValue)
            XCTAssertNotEqual(
                engine.tileSnapshot(for: first, in: workspace)?.id,
                engine.tileSnapshot(for: second, in: workspace)?.id,
                direction.rawValue
            )
            XCTAssertEqual(
                engine.root(for: workspace)?.splitOrientation,
                direction.dwindleOrientation,
                direction.rawValue
            )
            let extractedFirst = direction == .left || direction == .down
            XCTAssertEqual(
                extractedFirst
                    ? engine.root(for: workspace)?.firstChild()?.windowToken
                    : engine.root(for: workspace)?.secondChild()?.windowToken,
                second,
                direction.rawValue
            )
            XCTAssertTrue(engine.isWindowFullscreen(second, in: workspace), direction.rawValue)
            XCTAssertEqual(engine.activeToken(in: workspace), second, direction.rawValue)
        }
    }

    func testUngroupPlacesWindowOnRequestedSideOfFormerGroup() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let (engine, workspace, first, second) = makeTwoWindowEngine()

            XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace), direction.rawValue)
            XCTAssertTrue(engine.ungroupWindow(direction: direction, in: workspace), direction.rawValue)

            let frames = engine.calculateLayout(for: workspace, screen: screen)
            let firstFrame = try XCTUnwrap(frames[first], direction.rawValue)
            let secondFrame = try XCTUnwrap(frames[second], direction.rawValue)

            switch direction {
            case .left:
                XCTAssertLessThan(secondFrame.midX, firstFrame.midX, direction.rawValue)
            case .right:
                XCTAssertGreaterThan(secondFrame.midX, firstFrame.midX, direction.rawValue)
            case .up:
                XCTAssertGreaterThan(secondFrame.midY, firstFrame.midY, direction.rawValue)
            case .down:
                XCTAssertLessThan(secondFrame.midY, firstFrame.midY, direction.rawValue)
            }

            XCTAssertNil(
                engine.findGeometricNeighbor(from: second, direction: direction, in: workspace),
                direction.rawValue
            )
            XCTAssertEqual(
                engine.findGeometricNeighbor(from: second, direction: opposite(direction), in: workspace),
                first,
                direction.rawValue
            )
        }
    }

    func testGroupingJoinsGeometricNeighborInEveryDirectionAndPreservesDestinationIdentity() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let (engine, workspace, first, second) = makeTwoWindowEngine(neighborDirection: direction)
            let destinationTileId = try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace)?.id)
            XCTAssertEqual(
                engine.findGeometricNeighbor(from: second, direction: direction, in: workspace),
                first,
                direction.rawValue
            )

            XCTAssertTrue(engine.groupWindow(direction: direction, in: workspace), direction.rawValue)
            let snapshot = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))
            XCTAssertEqual(snapshot.id, destinationTileId, direction.rawValue)
            XCTAssertEqual(snapshot.members.map(\.token), [first, second], direction.rawValue)
            XCTAssertEqual(snapshot.activeToken, second, direction.rawValue)
            XCTAssertEqual(engine.tileCount(in: workspace), 1, direction.rawValue)
        }
    }

    func testPerMemberFullscreenAppliesOnlyWhenThatMemberIsActive() {
        let (engine, workspace, first, second) = makeGroupedEngine()
        XCTAssertEqual(engine.toggleFullscreen(in: workspace), second)
        XCTAssertEqual(engine.fullscreenTokens(in: workspace), [second])

        XCTAssertEqual(engine.activateWindowOutcome(first, in: workspace), .activated)
        let firstFrame = engine.calculateLayout(for: workspace, screen: screen)[first]
        XCTAssertFalse(engine.isWindowFullscreen(first, in: workspace))
        XCTAssertEqual(firstFrame, CGRect(x: 12, y: 0, width: 988, height: 800))

        XCTAssertEqual(engine.activateWindowOutcome(second, in: workspace), .activated)
        let secondFrame = engine.calculateLayout(for: workspace, screen: screen)[second]
        XCTAssertTrue(engine.isWindowFullscreen(second, in: workspace))
        XCTAssertEqual(secondFrame, screen)
    }

    func testRejectedGroupMutationsPreserveTopologyAndSelection() throws {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let token = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        let before = try XCTUnwrap(engine.tileSnapshot(for: token, in: workspace))

        for direction in [Direction.left, .right, .up, .down] {
            XCTAssertFalse(engine.groupWindow(direction: direction, in: workspace))
            XCTAssertFalse(engine.ungroupWindow(direction: direction, in: workspace))
        }

        XCTAssertEqual(engine.tileSnapshot(for: token, in: workspace), before)
        XCTAssertEqual(engine.activeToken(in: workspace), token)
        XCTAssertEqual(engine.tileCount(in: workspace), 1)
        XCTAssertEqual(engine.windowCount(in: workspace), 1)
    }

    func testRemovingActiveMemberChoosesSameIndexThenPreviousAtEnd() throws {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        let third = WindowToken(pid: 3, windowId: 3)
        _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        _ = engine.addWindow(token: third, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        let groupedMembers = try XCTUnwrap(
            engine.tileSnapshot(for: third, in: workspace)
        ).members.map(\.token)
        XCTAssertEqual(groupedMembers, [first, second, third])

        XCTAssertEqual(engine.activateWindowOutcome(second, in: workspace), .activated)
        engine.removeWindow(token: second, from: workspace)
        XCTAssertEqual(engine.activeToken(in: workspace), third)

        engine.removeWindow(token: third, from: workspace)
        XCTAssertEqual(engine.activeToken(in: workspace), first)
        XCTAssertEqual(engine.tileCount(in: workspace), 1)
    }

    func testSwapMovesWholeGroupedTileInEveryDirectionAndRepairsEveryMemberIndex() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let engine = DwindleLayoutEngine()
            let workspace = WorkspaceDescriptor.ID()
            let first = WindowToken(pid: 1, windowId: 1)
            let second = WindowToken(pid: 2, windowId: 2)
            let third = WindowToken(pid: 3, windowId: 3)
            _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
            _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspace, screen: screen)
            XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
            XCTAssertTrue(engine.setPreselection(direction, in: workspace))
            _ = engine.addWindow(token: third, to: workspace, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspace, screen: screen)

            let groupedId = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace)?.id)
            let neighborId = try XCTUnwrap(engine.tileSnapshot(for: third, in: workspace)?.id)
            engine.setSelectedNode(engine.findNode(for: second, in: workspace), in: workspace)
            XCTAssertEqual(
                engine.findGeometricNeighbor(from: second, direction: direction, in: workspace),
                third,
                direction.rawValue
            )
            XCTAssertEqual(engine.toggleFullscreen(in: workspace), second)

            XCTAssertEqual(
                engine.swapWindowOutcome(direction: direction, in: workspace),
                .movedWithinWorkspace,
                direction.rawValue
            )
            let grouped = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))
            XCTAssertEqual(grouped.id, groupedId, direction.rawValue)
            XCTAssertEqual(grouped.members.map(\.token), [first, second], direction.rawValue)
            XCTAssertEqual(grouped.activeToken, second, direction.rawValue)
            XCTAssertFalse(grouped.members[0].isFullscreen, direction.rawValue)
            XCTAssertTrue(grouped.members[1].isFullscreen, direction.rawValue)
            XCTAssertEqual(engine.tileSnapshot(for: first, in: workspace)?.id, groupedId, direction.rawValue)
            XCTAssertEqual(engine.tileSnapshot(for: third, in: workspace)?.id, neighborId, direction.rawValue)
            XCTAssertEqual(
                engine.findNode(for: first, in: workspace)?.id,
                engine.findNode(for: second, in: workspace)?.id,
                direction.rawValue
            )
            XCTAssertEqual(engine.activeToken(in: workspace), second, direction.rawValue)
        }
    }

    func testSwapAtWorkspaceEdgePreservesGroupedTile() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let (engine, workspace, first, second) = makeGroupedEngine()
            let before = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))

            XCTAssertEqual(
                engine.swapWindowOutcome(direction: direction, in: workspace),
                .atWorkspaceEdge,
                direction.rawValue
            )
            XCTAssertEqual(engine.tileSnapshot(for: second, in: workspace), before, direction.rawValue)
            XCTAssertEqual(engine.tileSnapshot(for: first, in: workspace), before, direction.rawValue)
            XCTAssertEqual(engine.activeToken(in: workspace), second, direction.rawValue)
            XCTAssertEqual(engine.tileCount(in: workspace), 1, direction.rawValue)
        }
    }

    func testFullscreenPresentationPreservesStructuralNeighborsForJoinAndSwap() throws {
        for direction in [Direction.left, .right, .up, .down] {
            let joinFixture = makeTwoWindowEngine(neighborDirection: direction)
            XCTAssertEqual(joinFixture.0.toggleFullscreen(in: joinFixture.1), joinFixture.3)
            _ = joinFixture.0.calculateLayout(for: joinFixture.1, screen: screen)
            XCTAssertEqual(
                joinFixture.0.findGeometricNeighbor(
                    from: joinFixture.3,
                    direction: direction,
                    in: joinFixture.1
                ),
                joinFixture.2,
                direction.rawValue
            )
            XCTAssertTrue(
                joinFixture.0.groupWindow(direction: direction, in: joinFixture.1),
                direction.rawValue
            )
            XCTAssertTrue(joinFixture.0.isWindowFullscreen(joinFixture.3, in: joinFixture.1))

            let swapFixture = makeTwoWindowEngine(neighborDirection: direction)
            XCTAssertEqual(
                swapFixture.0.activateWindowOutcome(swapFixture.2, in: swapFixture.1),
                .selected
            )
            XCTAssertEqual(swapFixture.0.toggleFullscreen(in: swapFixture.1), swapFixture.2)
            XCTAssertEqual(
                swapFixture.0.activateWindowOutcome(swapFixture.3, in: swapFixture.1),
                .selected
            )
            _ = swapFixture.0.calculateLayout(for: swapFixture.1, screen: screen)
            XCTAssertEqual(
                swapFixture.0.findGeometricNeighbor(
                    from: swapFixture.3,
                    direction: direction,
                    in: swapFixture.1
                ),
                swapFixture.2,
                direction.rawValue
            )
            XCTAssertEqual(
                swapFixture.0.swapWindowOutcome(direction: direction, in: swapFixture.1),
                .movedWithinWorkspace,
                direction.rawValue
            )
            XCTAssertTrue(swapFixture.0.isWindowFullscreen(swapFixture.2, in: swapFixture.1))
        }
    }

    func testSwapAnimationStartsAtPresentedFrames() throws {
        let (engine, workspace, first, second) = makeTwoWindowEngine()
        let firstNode = try XCTUnwrap(engine.findNode(for: first, in: workspace))
        let secondNode = try XCTUnwrap(engine.findNode(for: second, in: workspace))
        let firstTarget = try XCTUnwrap(engine.currentFrames(in: workspace)[first])
        let secondTarget = try XCTUnwrap(engine.currentFrames(in: workspace)[second])
        let firstPresented = firstTarget.offsetBy(dx: 25, dy: 15)
        let secondPresented = secondTarget.offsetBy(dx: -30, dy: -20)
        let futureStart = CACurrentMediaTime() + 100
        firstNode.animateFrom(
            oldFrame: firstPresented,
            newFrame: firstTarget,
            startTime: futureStart,
            config: engine.windowMovementAnimationConfig,
            animated: true
        )
        secondNode.animateFrom(
            oldFrame: secondPresented,
            newFrame: secondTarget,
            startTime: futureStart,
            config: engine.windowMovementAnimationConfig,
            animated: true
        )

        XCTAssertEqual(engine.swapWindowOutcome(direction: .left, in: workspace), .movedWithinWorkspace)
        var oldFrames: [WindowToken: CGRect] = [:]
        var previousTargets: [WindowToken: CGRect] = [:]
        engine.consumePendingMovementFrameSeeds(
            in: workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )

        XCTAssertEqual(oldFrames[first], firstPresented)
        XCTAssertEqual(oldFrames[second], secondPresented)
        XCTAssertEqual(previousTargets[first], firstPresented)
        XCTAssertEqual(previousTargets[second], secondPresented)
    }

    func testGroupedMinimumUsesAllMembersAndAddsRailOnce() {
        let (engine, workspace, first, second) = makeGroupedEngine()
        engine.settings.singleWindowFit = SingleWindowFit(mode: .custom, width: 400, height: 300)
        engine.updateWindowConstraints(
            for: first,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 600, height: 500),
                maxSize: .zero,
                isFixed: false
            )
        )
        engine.updateWindowConstraints(
            for: second,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 300, height: 650),
                maxSize: .zero,
                isFixed: false
            )
        )

        let frame = engine.calculateLayout(for: workspace, screen: screen)[second]
        let tileFrame = engine.tileFrame(for: second, in: workspace)
        XCTAssertEqual(frame?.width ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(frame?.height ?? 0, 650, accuracy: 0.5)
        XCTAssertEqual(tileFrame?.width ?? 0, 612, accuracy: 0.5)

        XCTAssertEqual(engine.activateWindowOutcome(first, in: workspace), .activated)
        let switchedFrame = engine.calculateLayout(for: workspace, screen: screen)[first]
        XCTAssertEqual(engine.tileFrame(for: first, in: workspace), tileFrame)
        XCTAssertEqual(switchedFrame, frame)
    }

    func testGroupingAnimationStartsAtMovedWindowPresentedFrame() throws {
        let (engine, workspace, _, second) = makeTwoWindowEngine()
        let sourceFrame = try XCTUnwrap(engine.currentFrames(in: workspace)[second])

        XCTAssertTrue(engine.groupWindow(direction: .left, in: workspace))
        var previousTargets = engine.currentFrames(in: workspace)
        var oldFrames = engine.presentedFrames(in: workspace, at: 100)
        engine.consumePendingMovementFrameSeeds(
            in: workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        let newFrames = engine.calculateLayout(for: workspace, screen: screen)
        engine.animateWindowMovements(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargets,
            newFrames: newFrames,
            in: workspace,
            startTime: 100,
            motion: .enabled
        )

        XCTAssertEqual(oldFrames[second], sourceFrame)
        XCTAssertEqual(previousTargets[second], sourceFrame)
        XCTAssertEqual(
            engine.calculateAnimatedFrames(baseFrames: newFrames, in: workspace, at: 100)[second],
            sourceFrame
        )
    }

    func testUngroupAnimationStartsAtExtractedWindowPresentedFrame() throws {
        let (engine, workspace, _, second) = makeGroupedEngine()
        _ = engine.calculateLayout(for: workspace, screen: screen)
        var completedOldFrames = engine.presentedFrames(in: workspace, at: 99)
        var completedTargetFrames = engine.currentFrames(in: workspace)
        engine.consumePendingMovementFrameSeeds(
            in: workspace,
            oldFrames: &completedOldFrames,
            previousTargetFrames: &completedTargetFrames
        )
        let groupedFrame = try XCTUnwrap(engine.currentFrames(in: workspace)[second])

        XCTAssertTrue(engine.ungroupWindow(direction: .left, in: workspace))
        var previousTargets = engine.currentFrames(in: workspace)
        var oldFrames = engine.presentedFrames(in: workspace, at: 100)
        engine.consumePendingMovementFrameSeeds(
            in: workspace,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargets
        )
        let newFrames = engine.calculateLayout(for: workspace, screen: screen)
        engine.animateWindowMovements(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargets,
            newFrames: newFrames,
            in: workspace,
            startTime: 100,
            motion: .enabled
        )

        XCTAssertEqual(oldFrames[second], groupedFrame)
        XCTAssertEqual(previousTargets[second], groupedFrame)
        XCTAssertEqual(
            engine.calculateAnimatedFrames(baseFrames: newFrames, in: workspace, at: 100)[second],
            groupedFrame
        )
    }

    private func makeTwoWindowEngine() -> (
        DwindleLayoutEngine,
        WorkspaceDescriptor.ID,
        WindowToken,
        WindowToken
    ) {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        return (engine, workspace, first, second)
    }

    private func makeTwoWindowEngine(
        neighborDirection: Direction
    ) -> (
        DwindleLayoutEngine,
        WorkspaceDescriptor.ID,
        WindowToken,
        WindowToken
    ) {
        let engine = DwindleLayoutEngine()
        let workspace = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.setPreselection(preselection(for: neighborDirection), in: workspace))
        _ = engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        return (engine, workspace, first, second)
    }

    private func makeGroupedEngine() -> (
        DwindleLayoutEngine,
        WorkspaceDescriptor.ID,
        WindowToken,
        WindowToken
    ) {
        let result = makeTwoWindowEngine()
        XCTAssertTrue(result.0.groupWindow(direction: .left, in: result.1))
        return result
    }

    private func tokenOrder(_ lhs: WindowToken, _ rhs: WindowToken) -> Bool {
        lhs.windowId < rhs.windowId
    }

    private func opposite(_ direction: Direction) -> Direction {
        switch direction {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    private func preselection(for neighborDirection: Direction) -> Direction {
        opposite(neighborDirection)
    }
}
