// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

enum Direction: String, Codable {
    case left, right, up, down

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }

    func primaryStep(for orientation: Monitor.Orientation) -> Int? {
        switch orientation {
        case .horizontal:
            switch self {
            case .right: 1
            case .left: -1
            case .up,
                 .down: nil
            }
        case .vertical:
            switch self {
            case .up: 1
            case .down: -1
            case .left,
                 .right: nil
            }
        }
    }

    func secondaryStep(for orientation: Monitor.Orientation) -> Int? {
        switch orientation {
        case .horizontal:
            switch self {
            case .up: 1
            case .down: -1
            case .left,
                 .right: nil
            }
        case .vertical:
            switch self {
            case .right: 1
            case .left: -1
            case .up,
                 .down: nil
            }
        }
    }
}

enum WindowMoveOutcome {
    case movedWithinWorkspace
    case atWorkspaceEdge
    case blocked
}

extension ScrollModifierKey {
    var cgEventFlag: CGEventFlags {
        switch self {
        case .optionShift: [.maskAlternate, .maskShift]
        case .controlShift: [.maskControl, .maskShift]
        }
    }
}

extension MouseResizeModifierKey {
    var cgEventFlag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        case .shift: .maskShift
        case .controlOption: [.maskControl, .maskAlternate]
        case .optionCommand: [.maskAlternate, .maskCommand]
        case .optionShift: [.maskAlternate, .maskShift]
        case .controlCommand: [.maskControl, .maskCommand]
        case .controlShift: [.maskControl, .maskShift]
        case .commandShift: [.maskCommand, .maskShift]
        case .controlOptionCommand: [.maskControl, .maskAlternate, .maskCommand]
        case .controlOptionShift: [.maskControl, .maskAlternate, .maskShift]
        case .optionCommandShift: [.maskAlternate, .maskCommand, .maskShift]
        case .controlCommandShift: [.maskControl, .maskCommand, .maskShift]
        case .controlOptionCommandShift: [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        }
    }
}
