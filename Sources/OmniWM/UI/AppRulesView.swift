// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct AppRulesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let editorState: AppRulesEditorState

    @State private var selectedRuleId: AppRule.ID?
    @State private var addDraft: AppRuleDraft?
    @State private var pendingDeleteRule: AppRule?
    @State private var searchText = ""
    @State private var pendingSelection: AppRule.ID?
    @State private var isConfirmingDiscard = false

    var body: some View {
        NavigationSplitView {
            AppRulesSidebar(
                rules: settings.appRules,
                searchText: $searchText,
                selection: selectionBinding,
                onAdd: { presentNewRule() },
                onDelete: { pendingDeleteRule = $0 },
                onMove: moveHandler
            )
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $addDraft, content: addSheet)
        .confirmationDialog(
            "Delete app rule?",
            isPresented: isConfirmingDelete,
            presenting: pendingDeleteRule
        ) { rule in
            Button("Delete Rule", role: .destructive) {
                deleteRule(rule)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("Delete the rule for \(rule.displayLabel)?")
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $isConfirmingDiscard
        ) {
            Button("Discard Changes", role: .destructive) {
                editorState.isDirty = false
                selectedRuleId = pendingSelection
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved changes to this app rule.")
        }
        .frame(minWidth: 880, minHeight: 680)
    }

    private var selectionBinding: Binding<AppRule.ID?> {
        Binding(
            get: { selectedRuleId },
            set: { newValue in
                if editorState.isDirty {
                    pendingSelection = newValue
                    isConfirmingDiscard = true
                } else {
                    selectedRuleId = newValue
                }
            }
        )
    }

    @ViewBuilder private var detailColumn: some View {
        if let ruleId = selectedRuleId,
           let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleId })
        {
            AppRuleDetailView(
                rule: $settings.appRules[ruleIndex],
                workspaceNames: workspaceNames,
                controller: controller,
                editorState: editorState,
                onCreateRuleFromSnapshot: presentNewRule(from:),
                onDelete: { pendingDeleteRule = settings.appRules[ruleIndex] }
            )
            .id(ruleId)
        } else {
            AppRulesEmptyState(
                controller: controller,
                onAdd: { presentNewRule() },
                onCreateRuleFromSnapshot: presentNewRule(from:)
            )
        }
    }

    private func addSheet(_ draft: AppRuleDraft) -> AppRuleAddSheet {
        AppRuleAddSheet(
            initialDraft: draft,
            workspaceNames: workspaceNames,
            controller: controller,
            onSave: { newRule in
                settings.appRules.append(newRule)
                controller.updateAppRules()
                selectedRuleId = newRule.id
                addDraft = nil
            },
            onCancel: { addDraft = nil }
        )
    }

    private var workspaceNames: [String] {
        settings.workspaceConfigurations.map(\.name)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard !isSearching else { return nil }
        return { source, destination in
            settings.appRules.move(fromOffsets: source, toOffset: destination)
            controller.updateAppRules()
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeleteRule != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRule = nil
                }
            }
        )
    }

    private func deleteRule(_ rule: AppRule) {
        settings.appRules.removeAll { $0.id == rule.id }
        controller.updateAppRules()
        if selectedRuleId == rule.id {
            selectedRuleId = nil
        }
    }

    private func presentNewRule(_ draft: AppRuleDraft = AppRuleDraft()) {
        addDraft = draft
    }

    private func presentNewRule(from snapshot: WindowDecisionDebugSnapshot) {
        guard let draft = AppRuleDraft.guided(from: snapshot) else { return }
        addDraft = draft
    }
}

struct AppRulesSidebar: View {
    let rules: [AppRule]
    @Binding var searchText: String
    @Binding var selection: AppRule.ID?
    let onAdd: () -> Void
    let onDelete: (AppRule) -> Void
    let onMove: ((IndexSet, Int) -> Void)?

    var body: some View {
        List(selection: $selection) {
            ForEach(filteredRules) { rule in
                AppRuleSidebarRow(rule: rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(rule)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .onMove(perform: onMove)

            if rules.count > 1, onMove != nil {
                Text("More specific rules win; ties break by order — drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("App Rules")
        .searchable(text: $searchText, prompt: "Search rules")
        .overlay {
            if !rules.isEmpty, filteredRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onAdd) {
                    Label("Add app rule", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add app rule")
                .accessibilityLabel("Add app rule")
            }
        }
        .navigationSplitViewColumnWidth(min: 440, ideal: 520, max: 680)
    }

    private var filteredRules: [AppRule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            if rule.displayLabel.lowercased().contains(query) { return true }
            if rule.bundleId.lowercased().contains(query) { return true }
            return [rule.appNameSubstring, rule.titleSubstring, rule.titleRegex, rule.axRole, rule.axSubrole]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }
}

struct AppRuleSidebarRow: View {
    let rule: AppRule

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    badges
                }
            }

            Spacer()

            Text(rule.specificity.formatted())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("Match specificity \(rule.specificity) — higher specificity wins; ties break by list order")
                .accessibilityLabel("Specificity \(rule.specificity)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var badges: some View {
        switch rule.effectiveLayoutAction {
        case .float:
            RuleBadge(text: "Float", color: .blue, accessibilityLabel: "Floating")
        case .tile:
            RuleBadge(text: "Tile", color: .teal, accessibilityLabel: "Tiled")
        case .auto:
            EmptyView()
        }
        if let workspace = rule.assignToWorkspace {
            RuleBadge(text: "WS", color: .green, accessibilityLabel: "Assigned to workspace \(workspace)")
        }
        if let width = rule.validInitialContainerPrimarySpan {
            let percent = AppRuleInitialContainerPrimarySpanPercent.displayText(for: width)
            RuleBadge(
                text: "Primary \(percent)%",
                color: .indigo,
                accessibilityLabel: "Initial Niri container primary span \(percent) percent"
            )
        } else if rule.initialContainerPrimarySpan != nil {
            RuleBadge(
                text: "Primary invalid",
                color: .red,
                accessibilityLabel: "Invalid initial Niri container primary span"
            )
        }
        if rule.minWidth != nil || rule.minHeight != nil {
            RuleBadge(text: "Size", color: .orange, accessibilityLabel: "Minimum size set")
        }
        if rule.hasAdvancedMatchers {
            RuleBadge(text: "Advanced", color: .purple, accessibilityLabel: "Advanced matchers")
        }
    }
}

struct AppRulesEmptyState: View {
    let controller: WMController
    let onAdd: () -> Void
    let onCreateRuleFromSnapshot: (WindowDecisionDebugSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("No App Rule Selected", systemImage: "app.badge.checkmark")
                } description: {
                    Text("Select a rule from the sidebar to edit it, or add a new rule to get started.")
                } actions: {
                    Button("Add Rule", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }

                FocusedWindowInspectorView(
                    controller: controller,
                    onCreateRuleFromSnapshot: onCreateRuleFromSnapshot
                )
                .frame(maxWidth: 560)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RuleBadge: View {
    let text: String
    let color: Color
    var accessibilityLabel: String?

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(accessibilityLabel ?? text)
    }
}
