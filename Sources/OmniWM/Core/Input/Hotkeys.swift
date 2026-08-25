// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let command: HotkeyCommand

    init(binding: KeyBinding, command: HotkeyCommand) {
        self.binding = binding
        self.command = command
    }
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
    case requiresInputMonitoring
}

enum SystemHyperTriggerFailure: Equatable {
    case eventTapUnavailable
    case capsLockRemapUnavailable
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let sideSpecificRegistrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]

    init(
        registrations: [HotkeyPlannedRegistration],
        sideSpecificRegistrations: [HotkeyPlannedRegistration] = [],
        failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
    ) {
        self.registrations = registrations
        self.sideSpecificRegistrations = sideSpecificRegistrations
        self.failures = failures
    }
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let systemHyperTrigger: SystemHyperTrigger

    init(bindings: [HotkeyBinding] = [], systemHyperTrigger: SystemHyperTrigger = .default) {
        self.bindings = bindings
        self.systemHyperTrigger = systemHyperTrigger
    }
}

struct HyperTriggerStateMachine: Equatable {
    enum Decision: Equatable {
        case suppress
        case passThrough
        case inject
        case toggleCapsLock
    }

    private enum Trigger: Equatable {
        case none
        case key(UInt32)
        case capsLockF18
        case modifier(keyCode: UInt32, mask: UInt64)
        case mouseButton(Int64)
    }

    static let capsLockTapTimeout: TimeInterval = 0.3

    private let trigger: Trigger
    private(set) var isActive = false
    private var capsAlone = false
    private var capsDownTimestamp: TimeInterval?

    init(trigger: SystemHyperTrigger, capsLockRemapped: Bool) {
        guard trigger.isSupported else {
            self.trigger = .none
            return
        }
        switch trigger {
        case .none:
            self.trigger = .none
        case let .key(keyCode):
            if capsLockRemapped, keyCode == UInt32(kVK_CapsLock) {
                self.trigger = .capsLockF18
            } else if let mask = Self.modifierMask(for: keyCode) {
                self.trigger = .modifier(keyCode: keyCode, mask: mask)
            } else {
                self.trigger = .key(keyCode)
            }
        case let .mouseButton(button):
            self.trigger = .mouseButton(button)
        }
    }

    mutating func handleKeyDown(_ keyCode: UInt32, timestamp: TimeInterval = 0) -> Decision {
        handleKey(keyCode, isDown: true, timestamp: timestamp)
    }

    mutating func handleKeyUp(_ keyCode: UInt32, timestamp: TimeInterval = 0) -> Decision {
        handleKey(keyCode, isDown: false, timestamp: timestamp)
    }

    mutating func handleFlagsChanged(keyCode: UInt32, rawFlags: UInt64) -> Decision {
        guard case let .modifier(triggerKeyCode, mask) = trigger, keyCode == triggerKeyCode else {
            return .passThrough
        }
        isActive = rawFlags & mask != 0
        return .suppress
    }

    mutating func handleMouseDown(_ button: Int64) -> Decision {
        handleMouse(button, isDown: true)
    }

    mutating func handleMouseUp(_ button: Int64) -> Decision {
        handleMouse(button, isDown: false)
    }

    mutating func reset() {
        isActive = false
        capsAlone = false
        capsDownTimestamp = nil
    }

    private mutating func handleKey(_ keyCode: UInt32, isDown: Bool, timestamp: TimeInterval) -> Decision {
        switch trigger {
        case let .key(triggerKeyCode) where keyCode == triggerKeyCode:
            isActive = isDown
            return .suppress
        case .capsLockF18 where keyCode == CapsLockHyperMapping.f18KeyCode:
            if isDown {
                if !isActive {
                    capsAlone = true
                    capsDownTimestamp = timestamp
                }
                isActive = true
                return .suppress
            }
            let shouldToggle = isActive
                && capsAlone
                && timestamp - (capsDownTimestamp ?? timestamp) < Self.capsLockTapTimeout
            isActive = false
            capsAlone = false
            capsDownTimestamp = nil
            return shouldToggle ? .toggleCapsLock : .suppress
        default:
            if isActive, isDown {
                capsAlone = false
            }
            return isActive ? .inject : .passThrough
        }
    }

    private mutating func handleMouse(_ button: Int64, isDown: Bool) -> Decision {
        if case let .mouseButton(triggerButton) = trigger, button == triggerButton {
            isActive = isDown
            return .suppress
        }
        if case .capsLockF18 = trigger, isActive {
            if isDown {
                capsAlone = false
            }
            return .inject
        }
        return .passThrough
    }

    private static func modifierMask(for keyCode: UInt32) -> UInt64? {
        switch Int(keyCode) {
        case kVK_Shift:
            return UInt64(NX_DEVICELSHIFTKEYMASK)
        case kVK_RightShift:
            return UInt64(NX_DEVICERSHIFTKEYMASK)
        case kVK_Control:
            return UInt64(NX_DEVICELCTLKEYMASK)
        case kVK_RightControl:
            return UInt64(NX_DEVICERCTLKEYMASK)
        case kVK_Option:
            return UInt64(NX_DEVICELALTKEYMASK)
        case kVK_RightOption:
            return UInt64(NX_DEVICERALTKEYMASK)
        case kVK_Command:
            return UInt64(NX_DEVICELCMDKEYMASK)
        case kVK_RightCommand:
            return UInt64(NX_DEVICERCMDKEYMASK)
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyCenter {
    var onCommand: ((HotkeyInvocation) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var commandHotkeysSuspended = false
    private var idToRegistration: [UInt32: HotkeyPlannedRegistration] = [:]
    private var pressedHotKeyIds: Set<UInt32> = []

    private var configuration = HotkeyRuntimeConfiguration()
    private var sideSpecificDispatch: [CommandHotkeyTapMatcher.Entry] = []
    private var suppressedHotkeyKeyCodes: Set<UInt32> = []
    var hyperTriggerTap: CFMachPort?
    var hyperTriggerRunLoopSource: CFRunLoopSource?
    private var hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
    private let capsLockHyperRemapper = CapsLockHyperRemapper()
    private var capsLockToggler = CapsLockToggler()
    private var capsLockHyperRemapActive = false

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
    private(set) var systemHyperTriggerFailure: SystemHyperTriggerFailure?

    private static var hyperFlagMask: UInt64 {
        let hyper = KeySymbolMapper.hyperModifiers
        return ModifierFlagMask.all.reduce(UInt64(0)) { mask, flag in
            hyper & flag.carbon != 0 ? mask | flag.independent : mask
        }
    }

    var isHyperTriggerActive: Bool {
        hyperTrigger.isActive
    }

    func hotkeyHealthFacts() -> HotkeyHealthFacts {
        HotkeyHealthFacts(
            isRunning: isRunning,
            isHyperTriggerActive: hyperTrigger.isActive,
            hyperTriggerTapInstalled: hyperTriggerTap != nil,
            capsLockHyperRemapActive: capsLockHyperRemapActive,
            systemHyperTriggerEnabled: configuration.systemHyperTrigger.isEnabled,
            systemHyperTriggerName: configuration.systemHyperTrigger.humanReadableString,
            systemHyperTriggerFailure: systemHyperTriggerFailure.map { "\($0)" },
            suppressedHotkeyCount: suppressedHotkeyKeyCodes.count,
            registrationFailureCount: registrationFailures.count,
            sideSpecificCount: sideSpecificDispatch.count,
            bindingCount: configuration.bindings.count,
            bindings: Self.bindingFacts(for: configuration.bindings)
        )
    }

    nonisolated static func bindingFacts(for bindings: [HotkeyBinding]) -> [HotkeyBindingFact] {
        let failures = registrationPlan(for: bindings).failures
        return bindings.compactMap { binding in
            guard case let .chord(chord) = binding.binding, !chord.isUnassigned else { return nil }
            let route: String
            if let reason = failures[binding.command] {
                route = "unregistered(\(reason))"
            } else if chord.sidedModifiers.isEmpty {
                route = "carbon"
            } else {
                route = "sided"
            }
            return HotkeyBindingFact(command: binding.command.displayName, display: chord.displayString, route: route)
        }
    }

    static func decisionLabel(_ decision: HyperTriggerStateMachine.Decision) -> String {
        switch decision {
        case .suppress: "suppress"
        case .passThrough: "passThrough"
        case .inject: "inject"
        case .toggleCapsLock: "toggleCapsLock"
        }
    }

    deinit {
        MainActor.assumeIsolated {
            unregisterCommandHotkeys()
            stopHyperTriggerTap()
            restoreCapsLockHyperRemap()
            removeCarbonEventHandler()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            MainActor.assumeIsolated {
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    center.pressedHotKeyIds.remove(hotKeyID.id)
                } else {
                    let isRepeat = !center.pressedHotKeyIds.insert(hotKeyID.id).inserted
                    center.dispatch(id: hotKeyID.id, isRepeat: isRepeat)
                }
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventSpecs, selfPtr, &handler)

        refreshCommandHotkeyRegistrations()
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.start")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterCommandHotkeys()
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        removeCarbonEventHandler()
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.stop")
    }

    private func removeCarbonEventHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func setCommandHotkeysSuspended(_ suspended: Bool) {
        guard commandHotkeysSuspended != suspended else { return }
        commandHotkeysSuspended = suspended
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    func updateBindings(
        _ newBindings: [HotkeyBinding],
        systemHyperTrigger newSystemHyperTrigger: SystemHyperTrigger = .default,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            systemHyperTrigger: newSystemHyperTrigger
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    private func unregisterCommandHotkeys() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToRegistration.removeAll()
        pressedHotKeyIds.removeAll()
    }

    private func reconcileEventTap() {
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        systemHyperTriggerFailure = nil
        hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)

        let hyperEnabled = configuration.systemHyperTrigger.isEnabled
        guard hyperEnabled || !sideSpecificDispatch.isEmpty else { return }

        if hyperEnabled {
            if activateCapsLockHyperRemapIfNeeded() {
                hyperTrigger = HyperTriggerStateMachine(
                    trigger: configuration.systemHyperTrigger,
                    capsLockRemapped: capsLockHyperRemapActive
                )
            } else {
                systemHyperTriggerFailure = .capsLockRemapUnavailable
                DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.capsLockRemap.failed")
                FallbackFiringRecorder.shared.note(.input, "capsLockHyperRemapFailed")
            }
        }

        if setupHyperTriggerTapIfNeeded() {
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.hyperTap.installed")
        } else {
            if hyperEnabled {
                systemHyperTriggerFailure = .eventTapUnavailable
            }
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.hyperTap.failed")
            FallbackFiringRecorder.shared.note(.input, "hyperTapSetupFailed")
            restoreCapsLockHyperRemap()
            hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
        }
    }

    private func refreshCommandHotkeyRegistrations() {
        unregisterCommandHotkeys()
        let plan = Self.registrationPlan(for: configuration.bindings)
        registrationFailures = plan.failures

        guard !commandHotkeysSuspended else {
            sideSpecificDispatch = []
            reconcileEventTap()
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.suspended")
            return
        }

        var nextId: UInt32 = 1
        for registration in plan.registrations {
            guard registrationFailures[registration.command] == nil else {
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: nextId)
            let status = RegisterEventHotKey(
                registration.binding.keyCode,
                registration.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                idToRegistration[nextId] = registration
            } else {
                registrationFailures[registration.command] = .systemReserved
                FallbackFiringRecorder.shared.note(.input, "hotkeyRegistrationFailed")
            }
            nextId += 1
        }

        sideSpecificDispatch = plan.sideSpecificRegistrations.map {
            CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command)
        }
        reconcileEventTap()
        if !sideSpecificDispatch.isEmpty, hyperTriggerTap == nil {
            for entry in sideSpecificDispatch {
                registrationFailures[entry.command] = .requiresInputMonitoring
            }
            sideSpecificDispatch = []
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "hotkeys.registered registered=\(refs.count) "
                + "failures=\(registrationFailures.count) sided=\(sideSpecificDispatch.count)"
        )
    }

    private func dispatch(id: UInt32, isRepeat: Bool) {
        guard let registration = idToRegistration[id] else { return }
        InputTrace.record("hotkey.carbon cmd=\(registration.command.displayName)")
        onCommand?(
            HotkeyInvocation(
                command: registration.command,
                trigger: PhysicalHotkeyTrigger(
                    keyCode: registration.binding.keyCode,
                    modifiers: registration.binding.modifiers,
                    isRepeat: isRepeat
                )
            )
        )
    }

    private func activateCapsLockHyperRemapIfNeeded() -> Bool {
        guard configuration.systemHyperTrigger.requiresCapsLockRemap else { return true }
        guard !capsLockHyperRemapActive else { return true }
        guard capsLockHyperRemapper.apply() else { return false }
        capsLockHyperRemapActive = true
        return true
    }

    private func restoreCapsLockHyperRemap() {
        guard capsLockHyperRemapActive else { return }
        capsLockHyperRemapper.restore()
        capsLockHyperRemapActive = false
    }

    private func setupHyperTriggerTapIfNeeded() -> Bool {
        if hyperTriggerTap != nil { return true }
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleHyperTriggerEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        hyperTriggerTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = hyperTriggerTap else {
            FallbackFiringRecorder.shared.note(.input, "hyperTapCreateFailed")
            return false
        }
        hyperTriggerRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = hyperTriggerRunLoopSource else {
            EventTapTeardown.tearDown(
                tap: &hyperTriggerTap,
                runLoopSource: &hyperTriggerRunLoopSource
            )
            FallbackFiringRecorder.shared.note(.input, "hyperTapRunLoopSourceFailed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stopHyperTriggerTap() {
        hyperTrigger.reset()
        suppressedHotkeyKeyCodes.removeAll()
        EventTapTeardown.tearDown(
            tap: &hyperTriggerTap,
            runLoopSource: &hyperTriggerRunLoopSource
        )
    }

    private func handleHyperTriggerEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            InputTapHealth.recordTapDisabled(mouse: false, byTimeout: true)
            if let tap = hyperTriggerTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            hyperTrigger.reset()
            suppressedHotkeyKeyCodes.removeAll()
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            InputTapHealth.recordTapDisabled(mouse: false, byTimeout: false)
            hyperTrigger.reset()
            suppressedHotkeyKeyCodes.removeAll()
            return Unmanaged.passUnretained(event)
        case .keyDown,
             .keyUp:
            return handleHyperTriggerKeyEvent(type: type, event: event)
        case .flagsChanged:
            return handleHyperTriggerFlagsChanged(event)
        case .otherMouseDown,
             .otherMouseUp:
            return handleHyperTriggerMouseEvent(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        switch type {
        case .keyDown:
            let decision = hyperTrigger.handleKeyDown(keyCode, timestamp: timestamp)
            recordHyperDecision("keyDown", decision)
            switch decision {
            case .suppress:
                return nil
            case .toggleCapsLock:
                capsLockToggler.toggle()
                return nil
            case .inject:
                injectHyperFlags(into: event)
            case .passThrough:
                break
            }
            if suppressedHotkeyKeyCodes.contains(keyCode) {
                return nil
            }
            if dispatchSideSpecificHotkey(keyCode: keyCode, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if suppressedHotkeyKeyCodes.remove(keyCode) != nil {
                return nil
            }
            return applyHyperTriggerDecision(
                hyperTrigger.handleKeyUp(keyCode, timestamp: timestamp),
                to: event
            )
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return applyHyperTriggerDecision(
            hyperTrigger.handleFlagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue),
            to: event
        )
    }

    private func handleHyperTriggerMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseDown(button), to: event)
        case .otherMouseUp:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseUp(button), to: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func applyHyperTriggerDecision(
        _ decision: HyperTriggerStateMachine.Decision,
        to event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        recordHyperDecision("apply", decision)
        switch decision {
        case .suppress:
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .inject:
            injectHyperFlags(into: event)
            return Unmanaged.passUnretained(event)
        case .toggleCapsLock:
            capsLockToggler.toggle()
            return nil
        }
    }

    private func injectHyperFlags(into event: CGEvent) {
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | Self.hyperFlagMask)
    }

    private func recordHyperDecision(_ phase: String, _ decision: HyperTriggerStateMachine.Decision) {
        guard decision != .passThrough else { return }
        InputTrace.record("hyper \(phase) decision=\(Self.decisionLabel(decision))")
    }

    private func dispatchSideSpecificHotkey(keyCode: UInt32, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        let rawFlags = event.flags.rawValue
        if let entry = sideSpecificDispatch.first(where: {
            CommandHotkeyTapMatcher.matches($0.binding, keyCode: keyCode, rawFlags: rawFlags)
        }) {
            suppressedHotkeyKeyCodes.insert(keyCode)
            InputTrace.record("hotkey.sided cmd=\(entry.command.displayName)")
            onCommand?(
                HotkeyInvocation(
                    command: entry.command,
                    trigger: PhysicalHotkeyTrigger(
                        keyCode: entry.binding.keyCode,
                        modifiers: entry.binding.modifiers,
                        isRepeat: false
                    )
                )
            )
            return true
        }
        recordSidedMiss(keyCode: keyCode, rawFlags: rawFlags)
        return false
    }

    private func recordSidedMiss(keyCode: UInt32, rawFlags: UInt64) {
        guard InputTrace.shared.isActive, !sideSpecificDispatch.isEmpty else { return }
        let down = KeySymbolMapper.sidedModifierLabel(rawFlags)
        guard !down.isEmpty else { return }
        let nearMiss = CommandHotkeyTapMatcher.nearMiss(
            keyCode: keyCode,
            rawFlags: rawFlags,
            entries: sideSpecificDispatch
        )
        InputTrace.record(
            "hotkey.sided.miss key=\(KeySymbolMapper.keySymbol(keyCode)) down=\(down) "
                + "closest=\(nearMiss?.entry.command.displayName ?? "none") "
                + "needs=\(nearMiss?.entry.binding.displayString ?? "-") "
                + "reason=\(nearMiss?.reason ?? "-")"
        )
    }

    nonisolated static func inputMonitoringAccessGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    nonisolated static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    nonisolated static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        var candidates: [(command: HotkeyCommand, binding: KeyBinding)] = []
        for binding in bindings {
            guard case let .chord(keyBinding) = binding.binding, !keyBinding.isUnassigned else { continue }
            candidates.append((binding.command, keyBinding))
        }

        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
        for index in candidates.indices {
            let overlaps = candidates.indices.contains { other in
                other != index && candidates[index].binding.conflicts(with: candidates[other].binding)
            }
            if overlaps {
                failures[candidates[index].command] = .duplicateBinding
            }
        }

        let registrable = candidates.filter { failures[$0.command] == nil }
        let registrations = registrable
            .filter { $0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }
        let sideSpecific = registrable
            .filter { !$0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            sideSpecificRegistrations: sideSpecific,
            failures: failures
        )
    }
}
