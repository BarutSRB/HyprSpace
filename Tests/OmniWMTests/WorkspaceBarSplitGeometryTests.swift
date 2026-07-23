// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarSplitGeometryTests: XCTestCase {
    private func makeMonitor(
        frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleTop: CGFloat = 950,
        hasNotch: Bool = true,
        notchRange: ClosedRange<CGFloat>? = 656 ... 856
    ) -> Monitor {
        Monitor(
            id: Monitor.ID(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: visibleTop - frame.minY
            ),
            hasNotch: hasNotch,
            notchRange: notchRange,
            name: "Test"
        )
    }

    private func makeResolved(
        notchMode: WorkspaceBarNotchMode,
        zoneWidth: Double = 180,
        position: WorkspaceBarPosition = .overlappingMenuBar,
        xOffset: Double = 0,
        yOffset: Double = 0
    ) -> ResolvedBarSettings {
        ResolvedBarSettings(
            enabled: true,
            showLabels: true,
            showFloatingWindows: false,
            deduplicateAppIcons: false,
            hideEmptyWorkspaces: false,
            excludedBundleIDs: [],
            reserveLayoutSpace: false,
            notchMode: notchMode,
            notchActiveZoneWidth: zoneWidth,
            systemStatsButton: false,
            position: position,
            windowLevel: .popup,
            height: 24,
            backgroundOpacity: 0.1,
            xOffset: xOffset,
            yOffset: yOffset,
            accentColor: nil,
            textColor: nil
        )
    }

    private func splitLayout(
        activeWidth: CGFloat,
        secondaryWidth: CGFloat? = 400,
        monitor: Monitor? = nil,
        resolved: ResolvedBarSettings? = nil
    ) -> WorkspaceBarSplitLayout? {
        let monitor = monitor ?? makeMonitor()
        let resolved = resolved ?? makeResolved(notchMode: .splitActiveLeft)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        return geometry.splitFrame(
            activeWidth: activeWidth,
            secondaryWidth: secondaryWidth,
            monitor: monitor,
            resolved: resolved
        )
    }

    func testSplitActiveLeftCentersPillInZone() throws {
        let layout = try XCTUnwrap(splitLayout(activeWidth: 100))

        XCTAssertEqual(layout.activeFrame, CGRect(x: 508, y: 950, width: 100, height: 24))
        XCTAssertEqual(layout.secondaryFrame, CGRect(x: 864, y: 950, width: 400, height: 24))
        XCTAssertEqual(layout.activeFrame.midX, 558)
    }

    func testSplitActivePillClampsAtNotchGapWhenWiderThanZone() throws {
        let layout = try XCTUnwrap(splitLayout(activeWidth: 260))

        XCTAssertEqual(layout.activeFrame.maxX, 648)
        XCTAssertEqual(layout.activeFrame.minX, 388)
    }

    func testSplitZoneWidthClampsToAvailableSpace() throws {
        let resolved = makeResolved(notchMode: .splitActiveLeft, zoneWidth: 5000)
        let layout = try XCTUnwrap(splitLayout(activeWidth: 100, resolved: resolved))

        XCTAssertEqual(layout.activeFrame.midX, 324)
    }

    func testSplitActiveWidthClampsAtMonitorEdge() throws {
        let layout = try XCTUnwrap(splitLayout(activeWidth: 10000))

        XCTAssertEqual(layout.activeFrame, CGRect(x: 0, y: 950, width: 648, height: 24))
    }

    func testSplitVirtualNotchOnPlainMonitor() throws {
        let plain = makeMonitor(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleTop: 1055,
            hasNotch: false,
            notchRange: nil
        )

        let overlapping = try XCTUnwrap(splitLayout(activeWidth: 100, monitor: plain))
        XCTAssertEqual(overlapping.activeFrame.maxX, 952 - (180 - 100) / 2)
        XCTAssertEqual(try XCTUnwrap(overlapping.secondaryFrame).minX, 968)
        XCTAssertEqual(overlapping.activeFrame.minY, 1055)

        let below = try XCTUnwrap(splitLayout(
            activeWidth: 100,
            monitor: plain,
            resolved: makeResolved(notchMode: .splitActiveLeft, position: .belowMenuBar)
        ))
        XCTAssertEqual(below.activeFrame.minY, 1055 - 24)
    }

    func testSplitActiveRightMirrorsLeftForCenteredNotch() throws {
        let monitor = makeMonitor()
        let mirror: (CGFloat) -> CGFloat = { monitor.frame.minX + monitor.frame.maxX - $0 }

        let left = try XCTUnwrap(splitLayout(
            activeWidth: 100,
            monitor: monitor,
            resolved: makeResolved(notchMode: .splitActiveLeft)
        ))
        let right = try XCTUnwrap(splitLayout(
            activeWidth: 100,
            monitor: monitor,
            resolved: makeResolved(notchMode: .splitActiveRight)
        ))

        XCTAssertEqual(right.activeFrame.minX, mirror(left.activeFrame.maxX))
        XCTAssertEqual(right.activeFrame.width, left.activeFrame.width)
        XCTAssertEqual(
            try XCTUnwrap(right.secondaryFrame).minX,
            mirror(try XCTUnwrap(left.secondaryFrame).maxX)
        )
    }

    func testSplitActiveRightPlacesActiveZoneRightOfAsymmetricNotch() throws {
        let layout = try XCTUnwrap(splitLayout(
            activeWidth: 100,
            monitor: makeMonitor(notchRange: 600 ... 800),
            resolved: makeResolved(notchMode: .splitActiveRight)
        ))

        XCTAssertEqual(layout.activeFrame, CGRect(x: 848, y: 950, width: 100, height: 24))
        XCTAssertEqual(try XCTUnwrap(layout.secondaryFrame).maxX, 592)
        XCTAssertEqual(try XCTUnwrap(layout.secondaryFrame).width, 400)
    }

    func testSplitEmptySecondaryOmitsIsland() throws {
        let layout = try XCTUnwrap(splitLayout(activeWidth: 100, secondaryWidth: nil))

        XCTAssertNil(layout.secondaryFrame)
    }

    func testSplitOffsetsTranslateAllFrames() throws {
        let base = try XCTUnwrap(splitLayout(activeWidth: 100))
        let offset = try XCTUnwrap(splitLayout(
            activeWidth: 100,
            resolved: makeResolved(notchMode: .splitActiveLeft, xOffset: 20, yOffset: -10)
        ))

        XCTAssertEqual(offset.activeFrame, base.activeFrame.offsetBy(dx: 20, dy: -10))
        XCTAssertEqual(
            try XCTUnwrap(offset.secondaryFrame),
            try XCTUnwrap(base.secondaryFrame).offsetBy(dx: 20, dy: -10)
        )
    }

    func testSplitReturnsNilWhenSideSpaceTooSmall() {
        let monitor = makeMonitor(notchRange: 30 ... 200)

        XCTAssertNil(splitLayout(activeWidth: 100, monitor: monitor))
    }

    func testSplitIslandsNeverIntersectNotch() throws {
        let monitor = makeMonitor(notchRange: 600 ... 800)
        let notchSpan = CGRect(x: 600, y: 950, width: 200, height: 24)

        for mode in [WorkspaceBarNotchMode.splitActiveLeft, .splitActiveRight] {
            for activeWidth: CGFloat in [10, 50, 180, 300, 700, 2000] {
                let layout = try XCTUnwrap(splitLayout(
                    activeWidth: activeWidth,
                    monitor: monitor,
                    resolved: makeResolved(notchMode: mode)
                ))
                XCTAssertFalse(layout.activeFrame.intersects(notchSpan))
                if let secondary = layout.secondaryFrame {
                    XCTAssertFalse(secondary.intersects(notchSpan))
                }
                XCTAssertGreaterThanOrEqual(layout.activeFrame.minX, monitor.frame.minX)
                XCTAssertLessThanOrEqual(layout.activeFrame.maxX, monitor.frame.maxX)
            }
        }
    }

    func testCenteredIslandHugsMeasuredWidth() {
        let monitor = makeMonitor()
        let resolved = makeResolved(notchMode: .off)
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)

        for fittingWidth: CGFloat in [40, 60, 221, 288, 355, 700] {
            let frame = geometry.frame(fittingWidth: fittingWidth, monitor: monitor, resolved: resolved)
            XCTAssertEqual(frame.width, fittingWidth, accuracy: 0.01, "fitting \(fittingWidth)")
            XCTAssertEqual(frame.midX, monitor.frame.midX, accuracy: 0.01, "fitting \(fittingWidth)")
        }

        let degenerate = geometry.frame(fittingWidth: 4, monitor: monitor, resolved: resolved)
        XCTAssertEqual(degenerate.width, WorkspaceBarGeometry.minimumIslandWidth)
        XCTAssertEqual(degenerate.midX, monitor.frame.midX, accuracy: 0.01)
    }

    func testSplitReturnsNilForNonSplitModes() {
        XCTAssertNil(splitLayout(activeWidth: 100, resolved: makeResolved(notchMode: .off)))
        XCTAssertNil(splitLayout(activeWidth: 100, resolved: makeResolved(notchMode: .moveBelowMenuBar)))
    }

    func testEffectivePositionOnlyMovesBelowForMoveBelowMode() {
        let monitor = makeMonitor()

        XCTAssertEqual(
            WorkspaceBarGeometry.effectivePosition(
                for: monitor,
                resolved: makeResolved(notchMode: .moveBelowMenuBar)
            ),
            .belowMenuBar
        )
        for mode in [WorkspaceBarNotchMode.off, .splitActiveLeft, .splitActiveRight] {
            XCTAssertEqual(
                WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: makeResolved(notchMode: mode)),
                .overlappingMenuBar
            )
        }
        XCTAssertEqual(
            WorkspaceBarGeometry.effectivePosition(
                for: makeMonitor(hasNotch: false, notchRange: nil),
                resolved: makeResolved(notchMode: .moveBelowMenuBar)
            ),
            .overlappingMenuBar
        )
    }
}
