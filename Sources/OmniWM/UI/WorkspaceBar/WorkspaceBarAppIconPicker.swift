// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct WorkspaceBarAppIconPickerRequest: Identifiable {
    let id = UUID()
    let bundleId: String
    let displayName: String
    let preferredBundleURL: URL?
    let clearsBundleIdField: Bool
}

struct WorkspaceBarAppIconPicker: View {
    let request: WorkspaceBarAppIconPickerRequest
    let discovery: WorkspaceBarAppIconDiscovery
    let select: (WorkspaceBarIconOverrideSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result: WorkspaceBarAppIconDiscoveryResult?
    @State private var isLoading = true

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose an App-Provided Icon")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(request.displayName)
                    .foregroundStyle(.secondary)
            }

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Finding icons in the app bundle…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if result?.bundleURL == nil {
                    emptyState(
                        title: "App Bundle Not Found",
                        detail: "Choose an image file instead."
                    )
                } else if result?.candidates.isEmpty != false {
                    emptyState(
                        title: "No App-Provided Icons Found",
                        detail: "This app may create its Dock icon only while running."
                    )
                } else if let candidates = result?.candidates {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(candidates) { candidate in
                                Button {
                                    select(.bundleResource(candidate.resourceName))
                                    dismiss()
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(nsImage: candidate.image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 64, height: 64)
                                            .accessibilityHidden(true)

                                        Text(candidate.resourceName)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity)
                                    .background(.quaternary.opacity(0.45))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Use \(candidate.resourceName)")
                                .help("Use \(candidate.resourceName)")
                            }
                        }
                        .padding(2)
                    }
                }
            }

            Divider()

            HStack {
                Button("Choose Image File…") {
                    guard let selectedURL = WorkspaceBarIconImagePicker.selectImage() else {
                        return
                    }
                    select(.file(selectedURL.standardizedFileURL.path))
                    dismiss()
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .task(id: request.id) {
            isLoading = true
            let discovered = await discovery.discover(
                bundleId: request.bundleId,
                preferredBundleURL: request.preferredBundleURL
            )
            guard !Task.isCancelled else { return }
            result = discovered
            isLoading = false
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
