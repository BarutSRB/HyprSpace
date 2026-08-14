// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI

enum LaunchPermissionKind: CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: Self {
        self
    }

    var isRequired: Bool {
        self != .screenRecording
    }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .screenRecording: "Screen Recording"
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: "macwindow"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "rectangle.inset.filled"
        }
    }

    var detail: String {
        switch self {
        case .accessibility:
            "Lets OmniWM inspect, focus, move, and resize windows. Window management cannot start without it."
        case .inputMonitoring:
            "Lets OmniWM receive global keyboard, mouse, and trackpad input. Window management cannot start without it."
        case .screenRecording:
            "Enables Overview thumbnails, drag previews, and captured Hidden Bar glyphs. These visuals are unavailable without it; a restart may be required after granting access."
        }
    }

    var settingsURL: URL? {
        let pane = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")
    }
}

struct LaunchPermissionSnapshot: Equatable {
    var accessibilityGranted: Bool
    var inputMonitoringGranted: Bool
    var screenRecordingGranted: Bool

    var requiredGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    var allGranted: Bool {
        requiredGranted && screenRecordingGranted
    }

    func isGranted(_ kind: LaunchPermissionKind) -> Bool {
        switch kind {
        case .accessibility: accessibilityGranted
        case .inputMonitoring: inputMonitoringGranted
        case .screenRecording: screenRecordingGranted
        }
    }
}

struct LaunchPermissionEnvironment {
    let accessibilityGranted: @MainActor () -> Bool
    let requestAccessibility: @MainActor () -> Void
    let inputMonitoringGranted: @MainActor () -> Bool
    let requestInputMonitoring: @MainActor () -> Void
    let screenRecordingGranted: @MainActor () -> Bool
    let requestScreenRecording: @MainActor () -> Void

    @MainActor
    static var live: Self {
        Self(
            accessibilityGranted: AXIsProcessTrusted,
            requestAccessibility: {
                let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
                _ = AXIsProcessTrustedWithOptions(options)
            },
            inputMonitoringGranted: HotkeyCenter.inputMonitoringAccessGranted,
            requestInputMonitoring: { _ = HotkeyCenter.requestInputMonitoringAccess() },
            screenRecordingGranted: CGPreflightScreenCaptureAccess,
            requestScreenRecording: { _ = CGRequestScreenCaptureAccess() }
        )
    }

    @MainActor
    func snapshot() -> LaunchPermissionSnapshot {
        LaunchPermissionSnapshot(
            accessibilityGranted: accessibilityGranted(),
            inputMonitoringGranted: inputMonitoringGranted(),
            screenRecordingGranted: screenRecordingGranted()
        )
    }
}

@MainActor @Observable
final class LaunchPermissionsModel {
    private(set) var snapshot: LaunchPermissionSnapshot
    @ObservationIgnored private let environment: LaunchPermissionEnvironment

    init(environment: LaunchPermissionEnvironment = .live) {
        self.environment = environment
        snapshot = environment.snapshot()
    }

    var primaryActionTitle: String {
        snapshot.screenRecordingGranted ? "Start OmniWM" : "Continue Without Screen Recording"
    }

    func refresh() {
        snapshot = environment.snapshot()
    }

    func request(_ kind: LaunchPermissionKind) {
        switch kind {
        case .accessibility: environment.requestAccessibility()
        case .inputMonitoring: environment.requestInputMonitoring()
        case .screenRecording: environment.requestScreenRecording()
        }
        refresh()
    }
}

@MainActor
final class LaunchPermissionsWindowController {
    private let presenter: HostedWindowPresenter
    private let model: LaunchPermissionsModel
    private var startAction: (@MainActor () -> Void)?
    private var quitAction: (@MainActor () -> Void)?

    init(
        environment: LaunchPermissionEnvironment = .live,
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        presenter = HostedWindowPresenter(ownedWindowRegistry: ownedWindowRegistry)
        model = LaunchPermissionsModel(environment: environment)
    }

    var snapshot: LaunchPermissionSnapshot {
        model.snapshot
    }

    func show(
        onStart: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        startAction = onStart
        quitAction = onQuit
        model.refresh()
        presenter.present(
            title: "OmniWM Permissions",
            styleMask: [.titled, .resizable],
            contentSize: NSSize(width: 640, height: 500),
            minSize: NSSize(width: 640, height: 500),
            configure: { window in
                window.collectionBehavior = [.moveToActiveSpace]
            },
            onWillClose: { [weak self] in
                self?.clearActions()
            },
            content: {
                LaunchPermissionsView(
                    model: model,
                    onStart: { [weak self] in self?.start() },
                    onQuit: { [weak self] in self?.quit() }
                )
            }
        )
    }

    private func start() {
        model.refresh()
        guard model.snapshot.requiredGranted, let startAction else { return }
        clearActions()
        presenter.close()
        startAction()
    }

    private func quit() {
        guard let quitAction else { return }
        clearActions()
        presenter.close()
        quitAction()
    }

    private func clearActions() {
        startAction = nil
        quitAction = nil
    }
}

struct LaunchPermissionsView: View {
    @Bindable var model: LaunchPermissionsModel
    let onStart: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("OmniWM Permissions", systemImage: "checkmark.shield")
                    .font(.title2.bold())
                    .accessibilityHeading(.h1)
                Text("Grant the required permissions to start OmniWM. Screen Recording is optional.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(LaunchPermissionKind.allCases) { kind in
                        LaunchPermissionRow(
                            kind: kind,
                            granted: model.snapshot.isGranted(kind),
                            onRequest: { model.request(kind) }
                        )
                    }
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Quit OmniWM", action: onQuit)
                Spacer()
                Button("Check Again", action: model.refresh)
                Button(model.primaryActionTitle, action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.snapshot.requiredGranted)
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 500)
        .background(.background)
        .onAppear(perform: model.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

private struct LaunchPermissionRow: View {
    let kind: LaunchPermissionKind
    let granted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(kind.title).font(.headline)
                    Text(kind.isRequired ? "Required" : "Optional")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(kind.isRequired ? Color.orange : Color.secondary)
                }
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Label(
                    granted ? "Granted" : "Not Granted",
                    systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(granted ? Color.green : Color.orange)

                if !granted {
                    HStack(spacing: 6) {
                        Button("Grant Access", action: onRequest)
                            .accessibilityLabel("Grant \(kind.title) access")
                        if let settingsURL = kind.settingsURL {
                            Button("Open Settings") {
                                NSWorkspace.shared.open(settingsURL)
                            }
                            .accessibilityLabel("Open \(kind.title) settings")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
