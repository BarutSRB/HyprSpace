// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Carbon
import SwiftUI

enum HotkeyCaptureResult {
    case applied
    case conflict(ConflictAlert)
}

@MainActor enum HotkeyBindingEditor {
    static func capture(
        _ newBinding: KeyBinding,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        capture(newBinding.isUnassigned ? .unassigned : .chord(newBinding), for: actionId, settings: settings)
    }

    static func capture(
        _ newTrigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        let conflicts = settings.findConflicts(for: newTrigger, excluding: actionId)
        guard conflicts.isEmpty else {
            return .conflict(
                ConflictAlert(
                    targetActionId: actionId,
                    newTrigger: newTrigger,
                    conflictingCommands: conflicts.map(\.command.displayName)
                )
            )
        }

        settings.updateTrigger(for: actionId, newTrigger: newTrigger)
        return .applied
    }

    static func applyConflictResolution(_ alert: ConflictAlert, settings: SettingsStore) {
        let conflicts = settings.findConflicts(for: alert.newTrigger, excluding: alert.targetActionId)
        for conflict in conflicts {
            settings.clearBinding(for: conflict.id)
        }
        settings.updateTrigger(for: alert.targetActionId, newTrigger: alert.newTrigger)
    }
}

private enum HotkeyRecordingTarget: Equatable {
    case chord(String)
}

enum HotkeyInputMonitoringStatus: Equatable {
    case granted
    case denied

    init(granted: Bool) {
        self = granted ? .granted : .denied
    }

    var displayText: String {
        switch self {
        case .granted:
            "Granted"
        case .denied:
            "Denied"
        }
    }
}

enum HotkeySettingsDisplayModel {
    static func isVisible(bindingId: String, showsAdvancedHotkeys: Bool) -> Bool {
        switch ActionCatalog.visibility(for: bindingId) ?? .normal {
        case .normal:
            true
        case .advanced:
            showsAdvancedHotkeys
        case .unassignable:
            false
        }
    }

    static func matchesSearch(_ query: String, binding: HotkeyBinding) -> Bool {
        let normalizedQuery = ActionCatalog.normalizedSearchTerm(query)
        guard !normalizedQuery.isEmpty else { return true }
        let actionTerms = ActionCatalog.spec(for: binding.id)?.searchTerms ?? [
            binding.command.displayName,
            binding.command.layoutCompatibility.rawValue
        ]
        let searchTerms = actionTerms + [
            displayString(for: binding.binding),
            humanReadableString(for: binding.binding)
        ]
        return searchTerms.contains {
            ActionCatalog.normalizedSearchTerm($0).contains(normalizedQuery)
        }
    }

    static func advancedSearchMatchCount(_ query: String, bindings: [HotkeyBinding]) -> Int {
        guard !ActionCatalog.normalizedSearchTerm(query).isEmpty else { return 0 }
        return bindings.count { binding in
            ActionCatalog.visibility(for: binding.id) == .advanced
                && matchesSearch(query, binding: binding)
        }
    }

    static func displayString(for binding: KeyBinding) -> String {
        binding.displayString
    }

    static func displayString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return displayString(for: binding)
        }
    }

    static func humanReadableString(for binding: KeyBinding) -> String {
        binding.humanReadableString
    }

    static func humanReadableString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return "Unassigned"
        case let .chord(binding):
            return humanReadableString(for: binding)
        }
    }

    static func inputMonitoringStatus(
        preflightGranted: Bool,
        requestIfNeeded: Bool,
        requestGranted: Bool
    ) -> HotkeyInputMonitoringStatus {
        HotkeyInputMonitoringStatus(granted: preflightGranted || (requestIfNeeded && requestGranted))
    }
}

struct HotkeySettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @State private var recordingTarget: HotkeyRecordingTarget?
    @State private var conflictAlert: ConflictAlert?
    @State private var searchText: String = ""
    @State private var showsAdvancedHotkeys = false
    @State private var confirmsResetToDefaults = false
    @State private var inputMonitoringStatus = HotkeyInputMonitoringStatus(
        granted: HotkeyCenter.eventTapAccessGranted()
    )

    var body: some View {
        SettingsPage(
            subtitle: "Search commands, edit shortcuts, and review registration problems without leaving the settings window."
        ) {
            Section("Controls") {
                LabeledContent("System Hyper Trigger") {
                    Picker("System Hyper Trigger", selection: $settings.systemHyperTrigger) {
                        Text("None").tag(SystemHyperTrigger.none)
                        ForEach(SystemHyperTrigger.selectableKeyCodes, id: \.self) { code in
                            Text(KeySymbolMapper.keyName(code)).tag(SystemHyperTrigger.key(code))
                        }
                        ForEach(SystemHyperTrigger.selectableMouseButtons, id: \.self) { button in
                            Text("Mouse Button \(button)").tag(SystemHyperTrigger.mouseButton(button))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160)
                    .onChange(of: settings.systemHyperTrigger) { _, _ in
                        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
                    }
                    .accessibilityLabel("System Hyper trigger")
                    .accessibilityValue(settings.systemHyperTrigger.humanReadableString)
                }
                if let triggerFailure = controller.systemHyperTriggerFailure {
                    SettingsCaption(systemHyperTriggerFailureMessage(triggerFailure))
                }
                SettingsCaption(
                    "Hold this key or button to act as \(settings.hyperKeyModifiers.symbolsString) (Hyper). "
                        + "Needs Input Monitoring permission. "
                        + "Leave as None to use a Hyper key set up elsewhere, such as Karabiner."
                )

                LabeledContent("Hyper Key Modifiers") {
                    HStack(spacing: 12) {
                        hyperModifierToggle("⌃ Control", flag: UInt32(controlKey))
                        hyperModifierToggle("⌥ Option", flag: UInt32(optionKey))
                        hyperModifierToggle("⇧ Shift", flag: UInt32(shiftKey))
                        hyperModifierToggle("⌘ Command", flag: UInt32(cmdKey))
                    }
                    .onChange(of: settings.hyperKeyModifiers) { _, _ in
                        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
                    }
                }
                SettingsCaption(
                    "Modifiers that make up the Hyper chord. Unchecked modifiers stay free to combine "
                        + "with Hyper in shortcuts, such as Hyper+Shift when Shift is excluded."
                )

                LabeledContent("Input Monitoring") {
                    HStack(spacing: 10) {
                        Text(inputMonitoringStatus.displayText)
                            .foregroundStyle(inputMonitoringStatus == .granted ? Color.secondary : Color.orange)
                        Button("Request Permission") {
                            refreshInputMonitoringStatus(requestIfNeeded: true)
                        }
                    }
                }

                LabeledContent("Defaults") {
                    Button("Reset to Defaults", role: .destructive) {
                        confirmsResetToDefaults = true
                    }
                }
            }

            Section("Shortcuts") {
                LabeledContent("Search") {
                    HStack(spacing: 8) {
                        TextField("Command, shortcut, or scope", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search hotkeys")

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Label("Clear search", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Clear search")
                            .accessibilityLabel("Clear hotkey search")
                        }
                    }
                }

                Toggle("Include Advanced Commands", isOn: $showsAdvancedHotkeys)
                    .toggleStyle(.switch)
                SettingsCaption("Includes advanced commands in the shortcut list and search results.")

                let hiddenAdvancedMatchCount = hiddenAdvancedSearchMatchCount
                if hiddenAdvancedMatchCount > 0 {
                    HStack(spacing: 12) {
                        Text(hiddenAdvancedSearchMessage(for: hiddenAdvancedMatchCount))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Advanced Commands") {
                            showsAdvancedHotkeys = true
                        }
                    }
                } else if !hasSearchMatches {
                    Text("No matching hotkeys.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(HotkeyCategory.allCases, id: \.self) { category in
                let actions = actionsForCategory(category)
                if !actions.isEmpty {
                    Section(category.rawValue) {
                        ForEach(actions) { binding in
                            HotkeyBindingRow(
                                binding: binding,
                                recordingTarget: $recordingTarget,
                                failureReason: controller.hotkeyRegistrationFailures[binding.command],
                                isHyperActive: {
                                    controller.isHyperTriggerActive
                                },
                                onStartChordRecording: startChordRecording,
                                onChordCaptured: handleChordCaptured,
                                onCancelRecording: cancelRecording,
                                onClearBinding: clearBinding,
                                onResetBindings: resetBindings,
                                onSetSide: setSide
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            inputMonitoringStatus = HotkeyInputMonitoringStatus(
                granted: HotkeyCenter.eventTapAccessGranted()
            )
        }
        .onChange(of: recordingTarget) { _, _ in
            syncHotkeyRecordingState()
        }
        .onDisappear {
            guard isRecordingOrDrafting else { return }
            cancelRecording()
            controller.setHotkeysEnabled(settings.hotkeysEnabled)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("Hotkey Conflict"),
                message: Text(alert.message),
                primaryButton: .destructive(Text("Replace")) {
                    HotkeyBindingEditor.applyConflictResolution(alert, settings: settings)
                    controller.updateHotkeyBindings(settings.hotkeyBindings)
                    cancelRecording()
                },
                secondaryButton: .cancel {
                    cancelRecording()
                }
            )
        }
        .confirmationDialog("Reset all hotkeys?", isPresented: $confirmsResetToDefaults) {
            Button("Reset Hotkeys", role: .destructive) {
                settings.resetHotkeysToDefaults()
                controller.updateHotkeyBindings(settings.hotkeyBindings)
                cancelRecording()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All hotkey bindings will be restored to OmniWM defaults.")
        }
    }

    private var hasSearchMatches: Bool {
        visibleHotkeyBindings.contains {
            HotkeySettingsDisplayModel.matchesSearch(searchText, binding: $0)
        }
    }

    private var visibleHotkeyBindings: [HotkeyBinding] {
        settings.hotkeyBindings.filter(isVisible)
    }

    private var hiddenAdvancedSearchMatchCount: Int {
        guard !showsAdvancedHotkeys else { return 0 }
        return HotkeySettingsDisplayModel.advancedSearchMatchCount(
            searchText,
            bindings: settings.hotkeyBindings
        )
    }

    private func actionsForCategory(_ category: HotkeyCategory) -> [HotkeyBinding] {
        visibleHotkeyBindings.filter { binding in
            binding.category == category && HotkeySettingsDisplayModel.matchesSearch(searchText, binding: binding)
        }
    }

    private func isVisible(_ binding: HotkeyBinding) -> Bool {
        HotkeySettingsDisplayModel.isVisible(
            bindingId: binding.id,
            showsAdvancedHotkeys: showsAdvancedHotkeys
        )
    }

    private func hiddenAdvancedSearchMessage(for count: Int) -> String {
        if count == 1 {
            return "1 matching advanced command is hidden."
        }
        return "\(count) matching advanced commands are hidden."
    }

    private var isRecordingOrDrafting: Bool {
        recordingTarget != nil
    }

    private func startChordRecording(for actionId: String) {
        recordingTarget = .chord(actionId)
    }

    private func hyperModifierToggle(_ title: String, flag: UInt32) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings.hyperKeyModifiers.contains(flag) },
            set: { included in
                guard let updated = settings.hyperKeyModifiers.setting(flag, included: included) else { return }
                settings.hyperKeyModifiers = updated
            }
        ))
        .disabled(
            settings.hyperKeyModifiers.contains(flag)
                && settings.hyperKeyModifiers.modifierCount <= HyperKeyModifiers.minimumModifierCount
        )
        .accessibilityLabel("Hyper includes \(title)")
    }

    private func systemHyperTriggerFailureMessage(_ failure: SystemHyperTriggerFailure) -> String {
        switch failure {
        case .eventTapUnavailable:
            "System Hyper trigger is unavailable: grant Input Monitoring permission."
        case .capsLockRemapUnavailable:
            "System Hyper trigger is unavailable: Caps Lock remapping failed."
        }
    }

    private func handleChordCaptured(actionId: String, newBinding: KeyBinding) {
        guard !newBinding.isUnassigned else {
            handleTriggerCaptured(actionId: actionId, newTrigger: .unassigned)
            return
        }
        let previousSide = settings.hotkeyBindings
            .first { $0.id == actionId }?.binding.chordBinding?.side ?? .either
        handleTriggerCaptured(actionId: actionId, newTrigger: .chord(newBinding.settingSide(previousSide)))
    }

    private func handleTriggerCaptured(actionId: String, newTrigger: HotkeyTrigger) {
        switch HotkeyBindingEditor.capture(newTrigger, for: actionId, settings: settings) {
        case .applied:
            controller.updateHotkeyBindings(settings.hotkeyBindings)
            cancelRecording()
        case let .conflict(alert):
            conflictAlert = alert
            cancelRecording()
        }
    }

    private func clearBinding(actionId: String) {
        settings.clearBinding(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func resetBindings(actionId: String) {
        settings.resetBindings(for: actionId)
        controller.updateHotkeyBindings(settings.hotkeyBindings)
        cancelRecording()
    }

    private func setSide(actionId: String, side: ModifierSide) {
        guard let binding = settings.hotkeyBindings.first(where: { $0.id == actionId }),
              let chord = binding.binding.chordBinding
        else { return }
        handleTriggerCaptured(actionId: actionId, newTrigger: .chord(chord.settingSide(side)))
    }

    private func cancelRecording() {
        recordingTarget = nil
        syncHotkeyRecordingState()
    }

    @discardableResult
    private func refreshInputMonitoringStatus(requestIfNeeded: Bool) -> Bool {
        let preflightGranted = HotkeyCenter.eventTapAccessGranted()
        let requestGranted: Bool
        if preflightGranted || !requestIfNeeded {
            requestGranted = false
        } else {
            requestGranted = HotkeyCenter.requestEventTapAccess()
        }
        let status = HotkeySettingsDisplayModel.inputMonitoringStatus(
            preflightGranted: preflightGranted,
            requestIfNeeded: requestIfNeeded,
            requestGranted: requestGranted
        )
        inputMonitoringStatus = status
        controller.updateHotkeyBindings(settings.hotkeyBindings, force: true)
        return status == .granted
    }

    private func syncHotkeyRecordingState() {
        controller.setHotkeyRecordingActive(isRecordingOrDrafting)
    }
}

struct ConflictAlert: Identifiable {
    let targetActionId: String
    let newTrigger: HotkeyTrigger
    let conflictingCommands: [String]

    var id: String {
        [
            targetActionId,
            newTrigger.humanReadableString,
            conflictingCommands.joined(separator: "|")
        ].joined(separator: ":")
    }

    var message: String {
        if conflictingCommands.count == 1 {
            return "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
        } else {
            let commandList = conflictingCommands.joined(separator: ", ")
            return "This key combination is used by: \(commandList). Do you want to replace all?"
        }
    }
}

private struct HotkeyBindingRow: View {
    let binding: HotkeyBinding
    @Binding var recordingTarget: HotkeyRecordingTarget?
    let failureReason: HotkeyRegistrationFailureReason?
    let isHyperActive: () -> Bool
    let onStartChordRecording: (String) -> Void
    let onChordCaptured: (String, KeyBinding) -> Void
    let onCancelRecording: () -> Void
    let onClearBinding: (String) -> Void
    let onResetBindings: (String) -> Void
    let onSetSide: (String, ModifierSide) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let failureReason {
                    Label("Registration issue", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help(failureMessage(for: failureReason))
                        .accessibilityLabel("Registration issue")
                        .accessibilityValue(failureMessage(for: failureReason))
                }

                HotkeyBindingControl(
                    binding: binding.binding,
                    commandName: binding.command.displayName,
                    isRecordingChord: recordingTarget == .chord(binding.id),
                    isHyperActive: isHyperActive,
                    onStartChordRecording: {
                        onStartChordRecording(binding.id)
                    },
                    onCaptured: { newBinding in
                        onChordCaptured(binding.id, newBinding)
                    },
                    onCancel: {
                        onCancelRecording()
                    },
                    onRemove: {
                        onClearBinding(binding.id)
                    },
                    onSetSide: { side in
                        onSetSide(binding.id, side)
                    }
                )

                ResetIconButton(title: "Reset \(binding.command.displayName) to default") {
                    recordingTarget = nil
                    onResetBindings(binding.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(binding.command.displayName)
                    .font(.body)

                HStack(spacing: 6) {
                    HotkeyScopeText(compatibility: binding.command.layoutCompatibility)

                    if let failureReason {
                        Text(failureMessage(for: failureReason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [
            "Shortcut \(HotkeySettingsDisplayModel.humanReadableString(for: binding.binding))",
            "Scope \(binding.command.layoutCompatibility.rawValue)"
        ]
        if let failureReason {
            parts.append(failureMessage(for: failureReason))
        }
        return parts.joined(separator: ", ")
    }

    private func failureMessage(for reason: HotkeyRegistrationFailureReason) -> String {
        switch reason {
        case .duplicateBinding:
            return "Failed to register: this key combination is already assigned to another OmniWM command"
        case .systemReserved:
            return "Failed to register: this key combination may be reserved by the system"
        case .requiresInputMonitoring:
            return "Left/Right-specific shortcuts need Input Monitoring permission to work"
        }
    }
}

private struct HotkeyScopeText: View {
    let compatibility: LayoutCompatibility

    var body: some View {
        Text("Scope: \(compatibility.rawValue)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct HotkeyBindingControl: View {
    let binding: HotkeyTrigger
    let commandName: String
    let isRecordingChord: Bool
    let isHyperActive: () -> Bool
    let onStartChordRecording: () -> Void
    let onCaptured: (KeyBinding) -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onSetSide: (ModifierSide) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRecordingChord {
                KeyRecorderView(
                    accessibilityLabel: "Recording hotkey for \(commandName)",
                    isHyperActive: isHyperActive,
                    onCapture: onCaptured,
                    onCancel: onCancel
                )
                .frame(minWidth: 180, idealWidth: 210, minHeight: 34)
                .accessibilityHint("Press Escape to cancel recording")
            } else {
                HStack(spacing: 6) {
                    Button {
                        onStartChordRecording()
                    } label: {
                        Text(displayString)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .frame(minWidth: 112, alignment: .center)
                    }
                    .buttonStyle(.bordered)
                    .help("Change hotkey for \(commandName). Current shortcut: \(humanReadableString)")
                    .accessibilityLabel("Change hotkey for \(commandName)")
                    .accessibilityValue(humanReadableString)
                }

                if !binding.isUnassigned {
                    Button {
                        onRemove()
                    } label: {
                        Label("Clear hotkey for \(commandName)", systemImage: "xmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this hotkey")
                    .accessibilityLabel("Clear hotkey for \(commandName)")
                }

                if let chord = binding.chordBinding, chord.modifiers != 0 {
                    Picker(
                        "Modifier side",
                        selection: Binding(get: { chord.side }, set: { onSetSide($0) })
                    ) {
                        Text("Either").tag(ModifierSide.either)
                        Text("Left").tag(ModifierSide.left)
                        Text("Right").tag(ModifierSide.right)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Restrict this shortcut to the left or right side of its modifier keys")
                    .accessibilityLabel("Modifier side for \(commandName)")
                    .accessibilityValue(sideAccessibilityValue(chord.side))
                }
            }
        }
    }

    private func sideAccessibilityValue(_ side: ModifierSide) -> String {
        switch side {
        case .either: "Either side"
        case .left: "Left side"
        case .right: "Right side"
        }
    }

    private var displayString: String {
        HotkeySettingsDisplayModel.displayString(for: binding)
    }

    private var humanReadableString: String {
        HotkeySettingsDisplayModel.humanReadableString(for: binding)
    }
}
