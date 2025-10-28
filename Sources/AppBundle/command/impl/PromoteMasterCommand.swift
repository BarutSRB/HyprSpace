import AppKit
import Common

struct PromoteMasterCommand: Command {
    let args: PromoteMasterCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err("No window is focused")
        }
        guard let parent = window.parent as? TilingContainer else {
            return io.err("Window is not in a tiling container")
        }

        // Only works with master layout
        guard parent.layout == .master else {
            return io.err("promote-master only works with master layout. Current layout: \(parent.layout.rawValue)")
        }

        // If window is already the master (first child), do nothing
        guard let windowIndex = parent.children.firstIndex(where: { $0 === window }) else {
            return false
        }

        if windowIndex == 0 {
            return io.err("Window is already the master window")
        }

        // Get the master window (first child)
        guard case .window(let masterWindow) = parent.children[0].nodeCases else {
            return io.err("First child is not a window")
        }

        // Swap the focused window with the master using unbind/bind
        let masterBinding = masterWindow.unbindFromParent()
        let windowBinding = window.unbindFromParent()

        window.bind(to: masterBinding.parent, adaptiveWeight: masterBinding.adaptiveWeight, index: masterBinding.index)
        masterWindow.bind(to: windowBinding.parent, adaptiveWeight: windowBinding.adaptiveWeight, index: windowBinding.index)

        return true
    }
}
