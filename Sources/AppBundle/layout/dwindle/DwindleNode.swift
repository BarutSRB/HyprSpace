import Foundation
import AppKit

/// Represents a node in the dwindle layout binary tree.
///
/// This class mirrors Hyprland's `SDwindleNodeData` structure, providing
/// an explicit binary tree for managing window splits and ratios.
///
/// Each container node (non-leaf) represents a binary split with:
/// - Exactly 2 children
/// - A split ratio controlling the proportion between children
/// - A split orientation (vertical or horizontal)
///
/// Leaf nodes reference actual windows and have no children.
final class DwindleNode {
    // MARK: - Tree Structure

    /// Parent node in the tree (weak to avoid retain cycles)
    weak var parent: DwindleNode?

    /// Child nodes - empty for leaves, exactly 2 for containers
    var children: [DwindleNode] = []

    // MARK: - Window Reference

    /// Associated window for leaf nodes (nil for container nodes)
    weak var window: TreeNode?

    // MARK: - Split Configuration

    /// Split ratio controlling the proportion between children.
    ///
    /// Based on Hyprland's formula:
    /// - childA_size = container_size * (splitRatio / (splitRatio + 1))
    /// - childB_size = container_size * (1 / (splitRatio + 1))
    ///
    /// Default is 1.0 (50/50 split). Valid range is [0.1, 1.9].
    ///
    /// Only meaningful for container nodes.
    var splitRatio: CGFloat = 1.0

    /// Split orientation for container nodes.
    ///
    /// - `true`: Vertical split (left | right)
    /// - `false`: Horizontal split (top / bottom)
    ///
    /// Determined by available space aspect ratio and configuration.
    var splitVertically: Bool = true

    // MARK: - Computed Layout

    /// Current position and size of this node.
    ///
    /// IMPORTANT: This value is updated during layout passes and should
    /// always reflect fresh geometry. When calculating resize deltas,
    /// always use the current box size to avoid stale data.
    var box: CGRect = .zero

    // MARK: - Helpers

    /// Returns true if this is a leaf node (contains a window)
    var isLeaf: Bool {
        return window != nil
    }

    /// Returns true if this is a container node (has children)
    var isContainer: Bool {
        return !children.isEmpty
    }

    // MARK: - Initialization

    /// Creates a new dwindle node
    /// - Parameter window: Optional window reference for leaf nodes
    init(window: TreeNode? = nil) {
        self.window = window
    }
}
