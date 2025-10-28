import AppKit
import Common

struct ResizeCommand: Command { // todo cover with tests
    let args: ResizeCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter {
                let layout = ($0.parent as? TilingContainer)?.layout
                return layout == .tiles || layout == .dwindle || layout == .scroll
            }
            ?? []

        guard let node = candidates.first else {
            return io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9")
        }
        guard let parent = node.parent as? TilingContainer else { return false }

        // Handle dwindle layout separately - it uses direct dimension-to-axis mapping
        if parent.layout == .dwindle {
            let cache = parent.dwindleCache

            // Detect grow vs shrink operation and calculate pixel delta
            let shouldGrow: Bool
            let pixelDiff: CGFloat

            switch args.units.val {
                case .set(let unit):
                    pixelDiff = CGFloat(unit) * 10  // Arbitrary pixel value for set mode
                    shouldGrow = true  // Set mode always grows
                case .add(let unit):
                    pixelDiff = CGFloat(unit)
                    shouldGrow = true  // Add = grow (equals key)
                case .subtract(let unit):
                    pixelDiff = CGFloat(unit)
                    shouldGrow = false  // Subtract = shrink (minus key)
            }

            // Map dimension directly to axes (no orientation lookup needed for dwindle)
            let delta = switch args.dimension.val {
                case .width:
                    Vector2D(x: pixelDiff, y: 0)
                case .height:
                    Vector2D(x: 0, y: pixelDiff)
                case .smart:
                    // For smart, resize in both dimensions
                    Vector2D(x: pixelDiff, y: pixelDiff)
                case .smartOpposite:
                    // For smart-opposite, use negative on one axis
                    Vector2D(x: pixelDiff, y: -pixelDiff)
            }

            cache.resize(window: node, delta: delta, shouldGrow: shouldGrow)
            // Layout will be refreshed automatically via refreshModel() after command completes
            return true
        }

        // Tiles and scroll layouts use orientation-based weight resizing
        let orientation: Orientation?
        let orientedNode: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                orientedNode = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
            case .height:
                orientation = .v
                orientedNode = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
            case .smart:
                orientedNode = candidates.first
                orientation = (orientedNode?.parent as? TilingContainer)?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                orientedNode = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
        }
        guard let orientation else { return false }
        guard let orientedNode else { return false }
        guard let tilesParent = orientedNode.parent as? TilingContainer else { return false }

        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - orientedNode.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        // Tiles and scroll layout use weight-based resizing
        let siblingCount = tilesParent.children.count - 1
        if tilesParent.layout != .scroll {
            guard let childDiff = diff.div(siblingCount) else { return false }
            tilesParent.children.lazy
                .filter { $0 != orientedNode }
                .forEach { $0.setWeight(tilesParent.orientation, $0.getWeight(tilesParent.orientation) - childDiff) }
        }

        orientedNode.setWeight(orientation, orientedNode.getWeight(orientation) + diff)
        return true
    }
}
