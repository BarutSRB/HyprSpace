// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

final class HotkeyChordTests: XCTestCase {
    func testHotkeyTriggerRejectsSequenceText() {
        XCTAssertNil(HotkeyTrigger.fromHumanReadable("Option+A, B"))
        XCTAssertNil(HotkeyTrigger.fromHumanReadable("Leader, A"))
    }

    func testHotkeyTriggerRoundTripsChordEncoding() throws {
        let trigger = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let data = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(HotkeyTrigger.self, from: data)

        XCTAssertEqual(decoded, trigger)
    }

    func testChordConflictDetectionUsesOnlyChordBindings() {
        let lhs = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let same = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)))
        let different = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey)))

        XCTAssertTrue(lhs.conflicts(with: same))
        XCTAssertFalse(lhs.conflicts(with: different))
        XCTAssertFalse(lhs.conflicts(with: .unassigned))
    }

    func testHyperDisplaySugarRoundTrips() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: KeySymbolMapper.hyperModifiers)

        XCTAssertEqual(binding.humanReadableString, "Hyper+1")
        XCTAssertEqual(binding.displayString, "Hyper+1")
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Hyper+1"), binding)
    }

    func testHyperAliasEqualsLiteralFourModifiersByDefault() {
        XCTAssertEqual(
            KeySymbolMapper.fromHumanReadable("Control+Option+Shift+Command+1"),
            KeySymbolMapper.fromHumanReadable("Hyper+1")
        )
    }

    func testConfiguredHyperAliasEqualsLiteralThreeModifiers() throws {
        try withHyperComposition("Control+Option+Command") {
            XCTAssertEqual(
                KeySymbolMapper.fromHumanReadable("Control+Option+Command+1"),
                KeySymbolMapper.fromHumanReadable("Hyper+1")
            )
        }
    }

    func testConfiguredHyperShiftAliasEqualsLiteralFourModifiers() throws {
        try withHyperComposition("Control+Option+Command") {
            XCTAssertEqual(
                KeySymbolMapper.fromHumanReadable("Control+Option+Shift+Command+1"),
                KeySymbolMapper.fromHumanReadable("Hyper+Shift+1")
            )
        }
    }

    func testConfiguredHyperShiftDisplaySugarRoundTrips() throws {
        try withHyperComposition("Control+Option+Command") {
            let binding = KeyBinding(
                keyCode: UInt32(kVK_ANSI_1),
                modifiers: KeySymbolMapper.hyperModifiers | UInt32(shiftKey)
            )

            XCTAssertEqual(binding.humanReadableString, "Hyper+Shift+1")
            XCTAssertEqual(binding.displayString, "Hyper+⇧1")
            XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Hyper+Shift+1"), binding)
        }
    }

    func testHyperKeyModifiersParsingAndValidation() {
        XCTAssertEqual(
            HyperKeyModifiers.fromHumanReadable("Control+Option+Command")?.carbonMask,
            UInt32(controlKey | optionKey | cmdKey)
        )
        XCTAssertEqual(
            HyperKeyModifiers.fromHumanReadable("command + shift")?.carbonMask,
            UInt32(cmdKey | shiftKey)
        )
        XCTAssertNil(HyperKeyModifiers.fromHumanReadable("Control"))
        XCTAssertNil(HyperKeyModifiers.fromHumanReadable(""))
        XCTAssertNil(HyperKeyModifiers.fromHumanReadable("Hyper+Command"))
        XCTAssertNil(HyperKeyModifiers.fromHumanReadable("Control+Q"))
        XCTAssertNil(HyperKeyModifiers(carbonMask: UInt32(shiftKey)))
    }

    func testHyperKeyModifiersCodableRoundTrips() throws {
        let modifiers = try XCTUnwrap(HyperKeyModifiers.fromHumanReadable("Control+Option+Command"))
        let data = try JSONEncoder().encode(modifiers)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Control+Option+Command\"")
        XCTAssertEqual(try JSONDecoder().decode(HyperKeyModifiers.self, from: data), modifiers)
        XCTAssertThrowsError(try JSONDecoder().decode(HyperKeyModifiers.self, from: Data(#""Control""#.utf8)))
    }

    func testRetargetingHyperChordsFollowsComposition() throws {
        defer { KeySymbolMapper.setHyperKeyModifiers(.default) }

        let threeModifiers = try XCTUnwrap(HyperKeyModifiers.fromHumanReadable("Control+Option+Command"))
        let hyperBound = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "focus.left",
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: KeySymbolMapper.hyperModifiers)
        ))
        let literalBound = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "focus.right",
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))
        ))

        let retargeted = HotkeyBindingRegistry.retargetingHyperChords([hyperBound, literalBound], to: threeModifiers)

        XCTAssertEqual(
            retargeted[0].binding,
            .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        )
        XCTAssertEqual(retargeted[1].binding, literalBound.binding)

        let restored = HotkeyBindingRegistry.retargetingHyperChords(retargeted, to: .default)
        XCTAssertEqual(restored[0].binding, hyperBound.binding)
        XCTAssertEqual(restored[1].binding, literalBound.binding)
    }

    func testTOMLDecodeAppliesHyperCompositionBeforeHotkeys() throws {
        defer { KeySymbolMapper.setHyperKeyModifiers(.default) }
        let toml = """
        [general]
        hyperKeyModifiers = "Control+Option+Command"

        [[hotkeys]]
        binding = "Hyper+H"
        id = "focus.left"

        [[hotkeys]]
        binding = "Hyper+Shift+H"
        id = "focus.right"
        """

        let export = try SettingsTOMLCodec.decode(Data(toml.utf8))

        XCTAssertEqual(export.hyperKeyModifiers.humanReadableString, "Control+Option+Command")
        let left = try XCTUnwrap(export.hotkeyBindings.first { $0.id == "focus.left" })
        XCTAssertEqual(
            left.binding,
            .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey | cmdKey)))
        )
        let right = try XCTUnwrap(export.hotkeyBindings.first { $0.id == "focus.right" })
        XCTAssertEqual(
            right.binding,
            .chord(KeyBinding(
                keyCode: UInt32(kVK_ANSI_H),
                modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
            ))
        )
    }

    private func withHyperComposition(_ composition: String, _ body: () throws -> Void) throws {
        let modifiers = try XCTUnwrap(HyperKeyModifiers.fromHumanReadable(composition))
        KeySymbolMapper.setHyperKeyModifiers(modifiers)
        defer { KeySymbolMapper.setHyperKeyModifiers(.default) }
        try body()
    }

    func testKeyBindingConflictRequiresIdenticalKeyAndModifiers() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let same = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let otherModifiers = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        let otherKey = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey))

        XCTAssertTrue(binding.conflicts(with: same))
        XCTAssertFalse(binding.conflicts(with: otherModifiers))
        XCTAssertFalse(binding.conflicts(with: otherKey))
        XCTAssertFalse(binding.conflicts(with: .unassigned))
    }

    func testRegistrationPlanMarksDuplicateChordBindings() {
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let bindings = [
            HotkeyBinding(id: "focus.left", command: .focus(.left), binding: binding),
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: binding)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.failures[.focus(.left)], .duplicateBinding)
        XCTAssertEqual(plan.failures[.focus(.right)], .duplicateBinding)
        XCTAssertTrue(plan.registrations.isEmpty)
    }

    func testRegistrationPlanRegistersHyperBindingLiterally() {
        let hyperBinding = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: KeySymbolMapper.hyperModifiers)
        let bindings = [
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: hyperBinding)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(
            plan.registrations,
            [HotkeyPlannedRegistration(binding: hyperBinding, command: .focus(.right))]
        )
        XCTAssertTrue(plan.failures.isEmpty)
    }

    func testSystemHyperTriggerCodableRoundTrips() throws {
        for trigger in [SystemHyperTrigger.none, .key(UInt32(kVK_CapsLock)), .mouseButton(4)] {
            let data = try JSONEncoder().encode(trigger)
            let decoded = try JSONDecoder().decode(SystemHyperTrigger.self, from: data)
            XCTAssertEqual(decoded, trigger)
        }
    }

    func testSystemHyperTriggerHumanReadableNames() {
        XCTAssertEqual(SystemHyperTrigger.none.humanReadableString, "None")
        XCTAssertEqual(SystemHyperTrigger.key(UInt32(kVK_CapsLock)).humanReadableString, "Caps Lock")
        XCTAssertEqual(SystemHyperTrigger.mouseButton(4).humanReadableString, "MouseButton4")
    }

    func testSystemHyperTriggerParsing() {
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("None"), SystemHyperTrigger.none)
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable(""), SystemHyperTrigger.none)
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Caps Lock"), .key(UInt32(kVK_CapsLock)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("F13"), .key(UInt32(kVK_F13)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Left Control"), .key(UInt32(kVK_Control)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Left Option"), .key(UInt32(kVK_Option)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Left Shift"), .key(UInt32(kVK_Shift)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("Left Command"), .key(UInt32(kVK_Command)))
        XCTAssertEqual(SystemHyperTrigger.fromHumanReadable("MouseButton4"), .mouseButton(4))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("A"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("Space"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("MouseButton2"))
        XCTAssertNil(SystemHyperTrigger.fromHumanReadable("not a key"))
    }

    func testSystemHyperTriggerSupportUsesSelectableSets() {
        XCTAssertTrue(SystemHyperTrigger.none.isSupported)
        for keyCode in SystemHyperTrigger.selectableKeyCodes {
            XCTAssertTrue(SystemHyperTrigger.key(keyCode).isSupported)
        }
        for button in SystemHyperTrigger.selectableMouseButtons {
            XCTAssertTrue(SystemHyperTrigger.mouseButton(button).isSupported)
        }

        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_ANSI_A)).isSupported)
        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_Space)).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(0).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(1).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(2).isSupported)
        XCTAssertFalse(SystemHyperTrigger.mouseButton(6).isSupported)
    }

    func testSystemHyperTriggerDirectDecodeRejectsUnsupportedValues() {
        XCTAssertThrowsError(try JSONDecoder().decode(SystemHyperTrigger.self, from: Data(#""A""#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SystemHyperTrigger.self, from: Data(#""MouseButton2""#.utf8)))
    }

    func testSystemHyperTriggerProperties() {
        XCTAssertFalse(SystemHyperTrigger.none.isEnabled)
        XCTAssertTrue(SystemHyperTrigger.key(UInt32(kVK_F13)).isEnabled)
        XCTAssertTrue(SystemHyperTrigger.key(UInt32(kVK_CapsLock)).requiresCapsLockRemap)
        XCTAssertFalse(SystemHyperTrigger.key(UInt32(kVK_F13)).requiresCapsLockRemap)
        XCTAssertEqual(SystemHyperTrigger.mouseButton(4).mouseButtonNumber, 4)
    }

    func testHyperTriggerStateMachineHandlesKeyTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F13)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F13)), .suppress)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
    }

    func testSystemHyperTriggerSupportsLeftModifiers() {
        let leftModifiers = [
            UInt32(kVK_Control), UInt32(kVK_Option), UInt32(kVK_Shift), UInt32(kVK_Command)
        ]
        for keyCode in leftModifiers {
            XCTAssertTrue(SystemHyperTrigger.selectableKeyCodes.contains(keyCode))
            XCTAssertTrue(SystemHyperTrigger.key(keyCode).isSupported)
        }
    }

    func testHyperTriggerStateMachineHandlesLeftModifierTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_Control)), capsLockRemapped: false)
        let leftControlDown = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)

        XCTAssertEqual(
            trigger.handleFlagsChanged(keyCode: UInt32(kVK_Control), rawFlags: leftControlDown),
            .suppress
        )
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleFlagsChanged(keyCode: UInt32(kVK_Control), rawFlags: 0), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineHandlesCapsLockRemap() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_CapsLock)), .passThrough)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode), .suppress)
        XCTAssertTrue(trigger.isActive)
    }

    func testHyperTriggerStateMachineTogglesCapsLockOnQuickTap() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 1.0), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 1.1), .toggleCapsLock)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A), timestamp: 1.2), .passThrough)
    }

    func testHyperTriggerStateMachineCapsLockWithKeyDoesNotToggleOnRelease() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 2.0), .suppress)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_K), timestamp: 2.1), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_ANSI_K), timestamp: 2.2), .inject)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 2.3), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineLongCapsLockHoldDoesNotToggle() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 3.0), .suppress)
        XCTAssertEqual(
            trigger.handleKeyUp(
                CapsLockHyperMapping.f18KeyCode,
                timestamp: 3.0 + HyperTriggerStateMachine.capsLockTapTimeout + 0.01
            ),
            .suppress
        )
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineCapsLockWithMouseDoesNotToggleOnRelease() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)

        XCTAssertEqual(trigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 4.0), .suppress)
        XCTAssertEqual(trigger.handleMouseDown(4), .inject)
        XCTAssertEqual(trigger.handleMouseUp(4), .inject)
        XCTAssertEqual(trigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 4.1), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineRealF18NeverTogglesCapsLock() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F18)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F18), timestamp: 5.0), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_K), timestamp: 5.1), .inject)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F18), timestamp: 5.2), .suppress)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineHandlesRightSideModifierTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_RightOption)), capsLockRemapped: false)

        XCTAssertEqual(
            trigger.handleFlagsChanged(
                keyCode: UInt32(kVK_RightOption),
                rawFlags: UInt64(NX_DEVICERALTKEYMASK)
            ),
            .suppress
        )
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(
            trigger.handleFlagsChanged(keyCode: UInt32(kVK_RightOption), rawFlags: 0),
            .suppress
        )
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineHandlesMouseTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .mouseButton(4), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleMouseDown(4), .suppress)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .inject)
        XCTAssertEqual(trigger.handleMouseUp(4), .suppress)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleMouseDown(3), .passThrough)
    }

    func testHyperTriggerStateMachineResetClearsActiveState() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F13)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .suppress)
        XCTAssertTrue(trigger.isActive)
        trigger.reset()
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
    }

    func testHyperTriggerStateMachineNonePassesThrough() {
        var trigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_F13)), .passThrough)
        XCTAssertEqual(trigger.handleKeyUp(UInt32(kVK_F13)), .passThrough)
        XCTAssertEqual(
            trigger.handleFlagsChanged(
                keyCode: UInt32(kVK_RightOption),
                rawFlags: UInt64(NX_DEVICERALTKEYMASK)
            ),
            .passThrough
        )
        XCTAssertEqual(trigger.handleMouseDown(4), .passThrough)
        XCTAssertEqual(trigger.handleMouseUp(4), .passThrough)
        XCTAssertFalse(trigger.isActive)
    }

    func testHyperTriggerStateMachineIgnoresUnsupportedTrigger() {
        var trigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_ANSI_A)), capsLockRemapped: false)

        XCTAssertEqual(trigger.handleKeyDown(UInt32(kVK_ANSI_A)), .passThrough)
        XCTAssertFalse(trigger.isActive)
    }

    func testCapsLockHyperMappingPreservesUnrelatedMappingsWhenApplying() {
        let unrelated = HIDKeyboardModifierMapping(source: 100, destination: 200)
        let existingCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 300
        )

        let mappings = CapsLockHyperMapping.applying(to: [unrelated, existingCapsLock])

        XCTAssertEqual(mappings, [unrelated, CapsLockHyperMapping.omniMapping])
    }

    func testCapsLockHyperMappingRestoresOnlyOmniMapping() {
        let unrelated = HIDKeyboardModifierMapping(source: 100, destination: 200)
        let originalCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 300
        )

        let mappings = CapsLockHyperMapping.restoring(
            current: [unrelated, CapsLockHyperMapping.omniMapping],
            original: [originalCapsLock]
        )

        XCTAssertEqual(mappings, [unrelated, originalCapsLock])
    }

    func testCapsLockHyperMappingKeepsExternalCapsLockChangeOnRestore() {
        let externalCapsLock = HIDKeyboardModifierMapping(
            source: CapsLockHyperMapping.capsLockSource,
            destination: 400
        )

        let mappings = CapsLockHyperMapping.restoring(
            current: [CapsLockHyperMapping.omniMapping, externalCapsLock],
            original: []
        )

        XCTAssertEqual(mappings, [externalCapsLock])
    }

    func testKeyRecorderBindingResolverRecordsHyperModifiedKey() {
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: KeySymbolMapper.hyperModifiers)
        )
    }

    func testKeyRecorderBindingResolverIgnoresBareHyperTriggerKey() {
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: CapsLockHyperMapping.f18KeyCode,
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            )
        )
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_CapsLock),
                modifiers: 0,
                hyperActive: true,
                allowsBareKeys: false
            )
        )
    }

    func testKeyRecorderBindingResolverKeepsExistingInactiveBehavior() {
        XCTAssertNil(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: 0,
                hyperActive: false,
                allowsBareKeys: false
            )
        )
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: UInt32(optionKey),
                hyperActive: false,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey))
        )
        XCTAssertEqual(
            KeyRecorderBindingResolver.binding(
                keyCode: UInt32(kVK_F13),
                modifiers: 0,
                hyperActive: false,
                allowsBareKeys: false
            ),
            KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)
        )
    }

    func testSettingsTOMLDoesNotEmitLeaderOrSequenceTimeout() throws {
        let data = try SettingsTOMLCodec.encode(.defaults())
        let toml = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(toml.contains("leaderKey"))
        XCTAssertFalse(toml.contains("sequenceTimeoutMilliseconds"))
    }

    func testKeyBindingConflictTreatsLeftAndRightAsDistinct() {
        let either = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        let left = either.settingSide(.left)
        let right = either.settingSide(.right)

        XCTAssertFalse(left.conflicts(with: right))
        XCTAssertFalse(right.conflicts(with: left))
        XCTAssertTrue(left.conflicts(with: left))
        XCTAssertTrue(either.conflicts(with: left))
        XCTAssertTrue(either.conflicts(with: right))
        XCTAssertTrue(left.conflicts(with: either))
    }

    func testSideQualifiedModifierRoundTrips() {
        let right = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)).settingSide(.right)

        XCTAssertEqual(right.humanReadableString, "Right Option+1")
        XCTAssertEqual(right.displayString, "R⌥1")
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Right Option+1"), right)
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("RightOption+1"), right)

        let either = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        XCTAssertEqual(either.humanReadableString, "Option+1")
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Option+1"), either)
    }

    func testMixedSideModifierRoundTrips() {
        let binding = KeyBinding(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey | shiftKey),
            sidedModifiers: SidedModifiers(left: UInt32(shiftKey), right: UInt32(optionKey))
        )

        XCTAssertEqual(binding.humanReadableString, "Right Option+Left Shift+A")
        XCTAssertEqual(KeySymbolMapper.fromHumanReadable("Right Option+Left Shift+A"), binding)
    }

    func testRegistrationPlanPartitionsSideSpecificBindings() {
        let either = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let leftOnly = KeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey)).settingSide(.left)
        let bindings = [
            HotkeyBinding(id: "focus.left", command: .focus(.left), binding: either),
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: leftOnly)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.registrations.map(\.command), [.focus(.left)])
        XCTAssertEqual(plan.sideSpecificRegistrations.map(\.command), [.focus(.right)])
        XCTAssertTrue(plan.failures.isEmpty)
    }

    func testRegistrationPlanMarksOverlappingSideBindingsDuplicate() {
        let either = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        let left = either.settingSide(.left)
        let bindings = [
            HotkeyBinding(id: "focus.left", command: .focus(.left), binding: either),
            HotkeyBinding(id: "focus.right", command: .focus(.right), binding: left)
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.failures[.focus(.left)], .duplicateBinding)
        XCTAssertEqual(plan.failures[.focus(.right)], .duplicateBinding)
    }

    func testCommandHotkeyTapMatcherRespectsModifierSide() {
        let leftOption = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)).settingSide(.left)
        let entries = [CommandHotkeyTapMatcher.Entry(binding: leftOption, command: .switchWorkspace(0))]
        let leftFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
        let rightFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)

        XCTAssertEqual(
            CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: leftFlags, entries: entries),
            .switchWorkspace(0)
        )
        XCTAssertNil(CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: rightFlags, entries: entries))
        XCTAssertNil(CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_2), rawFlags: leftFlags, entries: entries))
    }

    func testCommandHotkeyTapMatcherEitherSideMatchesBothSides() {
        let eitherOption = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        let entries = [CommandHotkeyTapMatcher.Entry(binding: eitherOption, command: .focusPrevious)]
        let leftFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
        let rightFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)

        XCTAssertEqual(
            CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: leftFlags, entries: entries),
            .focusPrevious
        )
        XCTAssertEqual(
            CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: rightFlags, entries: entries),
            .focusPrevious
        )
    }

    func testCommandHotkeyTapMatcherRejectsExtraModifiers() {
        let leftOption = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey)).settingSide(.left)
        let entries = [CommandHotkeyTapMatcher.Entry(binding: leftOption, command: .switchWorkspace(0))]
        let leftOptionWithShift = CGEventFlags.maskAlternate.rawValue
            | UInt64(NX_DEVICELALTKEYMASK)
            | CGEventFlags.maskShift.rawValue
            | UInt64(NX_DEVICELSHIFTKEYMASK)

        XCTAssertNil(
            CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: leftOptionWithShift, entries: entries)
        )
    }

    func testRejectionReasonAgreesWithMatchesAcrossCases() {
        let either = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        let bindings = [either, either.settingSide(.left), either.settingSide(.right)]
        let leftFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK)
        let rightFlags = CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICERALTKEYMASK)
        let leftWithShift = leftFlags | CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK)
        let flagSets: [UInt64] = [0, leftFlags, rightFlags, leftWithShift]

        for binding in bindings {
            for keyCode in [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2)] {
                for flags in flagSets {
                    let matched = CommandHotkeyTapMatcher.matches(binding, keyCode: keyCode, rawFlags: flags)
                    let reason = CommandHotkeyTapMatcher.rejectionReason(binding, keyCode: keyCode, rawFlags: flags)
                    XCTAssertEqual(
                        matched,
                        reason == nil,
                        "binding=\(binding.displayString) key=\(keyCode) flags=\(flags)"
                    )
                }
            }
        }
    }

    func testNearMissReportsClosestSidedBindingAndReason() {
        let leftHyper = KeyBinding(
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: KeySymbolMapper.hyperModifiers,
            sidedModifiers: SidedModifiers(left: KeySymbolMapper.hyperModifiers)
        )
        let entries = [CommandHotkeyTapMatcher.Entry(binding: leftHyper, command: .focusPrevious)]
        let onlyLeftControl = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)

        XCTAssertNil(
            CommandHotkeyTapMatcher.match(keyCode: UInt32(kVK_ANSI_1), rawFlags: onlyLeftControl, entries: entries)
        )
        let nearMiss = CommandHotkeyTapMatcher.nearMiss(
            keyCode: UInt32(kVK_ANSI_1),
            rawFlags: onlyLeftControl,
            entries: entries
        )
        XCTAssertEqual(nearMiss?.entry.command, .focusPrevious)
        XCTAssertEqual(nearMiss?.reason, "needs ⌥")
    }

    func testSettingSidePinsAndClearsUniformly() {
        let base = KeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))

        let right = base.settingSide(.right)
        XCTAssertEqual(right.side, .right)
        XCTAssertEqual(right.sidedModifiers.right, UInt32(optionKey | shiftKey))
        XCTAssertEqual(right.sidedModifiers.left, 0)

        let backToEither = right.settingSide(.either)
        XCTAssertEqual(backToEither.side, .either)
        XCTAssertTrue(backToEither.sidedModifiers.isEmpty)

        let bare = KeyBinding(keyCode: UInt32(kVK_F13), modifiers: 0)
        XCTAssertEqual(bare.settingSide(.right).side, .either)
    }

    func testSideSurvivesKeyedCodableFallbackForUnmappedKey() throws {
        let unmappedKeyCode: UInt32 = 9999
        XCTAssertEqual(KeySymbolMapper.keyName(unmappedKeyCode), "?")

        let binding = KeyBinding(
            keyCode: unmappedKeyCode,
            modifiers: UInt32(optionKey),
            sidedModifiers: SidedModifiers(right: UInt32(optionKey))
        )

        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)

        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.side, .right)
    }
}
