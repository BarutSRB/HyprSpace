import AppKit
import Common

/// Geometric navigation strategy for layouts without meaningful tree hierarchy
///
/// This strategy is used for:
/// - Dwindle layout: Binary tree with dynamic split orientations
/// - Accordion layout: Similar flat structure
///
/// Navigation works by analyzing window positions and edge adjacency rather than
/// tree structure orientation, which doesn't provide meaningful direction information
/// in these layouts.
final class GeometricNavigationProvider: NavigationProvider {
    @MainActor
    func findNeighbor(from window: Window, direction: CardinalDirection, workspace: Workspace) async throws -> Window? {
        // Get the window's tiling parent
        guard let parent = window.parent as? TilingContainer else { return nil }

        // Check if this layout uses geometric navigation
        guard parent.layout == .dwindle || parent.layout == .accordion else {
            #if DEBUG
            print("[GeometricNavigation] ⚠️ Layout \(parent.layout) should use tree navigation instead")
            #endif
            return nil
        }

        // For dwindle, use the cache-based navigation
        if parent.layout == .dwindle {
            guard parent.dwindleCache.rootNode != nil else {
                #if DEBUG
                print("[GeometricNavigation] ⚠️ Dwindle cache not initialized")
                #endif
                return nil
            }

            // Create layout context for gap configuration
            let context = LayoutContext(workspace)

            // Sync geometry from macOS to prevent stale positions
            try await parent.dwindleCache.syncGeometryFromMacOS()

            // Use dwindle cache for geometric navigation
            return parent.dwindleCache.findNeighbor(from: window, direction: direction, gaps: context.resolvedGaps)
        }

        // Accordion would use similar geometric approach
        // For now, return nil (not implemented)
        #if DEBUG
        print("[GeometricNavigation] ⚠️ Accordion geometric navigation not yet implemented")
        #endif
        return nil
    }
}
