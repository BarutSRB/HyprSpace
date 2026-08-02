// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

enum MouseMoveModifierKey: String, CaseIterable, Codable {
    case off
    case option
    case control
    case command
    case controlOption
    case optionCommand
    case controlCommand
    case controlOptionCommand

    var displayName: String {
        switch self {
        case .off: "Off"
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        case .controlOption: "Control+Option"
        case .optionCommand: "Option+Command"
        case .controlCommand: "Control+Command"
        case .controlOptionCommand: "Control+Option+Command"
        }
    }
}
