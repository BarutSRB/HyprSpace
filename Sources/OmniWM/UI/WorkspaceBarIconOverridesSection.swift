// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum WorkspaceBarIconOverrideEdits {
    @discardableResult
    static func applySelection(
        _ selectedURL: URL?,
        bundleID: String,
        settings: SettingsStore,
        refresh: (Bool) -> Void
    ) -> Bool {
        guard let selectedURL,
              let bundleID = WorkspaceBarAppCandidates.normalizedBundleID(bundleID)
        else {
            return false
        }

        return applySource(
            .file(selectedURL.standardizedFileURL.path),
            bundleID: bundleID,
            settings: settings,
            refresh: refresh
        )
    }

    @discardableResult
    static func applySource(
        _ source: WorkspaceBarIconOverrideSource,
        bundleID: String,
        settings: SettingsStore,
        refresh: (Bool) -> Void
    ) -> Bool {
        guard let bundleID = WorkspaceBarAppCandidates.normalizedBundleID(bundleID) else {
            return false
        }

        let changed = settings.setWorkspaceBarIconOverride(source.storedValue, for: bundleID)
        refresh(true)
        return changed
    }

    @discardableResult
    static func remove(
        bundleID: String,
        settings: SettingsStore,
        refresh: (Bool) -> Void
    ) -> Bool {
        guard settings.removeWorkspaceBarIconOverride(for: bundleID) else {
            return false
        }
        refresh(false)
        return true
    }
}

@MainActor
enum WorkspaceBarIconImagePicker {
    static func selectImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct WorkspaceBarIconOverridesSection: View {
    @Bindable var settings: SettingsStore
    let controller: WMController

    @State private var newBundleID = ""
    @State private var iconPickerRequest: WorkspaceBarAppIconPickerRequest?
    @State private var iconDiscovery = WorkspaceBarAppIconDiscovery()

    private var candidates: [WorkspaceBarAppCandidate] {
        WorkspaceBarAppCandidates.build(
            controller: controller,
            configuredBundleIDs: Array(settings.workspaceBarIconOverrides.keys)
        )
    }

    var body: some View {
        Section("App Icon Overrides — All Monitors") {
            SettingsCaption(
                "Choose an icon packaged inside an app, or select an image file. Runtime-generated "
                    + "Dock icons may not be available. Other OmniWM surfaces keep the standard icon."
            )

            if candidates.isEmpty {
                SettingsCaption("No managed apps with bundle IDs are currently available.")
            } else {
                ForEach(candidates) { candidate in
                    WorkspaceBarIconOverrideRow(
                        candidate: candidate,
                        configuredValue: settings.workspaceBarIconOverrideValue(
                            for: candidate.bundleID
                        ),
                        resolution: controller.workspaceBarIconResolver.overrideResolution(
                            for: candidate.bundleID
                        ),
                        resolutionRevision: controller.workspaceBarIconResolutionRevision,
                        choose: {
                            presentPicker(for: candidate)
                        },
                        remove: {
                            removeOverride(for: candidate.bundleID)
                        }
                    )
                }
            }

            HStack {
                TextField("Bundle ID", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)

                Button("Choose…") {
                    presentPicker(for: newBundleID)
                }
                .disabled(
                    WorkspaceBarAppCandidates.normalizedBundleID(newBundleID) == nil
                )
            }
        }
        .sheet(item: $iconPickerRequest) { request in
            WorkspaceBarAppIconPicker(
                request: request,
                discovery: iconDiscovery,
                select: { source in
                    apply(source, for: request)
                }
            )
        }
    }

    private func presentPicker(for candidate: WorkspaceBarAppCandidate) {
        iconPickerRequest = WorkspaceBarAppIconPickerRequest(
            bundleId: candidate.bundleID,
            displayName: candidate.name ?? candidate.bundleID,
            preferredBundleURL: candidate.bundleURL,
            clearsBundleIdField: false
        )
    }

    private func presentPicker(for rawBundleId: String) {
        guard let bundleId = WorkspaceBarAppCandidates.normalizedBundleID(rawBundleId) else {
            return
        }
        iconPickerRequest = WorkspaceBarAppIconPickerRequest(
            bundleId: bundleId,
            displayName: bundleId,
            preferredBundleURL: nil,
            clearsBundleIdField: true
        )
    }

    private func apply(
        _ source: WorkspaceBarIconOverrideSource,
        for request: WorkspaceBarAppIconPickerRequest
    ) {
        WorkspaceBarIconOverrideEdits.applySource(
            source,
            bundleID: request.bundleId,
            settings: settings,
            refresh: { forceIconReload in
                controller.updateWorkspaceBarIconOverride(
                    bundleId: request.bundleId,
                    forceReload: forceIconReload
                )
            }
        )
        if request.clearsBundleIdField {
            newBundleID = ""
        }
    }

    private func removeOverride(for bundleID: String) {
        WorkspaceBarIconOverrideEdits.remove(
            bundleID: bundleID,
            settings: settings,
            refresh: { forceIconReload in
                controller.updateWorkspaceBarIconOverride(
                    bundleId: bundleID,
                    forceReload: forceIconReload
                )
            }
        )
    }
}

private struct WorkspaceBarIconOverrideRow: View {
    let candidate: WorkspaceBarAppCandidate
    let configuredValue: String?
    let resolution: WorkspaceBarIconResolver.OverrideResolution?
    let resolutionRevision: UInt64
    let choose: () -> Void
    let remove: () -> Void

    private var hasOverride: Bool {
        configuredValue != nil
    }

    private var previewImage: NSImage? {
        resolution?.image ?? candidate.icon
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                }
            }
            .id(resolutionRevision)
            .scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
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

                if let value = resolution?.displayValue
                    ?? configuredValue.flatMap({
                        WorkspaceBarIconOverrideSource(storedValue: $0)?.displayValue
                    })
                {
                    Text(value)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(value)
                }

                if hasOverride, resolution?.image == nil {
                    Label(
                        "Image is unavailable; using the app's standard icon.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button(hasOverride ? "Replace…" : "Choose…", action: choose)
                if hasOverride {
                    Button("Remove", action: remove)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
