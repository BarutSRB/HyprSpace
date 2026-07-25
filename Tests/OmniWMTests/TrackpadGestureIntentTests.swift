// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class TrackpadGestureIntentTests: XCTestCase {
    private func makeConfig(
        columnEnabled: Bool = true,
        columnFingers: Int = 3,
        workspaceEnabled: Bool = true,
        workspaceFingers: Int = 3,
        workspaceAxis: WorkspaceSwipeAxis = .vertical
    ) -> TrackpadGestureIntent.Config {
        TrackpadGestureIntent.Config(
            columnScrollEnabled: columnEnabled,
            columnScrollFingerCount: columnFingers,
            workspaceSwipeEnabled: workspaceEnabled,
            workspaceSwipeFingerCount: workspaceFingers,
            workspaceSwipeAxis: workspaceAxis
        )
    }

    func testGestureStartAllowedForEitherEnabledFingerCount() {
        let config = makeConfig(columnFingers: 3, workspaceFingers: 4)
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 2))
    }

    func testGestureStartRejectedWhenBothGesturesDisabled() {
        let config = makeConfig(columnEnabled: false, workspaceEnabled: false)
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
    }

    func testGestureStartRespectsPerGestureEnablement() {
        let config = makeConfig(columnEnabled: false, columnFingers: 3, workspaceEnabled: true, workspaceFingers: 4)
        XCTAssertFalse(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 3))
        XCTAssertTrue(TrackpadGestureIntent.allowsGestureStart(config, fingerCount: 4))
    }

    func testCandidateModeRejectsColumnOnlyCountOverDwindleContext() {
        let config = makeConfig(workspaceEnabled: false)
        XCTAssertFalse(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: false))
        XCTAssertTrue(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: true))
    }

    func testCandidateModeAcceptsWorkspaceCountWithoutColumnContext() {
        let config = makeConfig(columnEnabled: false)
        XCTAssertTrue(TrackpadGestureIntent.hasCandidateMode(config, fingerCount: 3, columnContextAvailable: false))
    }

    func testResolveModePrefersColumnScrollForSharedCountHorizontalSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .columnScroll)
    }

    func testResolveModeResolvesWorkspaceSwitchForSharedCountVerticalSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 10,
            cumulativeY: 50,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeForcesVerticalForSharedCountEvenWithHorizontalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceAxis: .horizontal),
            fingerCount: 3,
            cumulativeX: 10,
            cumulativeY: 50,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilForColumnCountVerticalSwipeWithDistinctCounts() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4),
            fingerCount: 3,
            cumulativeX: 10,
            cumulativeY: 50,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeReturnsNilForWorkspaceCountOffAxisSwipe() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .vertical),
            fingerCount: 4,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeResolvesWorkspaceSwitchWithoutColumnContext() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 10,
            cumulativeY: 50,
            columnScrollAxis: .horizontal,
            columnContextAvailable: false
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilForColumnSwipeWithoutColumnContext() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceEnabled: false),
            fingerCount: 3,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .horizontal,
            columnContextAvailable: false
        )
        XCTAssertNil(mode)
    }

    func testResolveModeHonorsHorizontalAxisWhenCountsDiffer() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .horizontal),
            fingerCount: 4,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testAxisTieResolvesAsVertical() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 30,
            cumulativeY: 30,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .vertical))
    }

    func testResolveModeReturnsNilWithNoCandidates() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(columnEnabled: false, workspaceEnabled: false),
            fingerCount: 3,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .horizontal,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModePrefersColumnScrollForSharedCountVerticalSwipeOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 10,
            cumulativeY: 50,
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .columnScroll)
    }

    func testResolveModeResolvesHorizontalWorkspaceSwitchForSharedCountOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(),
            fingerCount: 3,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testResolveModeReturnsNilForColumnCountHorizontalSwipeWithDistinctCountsOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4),
            fingerCount: 3,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertNil(mode)
    }

    func testResolveModeHonorsConfiguredWorkspaceAxisWithDistinctCountsOnVerticalAxis() {
        let mode = TrackpadGestureIntent.resolveMode(
            makeConfig(workspaceFingers: 4, workspaceAxis: .horizontal),
            fingerCount: 4,
            cumulativeX: 50,
            cumulativeY: 10,
            columnScrollAxis: .vertical,
            columnContextAvailable: true
        )
        XCTAssertEqual(mode, .workspaceSwitch(axis: .horizontal))
    }

    func testNaturalHorizontalSwipeLeftIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: -1, naturalDirection: true),
            true
        )
    }

    func testNaturalHorizontalSwipeRightIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: 1, naturalDirection: true),
            false
        )
    }

    func testInvertedHorizontalSwipeRightIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: 1, naturalDirection: false),
            true
        )
    }

    func testInvertedHorizontalSwipeLeftIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .horizontal, displacement: -1, naturalDirection: false),
            false
        )
    }

    func testNaturalVerticalSwipeUpIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 1, naturalDirection: true),
            true
        )
    }

    func testNaturalVerticalSwipeDownIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: -1, naturalDirection: true),
            false
        )
    }

    func testInvertedVerticalSwipeDownIsNext() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: -1, naturalDirection: false),
            true
        )
    }

    func testInvertedVerticalSwipeUpIsPrevious() {
        XCTAssertEqual(
            TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 1, naturalDirection: false),
            false
        )
    }

    func testZeroDisplacementYieldsNoDirection() {
        XCTAssertNil(TrackpadGestureIntent.isNextWorkspace(axis: .vertical, displacement: 0, naturalDirection: true))
    }

    func testReleaseFlickFiresWhenVelocityExceedsFloor() {
        XCTAssertEqual(
            TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: 900),
            CGFloat(900)
        )
    }

    func testReleaseFlickRejectedBelowVelocityFloor() {
        XCTAssertNil(TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: 700))
    }

    func testReleaseFlickRejectedWhenVelocityOpposesCumulativeTravel() {
        XCTAssertNil(TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 60, velocity: -900))
    }

    func testReleaseFlickAllowedWithZeroCumulativeTravel() {
        XCTAssertEqual(
            TrackpadGestureIntent.releaseFlickDisplacement(cumulativeAxisUnits: 0, velocity: -900),
            CGFloat(-900)
        )
    }
}
