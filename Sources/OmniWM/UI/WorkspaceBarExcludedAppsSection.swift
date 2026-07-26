// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

@MainActor
enum WorkspaceBarExcludedAppsEdits {
    @discardableResult
    static func setExcluded(
        _ excluded: Bool,
        bundleID: String,
        settings: SettingsStore,
        refresh: () -> Void
    ) -> Bool {
        let changed = excluded
            ? settings.addWorkspaceBarExcludedBundleID(bundleID)
            : settings.removeWorkspaceBarExcludedBundleID(bundleID)
        guard changed else { return false }
        refresh()
        return true
    }
}

struct WorkspaceBarExcludedAppsSection: View {
    @Bindable var settings: SettingsStore
    let controller: WMController

    @State private var newBundleID = ""

    private var candidates: [WorkspaceBarAppCandidate] {
        WorkspaceBarAppCandidates.build(
            controller: controller,
            configuredBundleIDs: Array(settings.workspaceBarExcludedBundleIDs)
        )
    }

    var body: some View {
        Section("Excluded Apps — All Monitors") {
            SettingsCaption(
                "Excluded apps stay running and fully managed by OmniWM. Only their workspace-bar "
                    + "representation is removed on every monitor."
            )

            if candidates.isEmpty {
                SettingsCaption("No managed apps with bundle IDs are currently available.")
            } else {
                ForEach(candidates) { candidate in
                    Toggle(isOn: exclusionBinding(for: candidate.bundleID)) {
                        WorkspaceBarExcludedAppRow(candidate: candidate)
                    }
                }
            }

            HStack {
                TextField("Bundle ID", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addBundleID)

                Button("Add", action: addBundleID)
                    .disabled(!canAddBundleID)
            }
        }
    }

    private var canAddBundleID: Bool {
        guard let bundleID = WorkspaceBarAppCandidates.normalizedBundleID(newBundleID) else {
            return false
        }
        return !settings.workspaceBarExcludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.workspaceBarExcludedBundleIDs.contains {
                    $0.caseInsensitiveCompare(bundleID) == .orderedSame
                }
            },
            set: { excluded in
                WorkspaceBarExcludedAppsEdits.setExcluded(
                    excluded,
                    bundleID: bundleID,
                    settings: settings,
                    refresh: controller.requestWorkspaceBarRefresh
                )
            }
        )
    }

    private func addBundleID() {
        guard canAddBundleID,
              let bundleID = WorkspaceBarAppCandidates.normalizedBundleID(newBundleID),
              WorkspaceBarExcludedAppsEdits.setExcluded(
                  true,
                  bundleID: bundleID,
                  settings: settings,
                  refresh: controller.requestWorkspaceBarRefresh
              )
        else {
            return
        }
        newBundleID = ""
    }
}

private struct WorkspaceBarExcludedAppRow: View {
    let candidate: WorkspaceBarAppCandidate

    var body: some View {
        HStack(spacing: 8) {
            if let icon = candidate.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name ?? candidate.bundleID)
                if candidate.name != nil {
                    Text(candidate.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !candidate.isManaged {
                    Text("Not currently managed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
