import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    var layout: Layout

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self.layout = layout
        // Scroll layout requires horizontal orientation
        if layout == .scroll && orientation != .h {
            self._orientation = .h
        }
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach {
                    $0._orientation = orientation
                    orientation = orientation.opposite
                }
        } else {
            _orientation = targetOrientation
        }
    }

    func normalizeOppositeOrientationForNestedContainers() {
        if orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

enum Layout: String {
    case tiles
    case accordion
    case dwindle
    case scroll
    case master
}

extension String {
    func parseLayout() -> Layout? {
        if let parsed = Layout(rawValue: self) {
            return parsed
        } else if self == "list" {
            return .tiles
        } else {
            return nil
        }
    }
}

// MARK: - Dwindle Layout Cache Integration

private let dwindleCacheKey = TreeNodeUserDataKey<DwindleLayoutCache>(key: "dwindleLayoutCache")

extension TilingContainer {
    /// Gets or creates the dwindle layout cache for this container
    ///
    /// The cache persists across layout recalculations and maintains the binary
    /// tree structure with split ratios. It automatically rebuilds when windows
    /// are added or removed.
    var dwindleCache: DwindleLayoutCache {
        if let cache = getUserData(key: dwindleCacheKey) {
            return cache
        }
        let cache = DwindleLayoutCache()
        putUserData(key: dwindleCacheKey, data: cache)
        return cache
    }

    /// Invalidates the dwindle cache, forcing a rebuild on next layout pass
    ///
    /// Called when switching away from dwindle layout or when tree structure
    /// changes significantly (e.g., normalization)
    func invalidateDwindleCache() {
        cleanUserData(key: dwindleCacheKey)
    }
}

// MARK: - Master Layout Cache Integration

private let masterCacheKey = TreeNodeUserDataKey<MasterLayoutCache>(key: "masterLayoutCache")

extension TilingContainer {
    /// Gets or creates the master layout cache for this container
    ///
    /// The cache persists across layout recalculations and maintains the
    /// master area percentage and orientation.
    var masterCache: MasterLayoutCache {
        if let cache = getUserData(key: masterCacheKey) {
            return cache
        }
        let cache = MasterLayoutCache()
        putUserData(key: masterCacheKey, data: cache)
        return cache
    }

    /// Invalidates the master cache, resetting to defaults
    ///
    /// Called when switching away from master layout
    func invalidateMasterCache() {
        cleanUserData(key: masterCacheKey)
    }
}
