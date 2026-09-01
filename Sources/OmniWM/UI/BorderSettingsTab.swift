// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct BorderSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    var body: some View {
        Form {
            Section("Window Borders") {
                Toggle("Enable Borders", isOn: $settings.bordersEnabled)
                    .onChange(of: settings.bordersEnabled) { _, _ in
                        controller.borderSettingsChanged()
                    }

                if settings.bordersEnabled {
                    SettingsSliderRow(
                        label: "Border Width",
                        value: $settings.borderWidth,
                        range: 1 ... 12,
                        step: 0.5,
                        valueText: String(format: "%.1f px", settings.borderWidth),
                        valueWidth: 56
                    )
                    .onChange(of: settings.borderWidth) { _, _ in
                        controller.borderSettingsChanged()
                    }

                    ColorPicker("Border Color", selection: colorBinding, supportsOpacity: true)
                }
            }

            Section("About") {
                Text("Borders are displayed around the currently focused window.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(
                    red: settings.borderColorRed,
                    green: settings.borderColorGreen,
                    blue: settings.borderColorBlue,
                    opacity: settings.borderColorAlpha
                )
            },
            set: { newColor in
                guard let converted = SettingsColor(color: newColor) else { return }
                settings.borderColor = converted
                controller.borderSettingsChanged()
            }
        )
    }
}
