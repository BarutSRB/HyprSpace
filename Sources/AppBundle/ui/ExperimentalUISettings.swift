import SwiftUI

struct ExperimentalUISettings {
    var displayStyle: MenuBarStyle {
        get {
            if let value = UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue) {
                return MenuBarStyle(rawValue: value) ?? .monospacedText
            } else {
                return .monospacedText
            }
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue)
            UserDefaults.standard.synchronize()
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Equatable, Hashable {
    case monospacedText
    case systemText
    case squares
    case i3
    case i3Ordered
    var id: String { rawValue }
    var title: String {
        switch self {
            case .monospacedText: "Monospaced font"
            case .systemText: "System font"
            case .squares: "Square images"
            case .i3: "i3 style grouped"
            case .i3Ordered: "i3 style ordered"
        }
    }
}

enum ExperimentalUISettingsItems: String {
    case displayStyle
}

@MainActor
func getExperimentalUISettingsMenu(viewModel: TrayMenuModel) -> some View {
    let color = AppearanceTheme.current == .dark ? Color.white : Color.black
    return Menu {
        Text("Menu bar style (macOS 14 or later):")
        ForEach(MenuBarStyle.allCases, id: \.id) { style in
            MenuBarStyleButton(style: style, color: color).environmentObject(viewModel)
        }

        // CENTERED BAR FEATURE
        Divider()
        Text("Centered Workspace Bar:")
        Button {
            CenteredBarSettings.shared.enabled = !CenteredBarSettings.shared.enabled
            CenteredBarManager.shared?.toggleCenteredBar(viewModel: viewModel)
        } label: {
            Toggle(isOn: .constant(CenteredBarSettings.shared.enabled)) {
                Text("Enable centered workspace bar")
            }
        }

        Button {
            CenteredBarSettings.shared.showNumbers = !CenteredBarSettings.shared.showNumbers
            if CenteredBarSettings.shared.enabled {
                CenteredBarManager.shared?.update(viewModel: viewModel)
            }
        } label: {
            Toggle(isOn: .constant(CenteredBarSettings.shared.showNumbers)) {
                Text("Show workspace numbers")
            }
        }
        .disabled(!CenteredBarSettings.shared.enabled)

        // Window level selection
        Text("Window Level:")
        ForEach(CenteredBarWindowLevel.allCases) { level in
            Button {
                CenteredBarSettings.shared.windowLevel = level
                if CenteredBarSettings.shared.enabled {
                    CenteredBarManager.shared?.update(viewModel: viewModel)
                }
            } label: {
                Toggle(isOn: .constant(CenteredBarSettings.shared.windowLevel == level)) {
                    Text(level.title)
                }
            }
        }
        .disabled(!CenteredBarSettings.shared.enabled)

        // Target display selection
        Text("Target Display:")
        ForEach(CenteredBarTargetDisplay.allCases) { target in
            Button {
                CenteredBarSettings.shared.targetDisplay = target
                if CenteredBarSettings.shared.enabled {
                    CenteredBarManager.shared?.update(viewModel: viewModel)
                }
            } label: {
                Toggle(isOn: .constant(CenteredBarSettings.shared.targetDisplay == target)) {
                    Text(target.title)
                }
            }
        }
        .disabled(!CenteredBarSettings.shared.enabled)

        Divider()

        // Notch-aware positioning
        Button {
            CenteredBarSettings.shared.notchAware = !CenteredBarSettings.shared.notchAware
            if CenteredBarSettings.shared.enabled {
                CenteredBarManager.shared?.update(viewModel: viewModel)
            }
        } label: {
            Toggle(isOn: .constant(CenteredBarSettings.shared.notchAware)) {
                Text("Notch-aware positioning (shift right of notch)")
            }
        }
        .disabled(!CenteredBarSettings.shared.enabled)

        // Deduplicate app icons
        Button {
            CenteredBarSettings.shared.deduplicateAppIcons = !CenteredBarSettings.shared.deduplicateAppIcons
            if CenteredBarSettings.shared.enabled {
                CenteredBarManager.shared?.update(viewModel: viewModel)
            }
        } label: {
            Toggle(isOn: .constant(CenteredBarSettings.shared.deduplicateAppIcons)) {
                Text("Deduplicate app icons (show badge with count)")
            }
        }
        .disabled(!CenteredBarSettings.shared.enabled)
    } label: {
        Text("Experimental UI Settings (No stability guarantees)")
    }
}

@MainActor
struct MenuBarStyleButton: View {
    @EnvironmentObject var viewModel: TrayMenuModel
    let style: MenuBarStyle
    let color: Color

    var body: some View {
        Button {
            viewModel.experimentalUISettings.displayStyle = style
        } label: {
            Toggle(isOn: .constant(viewModel.experimentalUISettings.displayStyle == style)) {
                MenuBarLabel(style: style, color: color)
                    .environmentObject(viewModel)
                Text(" -  " + style.title)
            }
        }
    }
}
