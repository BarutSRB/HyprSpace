import Foundation
import AppKit
import Common

/// Manages persistent state for master layout, including master area percentage and orientation.
///
/// Master layout divides the workspace into two regions:
/// - Master area: Contains exactly 1 window (the "master" window)
/// - Stack area: Contains remaining windows arranged vertically
///
/// The cache stores:
/// - Master area percentage (default 50%)
/// - Orientation (left or right - where the master area is positioned)
///
/// Unlike dwindle's binary tree approach, master layout uses the existing flat list structure
/// where the first child is the master window and remaining children are stack windows.
final class MasterLayoutCache {
    // MARK: - Properties

    /// Master area percentage of total width
    /// Range: [0.1, 0.9] to prevent extreme layouts
    var masterPercent: CGFloat

    /// Master area orientation
    var orientation: MasterOrientation = .left

    // MARK: - Initialization

    init() {
        @MainActor func getDefaultPercent() -> CGFloat {
            return config.masterDefaultPercent
        }
        self.masterPercent = MainActor.assumeIsolated {
            getDefaultPercent()
        }
    }

    // MARK: - Calculated Values

    /// Calculates master area width based on total available width
    /// - Parameter totalWidth: Total available width
    /// - Returns: Width for master area
    func getMasterWidth(totalWidth: CGFloat) -> CGFloat {
        return totalWidth * masterPercent
    }

    /// Calculates stack area width based on total available width
    /// - Parameter totalWidth: Total available width
    /// - Returns: Width for stack area
    func getStackWidth(totalWidth: CGFloat) -> CGFloat {
        return totalWidth * (1.0 - masterPercent)
    }

    // MARK: - Resize Operations

    /// Adjusts master area percentage by pixel delta
    /// - Parameters:
    ///   - delta: Pixel delta (positive = grow master, negative = shrink master)
    ///   - totalWidth: Current total width of the workspace
    func adjustMasterPercent(delta: CGFloat, totalWidth: CGFloat) {
        guard totalWidth > 0 else { return }

        // Convert pixel delta to percentage delta
        let percentDelta = delta / totalWidth

        // Apply delta and clamp to valid range
        masterPercent = clampPercent(masterPercent + percentDelta)
    }

    /// Clamps percentage to valid range [0.1, 0.9]
    private func clampPercent(_ percent: CGFloat) -> CGFloat {
        return max(0.1, min(0.9, percent))
    }

    /// Resets master percentage to configured default
    @MainActor
    func resetToDefault() {
        masterPercent = config.masterDefaultPercent
    }
}

/// Master area orientation - where the master window is positioned
enum MasterOrientation: String, Sendable {
    case left   // Master on left, stack on right
    case right  // Master on right, stack on left
}
