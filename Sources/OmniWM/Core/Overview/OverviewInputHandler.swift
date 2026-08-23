// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation

@MainActor
final class OverviewInputHandler {
    enum KeyAction: Equatable {
        case dismissSelection
        case activateSelection
        case closeSelection
        case navigate(Direction)
        case cycleSelection(forward: Bool)
        case deleteBackward
        case appendToSearch(String)
        case consume
    }

    struct KeyHandlingResult: Equatable {
        let action: KeyAction
        let shouldConsume: Bool
    }

    private enum KeyCode {
        static let escape = UInt16(kVK_Escape)
        static let returnKey = UInt16(kVK_Return)
        static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
        static let leftArrow = UInt16(kVK_LeftArrow)
        static let rightArrow = UInt16(kVK_RightArrow)
        static let downArrow = UInt16(kVK_DownArrow)
        static let upArrow = UInt16(kVK_UpArrow)
        static let tab = UInt16(kVK_Tab)
        static let delete = UInt16(kVK_Delete)
        static let w = UInt16(kVK_ANSI_W)
    }

    private weak var controller: OverviewController?

    var searchQuery: String = ""

    init(controller: OverviewController) {
        self.controller = controller
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        guard controller.state.isOpen else { return false }

        let result = Self.keyHandlingResult(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            searchQuery: searchQuery,
            isRepeat: event.isARepeat
        )
        guard result.shouldConsume else { return false }

        switch controller.state {
        case .closed:
            return false
        case .closing:
            return true
        case .opening:
            switch result.action {
            case .dismissSelection:
                controller.dismissToSelection(animated: true)
            case .activateSelection:
                controller.dismissToSelection(animated: true)
            case .closeSelection,
                 .navigate,
                 .cycleSelection,
                 .deleteBackward,
                 .appendToSearch,
                 .consume:
                break
            }
            return true
        case .open:
            break
        }

        switch result.action {
        case .dismissSelection:
            controller.dismissToSelection(animated: true)
        case .activateSelection:
            controller.activateSelectedWindow()
        case .closeSelection:
            controller.closeSelectedWindow()
        case let .navigate(direction):
            controller.navigateSelection(direction)
        case let .cycleSelection(forward):
            controller.cycleSelection(forward: forward)
        case .deleteBackward:
            if !searchQuery.isEmpty {
                searchQuery = String(searchQuery.dropLast())
                controller.updateSearchQuery(searchQuery)
            }
        case let .appendToSearch(text):
            searchQuery += text
            controller.updateSearchQuery(searchQuery)
        case .consume:
            break
        }
        return true
    }

    static func keyHandlingResult(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        searchQuery _: String,
        isRepeat: Bool = false
    ) -> KeyHandlingResult {
        let relevantModifiers = modifierFlags.intersection([.shift, .command, .control, .option])

        switch keyCode {
        case KeyCode.escape:
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .dismissSelection, shouldConsume: true)
        case KeyCode.returnKey,
             KeyCode.keypadEnter:
            guard relevantModifiers.isEmpty else { break }
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .activateSelection, shouldConsume: true)
        case KeyCode.leftArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.left), shouldConsume: true)
        case KeyCode.rightArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.right), shouldConsume: true)
        case KeyCode.downArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.down), shouldConsume: true)
        case KeyCode.upArrow:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .navigate(.up), shouldConsume: true)
        case KeyCode.tab:
            guard relevantModifiers.isEmpty || relevantModifiers == .shift else { break }
            return .init(
                action: .cycleSelection(forward: !relevantModifiers.contains(.shift)),
                shouldConsume: true
            )
        case KeyCode.delete:
            guard relevantModifiers.isEmpty else { break }
            return .init(action: .deleteBackward, shouldConsume: true)
        case KeyCode.w:
            guard relevantModifiers == .command else { break }
            guard !isRepeat else { return .init(action: .consume, shouldConsume: true) }
            return .init(action: .closeSelection, shouldConsume: true)
        default:
            if relevantModifiers.intersection([.command, .control, .option]).isEmpty,
               let charactersIgnoringModifiers,
               let character = charactersIgnoringModifiers.first,
               charactersIgnoringModifiers.count == 1,
               (character.isLetter || character.isNumber || character == " ")
            {
                return .init(action: .appendToSearch(String(character)), shouldConsume: true)
            }
        }

        return .init(action: .consume, shouldConsume: true)
    }

    func reset() {
        searchQuery = ""
    }
}
