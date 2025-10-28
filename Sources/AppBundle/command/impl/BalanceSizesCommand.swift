import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        balance(target.workspace.rootTilingContainer)
        return true
    }
}

@MainActor
private func balance(_ parent: TilingContainer) {
    // For dwindle layout, reset all split ratios in the cache
    if parent.layout == .dwindle {
        parent.dwindleCache.resetAllRatios()
    }

    for child in parent.children {
        switch parent.layout {
            case .tiles: child.setWeight(parent.orientation, 1)
            case .dwindle: break // Ratios already reset above via cache
            case .accordion, .scroll: break // Do nothing
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}
