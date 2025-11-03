import AppKit
import Common
import HotKey

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig((try? String(contentsOf: defaultConfigUrl)).orDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceCopyable {
    var afterLoginCommand: [any Command] = []
    var afterStartupCommand: [any Command] = []
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var dwindleSingleWindowAspectRatio: CGPoint = .zero // x, y (e.g., 16, 9). Zero means disabled
    var dwindleSingleWindowAspectRatioTolerance: CGFloat = 0.1 // 0.0-1.0, prevents tiny adjustments
    var dwindleDefaultSplitRatio: CGFloat = 1.0 // 0.1-1.9, default split ratio for new dwindle containers (1.0 = 50/50, 1.618 = golden ratio)
    var masterDefaultPercent: CGFloat = 0.5 // 0.1-0.9, default master area percentage for master layout (0.5 = 50%, 0.618 = golden ratio)
    var niriFocusedWidthRatio: CGFloat = 0.8 // 0.1-1.0, ratio of screen width for focused window in scroll/niri layout
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()

    var onFocusChanged: [any Command] = []
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: [any Command] = []

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []

    var preservedWorkspaceNames: [String] = []
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
