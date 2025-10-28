import SwiftUI

// CENTERED BAR FEATURE
// UserDefaults-backed settings for the centered workspace bar
@MainActor
public final class CenteredBarSettings {
    public static let shared = CenteredBarSettings()

    private init() {}

    public var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: CenteredBarSettingsKeys.enabled.rawValue) == nil {
                return false // Default to disabled
            }
            return UserDefaults.standard.bool(forKey: CenteredBarSettingsKeys.enabled.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: CenteredBarSettingsKeys.enabled.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var showNumbers: Bool {
        get {
            if UserDefaults.standard.object(forKey: CenteredBarSettingsKeys.showNumbers.rawValue) == nil {
                return true // Default to true
            }
            return UserDefaults.standard.bool(forKey: CenteredBarSettingsKeys.showNumbers.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: CenteredBarSettingsKeys.showNumbers.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var windowLevel: CenteredBarWindowLevel {
        get {
            if let raw = UserDefaults.standard.string(forKey: CenteredBarSettingsKeys.windowLevel.rawValue),
               let value = CenteredBarWindowLevel(rawValue: raw)
            {
                return value
            }
            return .popup // default: above menu bar
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: CenteredBarSettingsKeys.windowLevel.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var position: CenteredBarPosition {
        get {
            if let raw = UserDefaults.standard.string(forKey: CenteredBarSettingsKeys.position.rawValue),
               let value = CenteredBarPosition(rawValue: raw)
            {
                return value
            }
            return .overlappingMenuBar // default: overlap menu bar
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: CenteredBarSettingsKeys.position.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var notchAware: Bool {
        get {
            return UserDefaults.standard.bool(forKey: CenteredBarSettingsKeys.notchAware.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: CenteredBarSettingsKeys.notchAware.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var deduplicateAppIcons: Bool {
        get {
            return UserDefaults.standard.bool(forKey: CenteredBarSettingsKeys.deduplicateAppIcons.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: CenteredBarSettingsKeys.deduplicateAppIcons.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    public var hideEmptyWorkspaces: Bool {
        get {
            return UserDefaults.standard.bool(forKey: CenteredBarSettingsKeys.hideEmptyWorkspaces.rawValue)
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: CenteredBarSettingsKeys.hideEmptyWorkspaces.rawValue)
            UserDefaults.standard.synchronize()
        }
    }
}

public enum CenteredBarSettingsKeys: String {
    case enabled
    case showNumbers
    case windowLevel
    case position
    case notchAware
    case deduplicateAppIcons
    case hideEmptyWorkspaces
}

public enum CenteredBarWindowLevel: String, CaseIterable, Identifiable, Equatable, Hashable {
    case normal      // NSWindow.Level.normal
    case floating    // NSWindow.Level.floating
    case status      // NSWindow.Level.statusBar
    case popup       // NSWindow.Level.popUpMenu
    case screensaver // NSWindow.Level.screenSaver

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .normal: "Normal"
            case .floating: "Floating"
            case .status: "Status Bar"
            case .popup: "Popup"
            case .screensaver: "Screen Saver (highest)"
        }
    }

    public var nsWindowLevel: NSWindow.Level {
        switch self {
            case .normal: .normal
            case .floating: .floating
            case .status: .statusBar
            case .popup: .popUpMenu
            case .screensaver: .screenSaver
        }
    }
}

public enum CenteredBarPosition: String, CaseIterable, Identifiable, Equatable, Hashable {
    case overlappingMenuBar // Bar overlaps menu bar (same y position)
    case belowMenuBar       // Bar positioned below menu bar

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .overlappingMenuBar: "Overlapping Menu Bar"
            case .belowMenuBar: "Below Menu Bar"
        }
    }
}
