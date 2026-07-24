// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import OmniWMIPC
import SwiftUI

@MainActor
enum WorkspaceConfigurationDeletePolicy {
    static func canDelete(
        _ config: WorkspaceConfiguration,
        settings: SettingsStore,
        workspaceManager: WorkspaceManager
    ) -> Bool {
        if settings.workspaceConfigurations.count <= 1 {
            return false
        }
        guard let workspaceId = workspaceManager.workspaceId(named: config.name) else { return true }
        return workspaceManager.entries(in: workspaceId).isEmpty
    }

    static func deleteHelp(
        _ config: WorkspaceConfiguration,
        settings: SettingsStore,
        workspaceManager: WorkspaceManager
    ) -> String {
        if settings.workspaceConfigurations.count <= 1 {
            return "OmniWM requires at least one configured workspace"
        }
        guard let workspaceId = workspaceManager.workspaceId(named: config.name) else {
            return "Delete workspace"
        }
        return workspaceManager.entries(in: workspaceId).isEmpty ?
            "Delete workspace" :
            "Move or close all windows in this workspace before deleting it"
    }
}

enum WorkspaceConfigurationAddPolicy {
    static func nextAvailableWorkspaceName(in configurations: [WorkspaceConfiguration]) -> String {
        WorkspaceIDPolicy.lowestUnusedRawID(in: configurations.map(\.name))
    }

    static let addButtonHelp = "Add the lowest unused workspace ID"
    static let footerText =
        "Workspace IDs use positive numeric slots. Display Name stays editable. Direct workspace hotkeys remain limited to 1-9; add 10+ here or through IPC/CLI."
}

struct WorkspacesSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var editingConfig: WorkspaceConfiguration?
    @State private var isAddingNew = false
    @State private var pendingDeleteConfig: WorkspaceConfiguration?
    @State private var connectedMonitors: [Monitor] = Monitor.sortedByPosition(Monitor.current())

    var body: some View {
        Form {
            Section("Default Layout") {
                Picker("Layout Algorithm", selection: $settings.defaultLayoutType) {
                    ForEach(LayoutType.allCases.filter { $0 != .defaultLayout }) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .onChange(of: settings.defaultLayoutType) { _, _ in
                    controller.updateWorkspaceConfig()
                }
            }

            Section {
                if settings.workspaceConfigurations.isEmpty {
                    Text("No workspaces configured")
                        .foregroundColor(.secondary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(sortedConfigurations) { config in
                        WorkspaceConfigurationRow(
                            configuration: config,
                            connectedMonitors: connectedMonitors,
                            canDelete: canDeleteConfiguration(config),
                            deleteHelp: deleteConfigurationHelp(config),
                            onEdit: { editingConfig = config },
                            onDelete: { pendingDeleteConfig = config }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Workspace Configurations")
                    Spacer()
                    Button(action: { isAddingNew = true }) {
                        Label("Add workspace", systemImage: "plus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help(addButtonHelp)
                    .accessibilityLabel("Add workspace")
                }
            } footer: {
                Text(WorkspaceConfigurationAddPolicy.footerText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingConfig) { config in
            WorkspaceEditSheet(
                configuration: config,
                isNew: false,
                connectedMonitors: connectedMonitors,
                onSave: { updated in
                    updateConfiguration(updated)
                    editingConfig = nil
                },
                onCancel: { editingConfig = nil }
            )
        }
        .sheet(isPresented: $isAddingNew) {
            WorkspaceEditSheet(
                configuration: WorkspaceConfiguration(
                    name: WorkspaceConfigurationAddPolicy
                        .nextAvailableWorkspaceName(in: settings.workspaceConfigurations),
                    monitorAssignment: .main
                ),
                isNew: true,
                connectedMonitors: connectedMonitors,
                onSave: { newConfig in
                    addConfiguration(newConfig)
                    isAddingNew = false
                },
                onCancel: { isAddingNew = false }
            )
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: isConfirmingDelete,
            presenting: pendingDeleteConfig
        ) { config in
            Button("Delete Workspace", role: .destructive) {
                deleteConfiguration(config)
            }
            Button("Cancel", role: .cancel) {}
        } message: { config in
            Text(deleteConfirmationMessage(for: config))
        }
    }

    private var sortedConfigurations: [WorkspaceConfiguration] {
        settings.workspaceConfigurations.sorted { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(
            get: { pendingDeleteConfig != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteConfig = nil
                }
            }
        )
    }

    private var addButtonHelp: String {
        WorkspaceConfigurationAddPolicy.addButtonHelp
    }

    private func deleteConfirmationMessage(for config: WorkspaceConfiguration) -> String {
        let matchingRuleCount = settings.appRules.count { $0.assignToWorkspace == config.name }
        guard matchingRuleCount > 0 else {
            return "Delete workspace \(config.effectiveDisplayName)?"
        }
        let ruleText = matchingRuleCount == 1 ? "1 app rule" : "\(matchingRuleCount) app rules"
        return "Delete workspace \(config.effectiveDisplayName)? This also clears workspace assignments from \(ruleText)."
    }

    private func canDeleteConfiguration(_ config: WorkspaceConfiguration) -> Bool {
        WorkspaceConfigurationDeletePolicy.canDelete(
            config,
            settings: settings,
            workspaceManager: controller.workspaceManager
        )
    }

    private func deleteConfigurationHelp(_ config: WorkspaceConfiguration) -> String {
        WorkspaceConfigurationDeletePolicy.deleteHelp(
            config,
            settings: settings,
            workspaceManager: controller.workspaceManager
        )
    }

    private func addConfiguration(_ config: WorkspaceConfiguration) {
        settings.workspaceConfigurations.append(config)
        settings.workspaceConfigurations.sort { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
        controller.updateWorkspaceConfig()
    }

    private func updateConfiguration(_ config: WorkspaceConfiguration) {
        if let index = settings.workspaceConfigurations.firstIndex(where: { $0.id == config.id }) {
            settings.workspaceConfigurations[index] = config
            settings.workspaceConfigurations.sort { WorkspaceIDPolicy.sortsBefore($0.name, $1.name) }
            controller.updateWorkspaceConfig()
        }
    }

    private func deleteConfiguration(_ config: WorkspaceConfiguration) {
        guard canDeleteConfiguration(config) else { return }
        settings.workspaceConfigurations.removeAll { $0.id == config.id }
        for index in settings.appRules.indices where settings.appRules[index].assignToWorkspace == config.name {
            settings.appRules[index].assignToWorkspace = nil
        }
        controller.updateWorkspaceConfig()
        controller.updateAppRules()
    }
}

struct WorkspaceConfigurationRow: View {
    let configuration: WorkspaceConfiguration
    let connectedMonitors: [Monitor]
    let canDelete: Bool
    let deleteHelp: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("WS \(configuration.name)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text(configuration.effectiveDisplayName)
                        .font(.body.weight(.medium))
                }
            }
            .frame(minWidth: 60, alignment: .leading)

            Divider()
                .frame(height: 24)

            Text(monitorDisplayName(configuration.monitorAssignment))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 70, alignment: .leading)

            Divider()
                .frame(height: 24)

            Text(configuration.layoutType.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(4)

            Spacer()

            Button(action: onEdit) {
                Label("Edit \(configuration.effectiveDisplayName)", systemImage: "pencil.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help("Edit workspace configuration")
            .accessibilityLabel("Edit \(configuration.effectiveDisplayName)")

            Button(action: onDelete) {
                Label("Delete \(configuration.effectiveDisplayName)", systemImage: "trash.circle")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help(deleteHelp)
            .disabled(!canDelete)
        }
        .padding(.vertical, 4)
    }

    private func monitorDisplayName(_ assignment: MonitorAssignment) -> String {
        switch assignment {
        case .main:
            return "Main"
        case .secondary:
            return "Secondary"
        case let .specificDisplay(output):
            if let monitor = output.resolveMonitor(in: connectedMonitors) {
                return monitor.name
            }
            return "\(output.name) (Disconnected)"
        }
    }
}

struct WorkspaceEditSheet: View {
    @State private var configuration: WorkspaceConfiguration
    let isNew: Bool
    let connectedMonitors: [Monitor]
    let onSave: (WorkspaceConfiguration) -> Void
    let onCancel: () -> Void

    init(
        configuration: WorkspaceConfiguration,
        isNew: Bool,
        connectedMonitors: [Monitor],
        onSave: @escaping (WorkspaceConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _configuration = State(initialValue: configuration)
        self.isNew = isNew
        self.connectedMonitors = connectedMonitors
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "Add Workspace" : "Edit Workspace")
                .font(.headline)

            Form {
                LabeledContent("Workspace ID") {
                    Text(configuration.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                TextField("Display Name (optional)", text: Binding(
                    get: { configuration.displayName ?? "" },
                    set: { configuration.displayName = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Picker("Home Monitor", selection: $configuration.monitorAssignment) {
                    Text("Main").tag(MonitorAssignment.main)
                    Text("Secondary").tag(MonitorAssignment.secondary)
                    Divider()
                    if case let .specificDisplay(output) = configuration.monitorAssignment,
                       output.resolveMonitor(in: connectedMonitors) == nil
                    {
                        Text("Unavailable: \(output.name)")
                            .tag(configuration.monitorAssignment)
                        Divider()
                    }
                    ForEach(connectedMonitors, id: \.id) { monitor in
                        HStack {
                            Text(monitor.name)
                            if monitor.isMain {
                                Text("(Main)").foregroundColor(.secondary)
                            }
                            if monitor.displayUUID == nil {
                                Text("(Session only)").foregroundColor(.secondary)
                            }
                        }
                        .tag(MonitorAssignment.specificDisplay(OutputId(from: monitor)))
                    }
                }

                Text(
                    "Main follows the current main display. Secondary follows the first non-main display. Specific Display pins this workspace to the selected monitor when available."
                )
                .font(.caption)
                .foregroundColor(.secondary)

                Picker("Layout", selection: $configuration.layoutType) {
                    ForEach(LayoutType.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isNew ? "Add" : "Save") {
                    onSave(configuration)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }
}
