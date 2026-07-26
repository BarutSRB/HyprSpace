// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MenuHeader: View {
    private var appVersion: String {
        Bundle.main.appVersion ?? "0.3.1"
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.3, green: 0.4, blue: 0.8).opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("OmniWM")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 6, height: 6)
                }
                Text("v\(appVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }
}

struct MenuSectionLabel: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 24, alignment: .bottom)
        .padding(.bottom, 2)
    }
}

struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .frame(height: 9)
    }
}

struct MenuInfoRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

struct MenuActionRow: View {
    let icon: String
    let label: String
    var showChevron = false
    var isExternal = false
    var isDestructive = false
    let action: @MainActor () -> Void

    @Environment(MotionPolicy.self) private var motionPolicy
    @Environment(\.statusMenuDismiss) private var dismissMenu
    @State private var isHovered = false

    var body: some View {
        Button {
            dismissMenu(then: action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(labelColor)
                Spacer(minLength: 0)
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                if isExternal {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .onHover { isHovered = $0 }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isHovered)
    }

    private var backgroundColor: Color {
        guard isHovered else { return .clear }
        return isDestructive
            ? Color(nsColor: .systemRed).opacity(0.14)
            : Color(nsColor: .controlAccentColor).opacity(0.32)
    }

    private var iconColor: Color {
        if isDestructive, isHovered { return Color(nsColor: .systemRed) }
        return isHovered ? .white : Color(nsColor: .secondaryLabelColor)
    }

    private var labelColor: Color {
        if isDestructive, isHovered { return Color(nsColor: .systemRed) }
        return isHovered ? .white : Color(nsColor: .labelColor)
    }
}

struct MenuToggleTile: View {
    let control: StatusMenuControl
    @Binding var isOn: Bool
    var onHoverChanged: (StatusMenuControl, Bool) -> Void = { _, _ in }
    var onFocusChanged: (StatusMenuControl, Bool) -> Void = { _, _ in }

    @Environment(MotionPolicy.self) private var motionPolicy
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: control.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(height: 20)
                Text(control.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fillColor)
        }
        .focused($isFocused)
        .onHover { hovered in
            isHovered = hovered
            onHoverChanged(control, hovered)
        }
        .onChange(of: isFocused) { _, focused in
            onFocusChanged(control, focused)
        }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isHovered)
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isOn)
        .accessibilityLabel(control.accessibilityName)
        .accessibilityHint(control.explanation)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }

    private var fillColor: Color {
        isOn
            ? Color(nsColor: .controlAccentColor).opacity(isHovered ? 1.0 : 0.9)
            : Color(nsColor: .secondaryLabelColor).opacity(isHovered ? 0.20 : 0.12)
    }

    private var iconColor: Color {
        if isOn { return .white }
        return isHovered ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
    }

    private var labelColor: Color {
        isOn ? .white : Color(nsColor: .labelColor)
    }
}

struct StatusMenuControlHelpCard: View {
    let control: StatusMenuControl?

    @Environment(MotionPolicy.self) private var motionPolicy

    var body: some View {
        ZStack {
            if let control {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(control.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .labelColor))
                        Text(control.explanation)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    StatusMenuControlPreviewView(
                        preview: control.preview,
                        animationsEnabled: motionPolicy.animationsEnabled
                    )
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                }
                .id(control.id)
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    Text("Hover or focus a control to learn what it does.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .frame(height: 100)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                }
        }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: control?.id)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    @Environment(MotionPolicy.self) private var motionPolicy
    @State private var isHovered = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? .white : Color(nsColor: .secondaryLabelColor))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? .white : Color(nsColor: .labelColor))
                Spacer(minLength: 0)
                switchTrack
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.34) : .clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .onHover { isHovered = $0 }
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.12) : nil, value: isHovered)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }

    private var switchTrack: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(
                    isOn
                        ? Color(nsColor: .systemGreen).opacity(isHovered ? 1.0 : 0.95)
                        : Color(white: isHovered ? 0.32 : 0.26)
                )
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1.8, y: 0.6)
                .padding(2)
        }
        .frame(width: 42, height: 22)
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.14) : nil, value: isOn)
    }
}
