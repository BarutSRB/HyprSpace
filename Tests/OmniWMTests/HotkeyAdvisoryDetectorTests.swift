// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import XCTest

final class HotkeyAdvisoryDetectorTests: XCTestCase {
    private let advisoryID = "hotkey-advisory:openCommandPalette"

    @MainActor
    func testAdvisoryFiresOnceForEnabledSystemChordAtDefault() throws {
        let defaults = HotkeyBindingRegistry.defaults()
        let defaultChord = try XCTUnwrap(
            defaults.first(where: { $0.id == "openCommandPalette" })?.binding.chordBinding
        )
        var queried: [KeyBinding] = []

        let issues = HotkeyAdvisoryDetector.issues(
            currentBindings: defaults,
            defaults: defaults,
            systemHotkeyQuery: { binding in
                queried.append(binding)
                return true
            }
        )

        let advisory = try XCTUnwrap(issues.first { $0.id == advisoryID })
        XCTAssertEqual(queried, [defaultChord])
        XCTAssertTrue(advisory.message.contains("Select next source in Input menu"))
        XCTAssertFalse(advisory.message.contains("previous"))
    }

    @MainActor
    func testAdvisorySuppressedWhenSystemChordIsDisabledOrUnknown() {
        let defaults = HotkeyBindingRegistry.defaults()
        let disabled = HotkeyAdvisoryDetector.issues(
            currentBindings: defaults,
            defaults: defaults,
            systemHotkeyQuery: { _ in false }
        )
        let unknown = HotkeyAdvisoryDetector.issues(
            currentBindings: defaults,
            defaults: defaults,
            systemHotkeyQuery: { _ in nil }
        )

        XCTAssertFalse(disabled.contains { $0.id == advisoryID })
        XCTAssertFalse(unknown.contains { $0.id == advisoryID })
    }

    @MainActor
    func testAdvisorySuppressedWhenUnassignedWithoutQueryingSystem() {
        let defaults = HotkeyBindingRegistry.defaults()
        var current = defaults
        if let index = current.firstIndex(where: { $0.id == "openCommandPalette" }) {
            current[index].binding = .unassigned
        }
        var queryCount = 0
        let issues = HotkeyAdvisoryDetector.issues(
            currentBindings: current,
            defaults: defaults,
            systemHotkeyQuery: { _ in
                queryCount += 1
                return true
            }
        )

        XCTAssertFalse(issues.contains { $0.id == advisoryID })
        XCTAssertEqual(queryCount, 0)
    }

    @MainActor
    func testAdvisorySuppressedWhenAssignedDifferentChordWithoutQueryingSystem() {
        let defaults = HotkeyBindingRegistry.defaults()
        var current = defaults
        if let index = current.firstIndex(where: { $0.id == "openCommandPalette" }) {
            current[index].binding = .chord(
                KeyBinding(
                    keyCode: UInt32(kVK_ANSI_P),
                    modifiers: UInt32(controlKey | optionKey)
                )
            )
        }
        var queryCount = 0
        let issues = HotkeyAdvisoryDetector.issues(
            currentBindings: current,
            defaults: defaults,
            systemHotkeyQuery: { _ in
                queryCount += 1
                return true
            }
        )

        XCTAssertFalse(issues.contains { $0.id == advisoryID })
        XCTAssertEqual(queryCount, 0)
    }

    @MainActor
    func testNoBindingsNoAdvisoryAndNoSystemQuery() {
        var queryCount = 0
        let issues = HotkeyAdvisoryDetector.issues(
            currentBindings: [],
            defaults: HotkeyBindingRegistry.defaults(),
            systemHotkeyQuery: { _ in
                queryCount += 1
                return true
            }
        )

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(queryCount, 0)
    }

    @MainActor
    func testRawSnapshotMatchesEnabledExactCarbonChord() {
        let binding = commandPaletteChord()
        let snapshot = snapshot([
            entry(keyCode: binding.keyCode, modifiers: UInt32(controlKey | optionKey), enabled: true)
        ])

        XCTAssertEqual(HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot), true)
        XCTAssertEqual(UInt32(controlKey | optionKey), 6_144)
    }

    @MainActor
    func testRawSnapshotIgnoresDisabledAndDifferentChords() {
        let binding = commandPaletteChord()
        let snapshot = snapshot([
            entry(keyCode: binding.keyCode, modifiers: binding.modifiers, enabled: false),
            entry(keyCode: UInt32(kVK_ANSI_P), modifiers: binding.modifiers, enabled: true),
            entry(keyCode: binding.keyCode, modifiers: UInt32(controlKey), enabled: true)
        ])

        XCTAssertEqual(HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot), false)
    }

    @MainActor
    func testRawSnapshotDoesNotTreatPreferencesModifierEncodingAsCarbon() {
        let binding = commandPaletteChord()
        let snapshot = snapshot([
            entry(keyCode: binding.keyCode, modifiers: 786_432, enabled: true)
        ])

        XCTAssertEqual(HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot), false)
    }

    @MainActor
    func testRawSnapshotMalformedEntryWithoutMatchIsUnknown() {
        let binding = commandPaletteChord()
        let malformed: [String: Any] = [
            kHISymbolicHotKeyCode: NSNumber(value: binding.keyCode)
        ]
        let snapshot = snapshot([
            entry(keyCode: UInt32(kVK_ANSI_P), modifiers: binding.modifiers, enabled: true),
            malformed
        ])

        XCTAssertNil(HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot))
    }

    @MainActor
    func testRawSnapshotReturnsMatchBeforeLaterMalformedEntry() {
        let binding = commandPaletteChord()
        let malformed: [String: Any] = [
            kHISymbolicHotKeyCode: NSNumber(value: binding.keyCode)
        ]
        let snapshot = snapshot([
            entry(keyCode: binding.keyCode, modifiers: binding.modifiers, enabled: true),
            malformed
        ])

        XCTAssertEqual(HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot), true)
    }

    @MainActor
    func testRawSnapshotRejectsNumberAsBooleanAndBooleanAsNumber() {
        let binding = commandPaletteChord()
        let numberAsBoolean: [String: Any] = [
            kHISymbolicHotKeyCode: NSNumber(value: binding.keyCode),
            kHISymbolicHotKeyModifiers: NSNumber(value: binding.modifiers),
            kHISymbolicHotKeyEnabled: NSNumber(value: 1)
        ]
        let booleanAsNumber: [String: Any] = [
            kHISymbolicHotKeyCode: kCFBooleanTrue as Any,
            kHISymbolicHotKeyModifiers: NSNumber(value: binding.modifiers),
            kHISymbolicHotKeyEnabled: kCFBooleanTrue as Any
        ]

        XCTAssertNil(
            HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot([numberAsBoolean]))
        )
        XCTAssertNil(
            HotkeyAdvisoryDetector.enabledSystemHotkeyMatches(binding, in: snapshot([booleanAsNumber]))
        )
    }

    private func commandPaletteChord() -> KeyBinding {
        KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    }

    private func entry(keyCode: UInt32, modifiers: UInt32, enabled: Bool) -> [String: Any] {
        [
            kHISymbolicHotKeyCode: NSNumber(value: keyCode),
            kHISymbolicHotKeyModifiers: NSNumber(value: modifiers),
            kHISymbolicHotKeyEnabled: enabled ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
    }

    private func snapshot(_ entries: [[String: Any]]) -> CFArray {
        entries as CFArray
    }
}
