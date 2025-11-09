import AppKit
import Common

/// Tree-based navigation strategy for layouts with meaningful hierarchy
///
/// This strategy is used for:
/// - Tiles layout: Windows arranged in oriented containers
/// - H_tiles / V_tiles: Directional tile layouts
/// - Master layout: Master-slave window arrangement
///
/// Navigation works by walking up the tree to find a parent whose orientation
/// matches the navigation direction, then selecting the appropriate sibling.
final class TreeNavigationProvider: NavigationProvider {
    @MainActor
    func findNeighbor(from window: Window, direction: CardinalDirection, workspace: Workspace) async throws -> Window? {
        // Use the existing tree-based navigation logic
        // This walks up the tree looking for a parent container whose orientation
        // matches the direction, then selects the appropriate neighbor

        #if DEBUG
        print("[TreeNavigation] Finding neighbor in direction \(direction)")
        print("[TreeNavigation] Window parent layout: \(String(describing: (window.parent as? TilingContainer)?.layout))")
        #endif

        // Find the closest parent that has children in the requested direction
        guard let (parent, ownIndex) = window.closestParent(hasChildrenInDirection: direction, withLayout: nil) else {
            #if DEBUG
            print("[TreeNavigation] ❌ No parent found with children in direction \(direction)")
            #endif
            return nil
        }

        #if DEBUG
        print("[TreeNavigation] Found parent with orientation \(parent.orientation)")
        print("[TreeNavigation] Current child index: \(ownIndex), moving to: \(ownIndex + direction.focusOffset)")
        #endif

        // Get the target child in the specified direction
        let targetChild = parent.children[ownIndex + direction.focusOffset]

        // Find the leaf window in the target child, snapped to the opposite direction
        // (e.g., if navigating right, snap to the leftmost window in the target container)
        guard let windowToFocus = targetChild.findLeafWindowRecursive(snappedTo: direction.opposite) else {
            #if DEBUG
            print("[TreeNavigation] ❌ No leaf window found in target child")
            #endif
            return nil
        }

        #if DEBUG
        print("[TreeNavigation] ✅ Found target window")
        #endif

        return windowToFocus
    }
}
