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

    var showMenuBarWorkspaces: Bool {
        get {
            if UserDefaults.standard.object(forKey: ExperimentalUISettingsItems.showMenuBarWorkspaces.rawValue) == nil {
                return true // Default to showing workspace indicators
            }
            return UserDefaults.standard.bool(forKey: ExperimentalUISettingsItems.showMenuBarWorkspaces.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: ExperimentalUISettingsItems.showMenuBarWorkspaces.rawValue)
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
    case showMenuBarWorkspaces
}

@MainActor
struct ExperimentalUISettingsMenu: View {
    @ObservedObject var viewModel: TrayMenuModel

    var body: some View {
        let color = AppearanceTheme.current == .dark ? Color.white : Color.black
        return Menu {
            Toggle(isOn: Binding(
                get: { viewModel.experimentalUISettings.showMenuBarWorkspaces },
                set: { newValue in
                    viewModel.experimentalUISettings.showMenuBarWorkspaces = newValue
                }
            )) {
                Text("Show workspace indicators in menu bar")
            }

            if viewModel.experimentalUISettings.showMenuBarWorkspaces {
                Text("Menu bar style (macOS 14 or later):")
                ForEach(MenuBarStyle.allCases, id: \.id) { style in
                    MenuBarStyleButton(style: style, color: color).environmentObject(viewModel)
                }
            }

            // CENTERED BAR FEATURE
            Divider()
            Text("Centered Workspace Bar:")
            Toggle(isOn: Binding(
                get: { viewModel.centeredBarEnabled },
                set: { viewModel.centeredBarEnabled = $0 }
            )) {
                Text("Enable centered workspace bar")
            }

            Toggle(isOn: Binding(
                get: { viewModel.centeredBarShowNumbers },
                set: { viewModel.centeredBarShowNumbers = $0 }
            )) {
                Text("Show workspace numbers")
            }
            .disabled(!viewModel.centeredBarEnabled)

            // Window level selection
            Text("Window Level (Z-Index):")
            ForEach(CenteredBarWindowLevel.allCases) { level in
                Toggle(isOn: Binding(
                    get: { viewModel.centeredBarWindowLevel == level },
                    set: { isOn in
                        guard isOn else { return }
                        viewModel.centeredBarWindowLevel = level
                    }
                )) {
                    Text(level.title)
                }
                .disabled(!viewModel.centeredBarEnabled)
            }

            // Bar position selection
            Text("Bar Position:")
            ForEach(CenteredBarPosition.allCases) { position in
                Toggle(isOn: Binding(
                    get: { viewModel.centeredBarPosition == position },
                    set: { isOn in
                        guard isOn else { return }
                        viewModel.centeredBarPosition = position
                    }
                )) {
                    Text(position.title)
                }
                .disabled(!viewModel.centeredBarEnabled)
            }

            Divider()

            // Notch-aware positioning
            Toggle(isOn: Binding(
                get: { viewModel.centeredBarNotchAware },
                set: { viewModel.centeredBarNotchAware = $0 }
            )) {
                Text("Notch-aware positioning (shift right of notch)")
            }
            .disabled(!viewModel.centeredBarEnabled)

            // Deduplicate app icons
            Toggle(isOn: Binding(
                get: { viewModel.centeredBarDeduplicateIcons },
                set: { viewModel.centeredBarDeduplicateIcons = $0 }
            )) {
                Text("Deduplicate app icons (show badge with count)")
            }
            .disabled(!viewModel.centeredBarEnabled)

            // Hide empty workspaces
            Toggle(isOn: Binding(
                get: { viewModel.centeredBarHideEmptyWorkspaces },
                set: { viewModel.centeredBarHideEmptyWorkspaces = $0 }
            )) {
                Text("Hide empty workspaces")
            }
            .disabled(!viewModel.centeredBarEnabled)
        } label: {
            Text("Experimental UI Settings (No stability guarantees)")
        }
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
