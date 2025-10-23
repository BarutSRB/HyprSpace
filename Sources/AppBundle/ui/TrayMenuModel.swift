import AppKit
import Common

@MainActor
public final class TrayMenuModel: ObservableObject {
    public static let shared = TrayMenuModel()

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var sponsorshipMessage: String = sponsorshipPrompts.randomElement().orDie()

    // CENTERED BAR FEATURE - Reactive properties for menu bindings
    @Published var centeredBarEnabled: Bool {
        didSet {
            CenteredBarSettings.shared.enabled = centeredBarEnabled
            if centeredBarEnabled {
                CenteredBarManager.shared?.setupCenteredBar(viewModel: self)
            } else {
                CenteredBarManager.shared?.removeCenteredBar()
            }
        }
    }

    @Published var centeredBarShowNumbers: Bool {
        didSet {
            CenteredBarSettings.shared.showNumbers = centeredBarShowNumbers
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    @Published var centeredBarWindowLevel: CenteredBarWindowLevel {
        didSet {
            CenteredBarSettings.shared.windowLevel = centeredBarWindowLevel
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    @Published var centeredBarPosition: CenteredBarPosition {
        didSet {
            CenteredBarSettings.shared.position = centeredBarPosition
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    @Published var centeredBarNotchAware: Bool {
        didSet {
            CenteredBarSettings.shared.notchAware = centeredBarNotchAware
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    @Published var centeredBarDeduplicateIcons: Bool {
        didSet {
            CenteredBarSettings.shared.deduplicateAppIcons = centeredBarDeduplicateIcons
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    @Published var centeredBarHideEmptyWorkspaces: Bool {
        didSet {
            CenteredBarSettings.shared.hideEmptyWorkspaces = centeredBarHideEmptyWorkspaces
            if centeredBarEnabled {
                CenteredBarManager.shared?.update(viewModel: self)
            }
        }
    }

    private init() {
        // Initialize centered bar properties from UserDefaults
        self.centeredBarEnabled = CenteredBarSettings.shared.enabled
        self.centeredBarShowNumbers = CenteredBarSettings.shared.showNumbers
        self.centeredBarWindowLevel = CenteredBarSettings.shared.windowLevel
        self.centeredBarPosition = CenteredBarSettings.shared.position
        self.centeredBarNotchAware = CenteredBarSettings.shared.notchAware
        self.centeredBarDeduplicateIcons = CenteredBarSettings.shared.deduplicateAppIcons
        self.centeredBarHideEmptyWorkspaces = CenteredBarSettings.shared.hideEmptyWorkspaces
    }
}

@MainActor func updateTrayText() {
    let sortedMonitors = sortedMonitors
    let focus = focus
    TrayMenuModel.shared.trayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "[\($0.uppercased())] " } ?? "") +
        sortedMonitors
        .map {
            let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let activeWorkspaceName = hasFullscreenWindows ? "(\($0.activeWorkspace.name))" : $0.activeWorkspace.name
            return ($0.activeWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "") + activeWorkspaceName
        }
        .joined(separator: " │ ")
    TrayMenuModel.shared.workspaces = Workspace.all.map {
        let apps = $0.allLeafWindowsRecursive.map { $0.app.name?.takeIf { !$0.isEmpty } }.filterNotNil().toSet()
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case $0.isVisible: dash + $0.workspaceMonitor.name
            default: ""
        }
        let hasFullscreenWindows = $0.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix,
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    TrayMenuModel.shared.trayItems = items
    // CENTERED BAR FEATURE
    CenteredBarManager.shared?.update(viewModel: TrayMenuModel.shared)
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        if let number = Int(name) {
            guard number >= 0 && number <= 50 else { return nil }
        } else if name.count == 1 {
            guard validLetters.contains(name) else { return nil }
        } else {
            return nil
        }
        let lowercasedName = name.lowercased()
        switch type {
            case .mode:
                return "\(lowercasedName).circle"
            case .workspace:
                if isActive {
                    return "\(lowercasedName).square.fill"
                } else {
                    return "\(lowercasedName).square"
                }
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
