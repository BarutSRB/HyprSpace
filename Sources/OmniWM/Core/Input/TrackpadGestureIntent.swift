// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

enum TrackpadGestureMode: Equatable {
    case columnScroll
    case workspaceSwitch(axis: WorkspaceSwipeAxis)
}

enum TrackpadGestureIntent {
    struct Config: Equatable {
        var columnScrollEnabled: Bool
        var columnScrollFingerCount: Int
        var workspaceSwipeEnabled: Bool
        var workspaceSwipeFingerCount: Int
        var workspaceSwipeAxis: WorkspaceSwipeAxis
    }

    static let workspaceSwipeTriggerUnits: CGFloat = 140.0
    static let workspaceSwipeReleaseVelocityFloor: Double = 800.0

    static func allowsGestureStart(_ config: Config, fingerCount: Int) -> Bool {
        (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func hasCandidateMode(_ config: Config, fingerCount: Int, columnContextAvailable: Bool) -> Bool {
        (config.columnScrollEnabled && fingerCount == config.columnScrollFingerCount && columnContextAvailable)
            || (config.workspaceSwipeEnabled && fingerCount == config.workspaceSwipeFingerCount)
    }

    static func resolveMode(
        _ config: Config,
        fingerCount: Int,
        cumulativeX: CGFloat,
        cumulativeY: CGFloat,
        columnScrollAxis: WorkspaceSwipeAxis,
        columnContextAvailable: Bool
    ) -> TrackpadGestureMode? {
        let dominantAxis: WorkspaceSwipeAxis = abs(cumulativeX) > abs(cumulativeY) ? .horizontal : .vertical
        let columnCandidate = config.columnScrollEnabled
            && fingerCount == config.columnScrollFingerCount
            && columnContextAvailable
        if columnCandidate, dominantAxis == columnScrollAxis {
            return .columnScroll
        }
        guard config.workspaceSwipeEnabled, fingerCount == config.workspaceSwipeFingerCount else { return nil }
        let axis = if columnCandidate {
            switch columnScrollAxis {
            case .horizontal: WorkspaceSwipeAxis.vertical
            case .vertical: WorkspaceSwipeAxis.horizontal
            }
        } else {
            config.workspaceSwipeAxis
        }
        guard axis == dominantAxis else { return nil }
        return .workspaceSwitch(axis: axis)
    }

    static func isNextWorkspace(
        axis: WorkspaceSwipeAxis,
        displacement: CGFloat,
        naturalDirection: Bool
    ) -> Bool? {
        guard displacement != 0 else { return nil }
        switch axis {
        case .horizontal:
            return naturalDirection ? displacement < 0 : displacement > 0
        case .vertical:
            return naturalDirection ? displacement > 0 : displacement < 0
        }
    }

    static func releaseFlickDisplacement(cumulativeAxisUnits: CGFloat, velocity: Double) -> CGFloat? {
        guard abs(velocity) >= workspaceSwipeReleaseVelocityFloor else { return nil }
        if cumulativeAxisUnits != 0, (velocity > 0) != (cumulativeAxisUnits > 0) {
            return nil
        }
        return CGFloat(velocity)
    }
}
