import SwiftUI

// CENTERED BAR FEATURE
// UserDefaults-backed settings for the centered workspace bar
@MainActor
public class CenteredBarSettings {
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

    public var targetDisplay: CenteredBarTargetDisplay {
        get {
            if let raw = UserDefaults.standard.string(forKey: CenteredBarSettingsKeys.targetDisplay.rawValue),
               let value = CenteredBarTargetDisplay(rawValue: raw)
            {
                return value
            }
            return .focused // default: follows focused workspace
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: CenteredBarSettingsKeys.targetDisplay.rawValue)
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
}

public enum CenteredBarSettingsKeys: String {
    case enabled
    case showNumbers
    case windowLevel
    case targetDisplay
    case notchAware
    case deduplicateAppIcons
}

public enum CenteredBarWindowLevel: String, CaseIterable, Identifiable, Equatable, Hashable {
    case status      // NSWindow.Level.statusBar
    case popup       // NSWindow.Level.popUpMenu (above menu bar)
    case screensaver // NSWindow.Level.screenSaver (highest common level)

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .status: "Status Bar"
            case .popup: "Popup (above menu bar)"
            case .screensaver: "Screen Saver (highest)"
        }
    }

    public var nsWindowLevel: NSWindow.Level {
        switch self {
            case .status: .statusBar
            case .popup: .popUpMenu
            case .screensaver: .screenSaver
        }
    }
}

public enum CenteredBarTargetDisplay: String, CaseIterable, Identifiable, Equatable, Hashable {
    case focused // monitor of the focused workspace
    case primary // main monitor (origin 0,0)
    case mouse   // display under mouse cursor

    public var id: String { rawValue }

    public var title: String {
        switch self {
            case .focused: "Focused Workspace Monitor"
            case .primary: "Primary Display"
            case .mouse: "Display Under Mouse"
        }
    }
}
