// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct QuakeTerminalSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    private var blurValueText: String {
        settings.quakeTerminalBackgroundBlurRadius == QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
            ? "Off"
            : "\(settings.quakeTerminalBackgroundBlurRadius)"
    }

    var body: some View {
        Form {
            Section("Quake Terminal") {
                Toggle("Enable Quake Terminal", isOn: $settings.quakeTerminalEnabled)
                    .onChange(of: settings.quakeTerminalEnabled) { _, newValue in
                        controller.setQuakeTerminalEnabled(newValue)
                    }
            }

            if settings.quakeTerminalEnabled {
                Section("Position & Size") {
                    Picker("Position", selection: $settings.quakeTerminalPosition) {
                        ForEach(QuakeTerminalPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }

                    Picker("Show On", selection: $settings.quakeTerminalMonitorMode) {
                        ForEach(QuakeTerminalMonitorMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    SettingsSliderRow(
                        label: "Width",
                        value: $settings.quakeTerminalWidthPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminalWidthPercent))%"
                    )

                    SettingsSliderRow(
                        label: "Height",
                        value: $settings.quakeTerminalHeightPercent,
                        range: 10 ... 100,
                        step: 5,
                        valueText: "\(Int(settings.quakeTerminalHeightPercent))%"
                    )

                    if settings.quakeTerminalUseCustomFrame {
                        Button("Reset to Default Position") {
                            settings.resetQuakeTerminalCustomFrame()
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Background Effect", selection: $settings.quakeTerminalBackgroundEffect) {
                        ForEach(QuakeTerminalBackgroundEffect.allCases, id: \.self) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                    .onChange(of: settings.quakeTerminalBackgroundEffect) { _, _ in
                        controller.reloadQuakeTerminalBackgroundEffect()
                    }

                    SettingsSliderRow(
                        label: "Quake Background Opacity",
                        value: $settings.quakeTerminalOpacity,
                        range: 0.1 ... 1.0,
                        step: 0.05,
                        valueText: "\(Int(settings.quakeTerminalOpacity * 100))%"
                    )
                    .onChange(of: settings.quakeTerminalOpacity) { _, _ in
                        controller.reloadQuakeTerminalOpacity()
                    }

                    SettingsSliderRow(
                        label: "Background Blur",
                        value: Binding(
                            get: { Double(settings.quakeTerminalBackgroundBlurRadius) },
                            set: { settings.quakeTerminalBackgroundBlurRadius = Int($0.rounded()) }
                        ),
                        range: Double(QuakeTerminalAppearancePolicy.minimumBackgroundBlurRadius)
                            ... Double(QuakeTerminalAppearancePolicy.maximumBackgroundBlurRadius),
                        step: 5,
                        valueText: blurValueText
                    )
                    .onChange(of: settings.quakeTerminalBackgroundBlurRadius) { _, _ in
                        controller.reloadQuakeTerminalBackgroundBlur()
                    }
                    .disabled(settings.quakeTerminalBackgroundEffect != .standardBlur)

                    if settings.quakeTerminalBackgroundEffect != .standardBlur {
                        SettingsCaption(
                            "The saved Standard Blur radius is preserved and becomes active again when Standard Blur is selected."
                        )
                    } else if QuakeTerminalAppearancePolicy.backgroundBlurIsHiddenByOpaqueBackground(
                        radius: settings.quakeTerminalBackgroundBlurRadius,
                        opacity: settings.quakeTerminalOpacity
                    ) {
                        SettingsCaption("Blur only shows through a translucent terminal - lower the opacity to see it.")
                    }
                }

                Section("Behavior") {
                    SettingsSliderRow(
                        label: "Animation Duration",
                        value: $settings.quakeTerminalAnimationDuration,
                        range: 0 ... 1,
                        step: 0.1,
                        valueText: "\(String(format: "%.1f", settings.quakeTerminalAnimationDuration))s"
                    )
                    .disabled(!controller.motionPolicy.animationsEnabled)

                    if !controller.motionPolicy.animationsEnabled {
                        SettingsCaption("Ignored while global animations are disabled.")
                    }

                    Toggle("Auto-hide on Focus Loss", isOn: $settings.quakeTerminalAutoHide)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsCaption(
                        "Quake Terminal provides a drop-down terminal that can be toggled with a hotkey, similar to the console in Quake-style games."
                    )

                    Label("Default hotkey: Option + ` (backtick)", systemImage: "keyboard")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Label("Configure hotkey in Hotkeys settings", systemImage: "gearshape")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
