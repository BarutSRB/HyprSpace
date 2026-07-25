// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct AppRuleDetailView: View {
    @Binding var rule: AppRule
    let workspaceNames: [String]
    let controller: WMController
    let editorState: AppRulesEditorState
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void
    let onDelete: () -> Void

    @State private var draft: AppRuleDraft
    @State private var isAdvancedMatchersExpanded: Bool

    init(
        rule: Binding<AppRule>,
        workspaceNames: [String],
        controller: WMController,
        editorState: AppRulesEditorState,
        onCreateRuleFromSnapshot: @escaping (WindowDecisionDebugSnapshot) -> Void,
        onDelete: @escaping () -> Void
    ) {
        _rule = rule
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.editorState = editorState
        self.onCreateRuleFromSnapshot = onCreateRuleFromSnapshot
        self.onDelete = onDelete

        let initialRule = rule.wrappedValue
        _draft = State(initialValue: AppRuleDraft(rule: initialRule))
        _isAdvancedMatchersExpanded = State(
            initialValue: AppRuleDraft(rule: initialRule).hasNarrowingMatchers ||
                controller.windowRuleEngine.invalidRegexMessagesByRuleId[initialRule.id] != nil
        )
    }

    private var isDirty: Bool {
        !draft.represents(rule)
    }

    var body: some View {
        Form {
            RuleApplicationSection(draft: $draft, controller: controller)
            RuleWindowBehaviorSection(draft: $draft, workspaceNames: workspaceNames)
            RuleMinimumSizeSection(draft: $draft)

            Section {
                DisclosureGroup("Advanced Matchers", isExpanded: $isAdvancedMatchersExpanded) {
                    AdvancedMatchersEditor(draft: $draft, regexError: titleRegexError)
                }
            }

            if let message = draft.identifierHint ?? draft.effectHint {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                FocusedWindowInspectorView(
                    controller: controller,
                    onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                )
            }

            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Rule", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { saveBar }
        .onChange(of: draft) { _, _ in editorState.isDirty = isDirty }
        .onChange(of: rule) { oldRule, newRule in
            if draft.represents(oldRule) {
                draft = AppRuleDraft(rule: newRule)
            }
            editorState.isDirty = isDirty
        }
        .onDisappear { editorState.isDirty = false }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            if isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") {
                draft = AppRuleDraft(rule: rule)
                editorState.isDirty = false
            }
            .disabled(!isDirty)
            Button("Save") {
                rule = draft.makeRule(id: rule.id)
                controller.updateAppRules()
                editorState.isDirty = false
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || !draft.isValid)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var titleRegexError: String? {
        guard draft.titleMatcherMode == .regex else { return nil }
        return controller.windowRuleEngine.invalidRegexMessagesByRuleId[rule.id] ?? draft.titleRegexError
    }
}

struct AppRuleAddSheet: View {
    let workspaceNames: [String]
    let controller: WMController
    let onSave: (AppRule) -> Void
    let onCancel: () -> Void

    @State private var draft: AppRuleDraft
    @State private var isAdvancedMatchersExpanded: Bool

    init(
        initialDraft: AppRuleDraft,
        workspaceNames: [String],
        controller: WMController,
        onSave: @escaping (AppRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceNames = workspaceNames
        self.controller = controller
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
        _isAdvancedMatchersExpanded = State(initialValue: initialDraft.hasNarrowingMatchers)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add App Rule")
                .font(.headline)

            Form {
                RuleApplicationSection(draft: $draft, controller: controller)
                RuleWindowBehaviorSection(draft: $draft, workspaceNames: workspaceNames)
                RuleMinimumSizeSection(draft: $draft)

                Section {
                    DisclosureGroup("Advanced Matchers", isExpanded: $isAdvancedMatchersExpanded) {
                        AdvancedMatchersEditor(draft: $draft, regexError: draft.titleRegexError)
                    }
                }
            }
            .formStyle(.grouped)

            if let message = draft.effectHint {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    onSave(draft.makeRule())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding()
        .frame(minWidth: 520)
    }
}

struct RuleWindowBehaviorSection: View {
    @Binding var draft: AppRuleDraft
    let workspaceNames: [String]

    var body: some View {
        Section("Window Behavior") {
            Picker("Layout", selection: $draft.layoutAction) {
                ForEach(WindowRuleLayoutAction.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Assign to Workspace", isOn: $draft.assignToWorkspaceEnabled)
                .onChange(of: draft.assignToWorkspaceEnabled) { _, enabled in
                    guard enabled else { return }
                    seedWorkspaceIfNeeded()
                }

            if draft.assignToWorkspaceEnabled {
                Picker("Workspace", selection: $draft.assignToWorkspace) {
                    ForEach(workspaceNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if isWorkspaceMissing {
                        Text("\(draft.assignToWorkspace) (missing)").tag(draft.assignToWorkspace)
                    }
                }
                .disabled(workspaceNames.isEmpty)

                if workspaceNames.isEmpty {
                    SettingsCaption("No workspaces configured. Add workspaces in Settings.")
                } else if isWorkspaceMissing {
                    Text("Workspace \"\(draft.assignToWorkspace)\" no longer exists. Pick another.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Toggle("Initial Container Primary Span", isOn: $draft.initialContainerPrimarySpanEnabled)
            if draft.initialContainerPrimarySpanEnabled {
                LabeledContent("Primary Span") {
                    HStack {
                        TextField(
                            "Initial Container Primary Span",
                            value: initialContainerPrimarySpanPercent,
                            format: .number.precision(.significantDigits(1 ... 15)).grouping(.never)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Initial container primary span percentage")
                        .accessibilityValue(initialContainerPrimarySpanAccessibilityValue)
                        .accessibilityHint(initialContainerPrimarySpanAccessibilityHint)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = draft.initialContainerPrimarySpanError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsCaption(
                "Only affects resizable windows in Niri when they create or claim a container. "
                    + "Primary span is width in horizontal orientation and height in vertical orientation."
            )
        }
    }

    private var initialContainerPrimarySpanPercent: Binding<Double> {
        Binding(
            get: { AppRuleInitialContainerPrimarySpanPercent.percent(from: draft.initialContainerPrimarySpan) },
            set: { percent in
                draft.initialContainerPrimarySpan = AppRuleInitialContainerPrimarySpanPercent.proportion(from: percent)
            }
        )
    }

    private var initialContainerPrimarySpanAccessibilityValue: String {
        let value = AppRuleInitialContainerPrimarySpanPercent.displayText(for: draft.initialContainerPrimarySpan) + " percent"
        guard draft.initialContainerPrimarySpanError != nil else { return value }
        return value + ", invalid"
    }

    private var initialContainerPrimarySpanAccessibilityHint: String {
        let range = "Enter a value from 5 through 100 percent."
        guard let error = draft.initialContainerPrimarySpanError else { return range }
        return error + ". " + range
    }

    private var isWorkspaceMissing: Bool {
        draft.assignToWorkspaceEnabled &&
            !draft.assignToWorkspace.isEmpty &&
            !workspaceNames.contains(draft.assignToWorkspace)
    }

    private func seedWorkspaceIfNeeded() {
        if draft.assignToWorkspace.isEmpty, let first = workspaceNames.first {
            draft.assignToWorkspace = first
        }
    }
}

struct RuleMinimumSizeSection: View {
    @Binding var draft: AppRuleDraft

    var body: some View {
        Section("Minimum Size (Layout Constraint)") {
            Toggle("Minimum Width", isOn: $draft.minWidthEnabled)
            if draft.minWidthEnabled {
                HStack {
                    TextField("Width", value: $draft.minWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Minimum Height", isOn: $draft.minHeightEnabled)
            if draft.minHeightEnabled {
                HStack {
                    TextField("Height", value: $draft.minHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = draft.minSizeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            SettingsCaption("Prevents the layout engine from sizing the window smaller than these values.")
        }
    }
}

struct AdvancedMatchersEditor: View {
    @Binding var draft: AppRuleDraft
    let regexError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCaption("Narrow a rule to specific windows within an app.")

            Picker("Title Match", selection: $draft.titleMatcherMode) {
                ForEach(TitleMatcherMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            switch draft.titleMatcherMode {
            case .none:
                EmptyView()
            case .substring:
                TextField("Title contains", text: $draft.titleSubstring)
                    .textFieldStyle(.roundedBorder)
            case .regex:
                TextField("Title regex", text: $draft.titleRegex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let regexError {
                    Text("Title regex is invalid: \(regexError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("AX Role", isOn: $draft.axRoleEnabled)
            if draft.axRoleEnabled {
                TextField("e.g. AXWindow", text: $draft.axRole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Toggle("AX Subrole", isOn: $draft.axSubroleEnabled)
            if draft.axSubroleEnabled {
                TextField("e.g. AXStandardWindow", text: $draft.axSubrole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
    }
}

struct FocusedWindowInspectorView: View {
    let controller: WMController
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    @State private var snapshot: WindowDecisionDebugSnapshot?
    @State private var isTroubleshootingExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Focused Window Inspector")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        refreshSnapshot()
                    }
                }

                if let snapshot {
                    Button("New Rule from Focused Window") {
                        onCreateRuleFromSnapshot(snapshot)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(AppRuleDraft.guided(from: snapshot) == nil)

                    DisclosureGroup("Advanced / Troubleshooting", isExpanded: $isTroubleshootingExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView(.vertical) {
                                Text(snapshot.formattedDump())
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 140, maxHeight: 220)

                            Button("Copy Debug Dump") {
                                controller.copyDebugDump(snapshot)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                } else {
                    SettingsCaption("No focused window is available for inspection.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() {
        snapshot = controller.focusedWindowDecisionDebugSnapshot()
    }
}
