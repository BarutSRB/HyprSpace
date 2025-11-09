import AppKit
import Common

/// Protocol for window navigation strategies
///
/// Different layout types use different navigation approaches:
/// - Geometric layouts (dwindle, accordion): Navigate by analyzing window positions and edge adjacency
/// - Tree-based layouts (tiles, h_tiles, v_tiles): Navigate using container hierarchy and orientation
///
/// This protocol enables the strategy pattern for clean separation of navigation logic.
@MainActor
protocol NavigationProvider {
    /// Finds the neighboring window in the specified direction
    ///
    /// - Parameters:
    ///   - window: Current window to navigate from
    ///   - direction: Cardinal direction to navigate (up/down/left/right)
    ///   - workspace: Workspace context for gap configuration
    /// - Returns: The neighboring window, or nil if no valid neighbor exists
    func findNeighbor(from window: Window, direction: CardinalDirection, workspace: Workspace) async throws -> Window?
}
