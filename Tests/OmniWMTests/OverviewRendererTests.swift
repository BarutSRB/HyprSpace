// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import CoreText
import Foundation
@testable import OmniWM
import XCTest

final class OverviewRendererTests: XCTestCase {
    func testTextLineCacheReusesLinesAndRemainsBounded() {
        var cache = OverviewTextLineCache()
        let key = OverviewTextLineCache.Key(role: .title, text: "Window", widthBucket: 200)
        let first = cache.line(for: key) {
            CTLineCreateWithAttributedString(NSAttributedString(string: "Window"))
        }
        let second = cache.line(for: key) {
            XCTFail("Expected the cached Core Text line")
            return CTLineCreateWithAttributedString(NSAttributedString(string: "Replacement"))
        }

        XCTAssertTrue(first === second)

        for index in 0 ..< 600 {
            let key = OverviewTextLineCache.Key(role: .appName, text: "App \(index)", widthBucket: 0)
            _ = cache.line(for: key) {
                CTLineCreateWithAttributedString(NSAttributedString(string: "App \(index)"))
            }
        }

        XCTAssertLessThanOrEqual(cache.entryCount, 512)
    }

    func testDefaultPalettePreservesExistingColors() {
        assertColor(OverviewRenderPalette.default.backdrop, equals: [0.05, 0.05, 0.08, 1.0])
        assertColor(OverviewRenderPalette.default.normalBorder, equals: [0.3, 0.3, 0.35, 0.5])
        assertColor(OverviewRenderPalette.default.hoveredBorder, equals: [0.4, 0.6, 1.0, 1.0])
        assertColor(OverviewRenderPalette.default.selectedBorder, equals: [0.3, 0.8, 0.4, 1.0])
    }

    func testPaletteClampsFiniteComponentsAndFallsBackForNonFiniteComponents() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: .nan, green: -1, blue: 2, alpha: .infinity),
            normalBorderColor: SettingsColor(red: -.infinity, green: 0.4, blue: 0.5, alpha: 0.6),
            hoveredBorderColor: SettingsColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
            selectedBorderColor: SettingsColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.6)
        )

        assertColor(palette.backdrop, equals: [0.05, 0, 1, 1])
        assertColor(palette.normalBorder, equals: [0.3, 0.4, 0.5, 0.6])
        assertColor(palette.hoveredBorder, equals: [0.1, 0.2, 0.3, 0.4])
        assertColor(palette.selectedBorder, equals: [0.9, 0.8, 0.7, 0.6])
    }

    func testSelectedBorderTakesPrecedenceOverHoveredAndNormalColors() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 1),
            normalBorderColor: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1),
            hoveredBorderColor: SettingsColor(red: 0, green: 1, blue: 0, alpha: 1),
            selectedBorderColor: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let token = WindowToken(pid: 1, windowId: 1)
        let window = OverviewWindowItem(
            handle: WindowHandle(id: token),
            windowId: token.windowId,
            workspaceId: UUID(),
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: .zero,
            overviewFrame: .zero,
            matchesSearch: true
        )

        XCTAssertEqual(window.title, "Window")
        assertColor(
            OverviewRenderer.borderColor(isSelected: false, isHovered: false, palette: palette),
            equals: [1, 0, 0, 1]
        )
        assertColor(
            OverviewRenderer.borderColor(isSelected: false, isHovered: true, palette: palette),
            equals: [0, 1, 0, 1]
        )
        assertColor(
            OverviewRenderer.borderColor(isSelected: true, isHovered: true, palette: palette),
            equals: [0, 0, 1, 1]
        )
    }

    func testVisibleContentRectTracksScrollDuringAnimation() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            OverviewRenderer.visibleContentRect(bounds: bounds, scrollOffset: -320),
            CGRect(x: 0, y: -320, width: 1440, height: 900)
        )
    }

    func testCullingKeepsIntersectingFramesAndRejectsHiddenFrames() {
        let viewport = CGRect(x: 0, y: -320, width: 1440, height: 900)
        let visible = CGRect(x: 100, y: 100, width: 300, height: 200)
        let hidden = CGRect(x: 100, y: -700, width: 300, height: 200)

        XCTAssertTrue(OverviewRenderer.shouldRender(frame: visible, visibleContentRect: viewport))
        XCTAssertFalse(OverviewRenderer.shouldRender(frame: hidden, visibleContentRect: viewport))
    }

    func testSectionCullingIncludesInterpolatedAnimationFrame() {
        let token = WindowToken(pid: 1, windowId: 1)
        let workspaceId = UUID()
        let window = OverviewWindowItem(
            handle: WindowHandle(id: token),
            windowId: token.windowId,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
            overviewFrame: CGRect(x: 100, y: -1000, width: 300, height: 200),
            matchesSearch: true
        )
        let section = OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [window],
            sectionFrame: CGRect(x: 0, y: -1100, width: 1000, height: 400),
            labelFrame: CGRect(x: 20, y: -700, width: 960, height: 32),
            gridFrame: CGRect(x: 0, y: -1100, width: 1000, height: 400),
            isActive: true
        )
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertFalse(
            OverviewRenderer.shouldRender(
                frame: section.sectionFrame.union(section.labelFrame),
                visibleContentRect: viewport
            )
        )
        XCTAssertTrue(
            OverviewRenderer.shouldRender(
                frame: OverviewRenderer.sectionCullingFrame(section, progress: 0.1),
                visibleContentRect: viewport
            )
        )
    }

    @MainActor
    func testLayoutCachesRasterizedApplicationIcon() {
        let bitmap = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let sourceImage = bitmap.makeImage()!
        let appIcon = NSImage(cgImage: sourceImage, size: NSSize(width: 4, height: 4))
        let workspaceId = UUID()
        let token = WindowToken(pid: 1, windowId: 1)
        let handle = WindowHandle(id: token)
        let data: OverviewWindowLayoutData = (
            token: token,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: appIcon,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let layout = OverviewLayoutCalculator.calculateLayout(
            workspaces: [(id: workspaceId, name: "Workspace", isActive: true)],
            windows: [handle: data],
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            searchQuery: "",
            scale: 1
        )

        XCTAssertEqual(layout.allWindows.first?.appIcon?.width, 4)
        XCTAssertEqual(layout.allWindows.first?.appIcon?.height, 4)
    }

    func testSectionCullingIncludesWorkspaceLabelFrame() {
        let sectionFrame = CGRect(x: 0, y: -500, width: 1000, height: 400)
        let labelFrame = CGRect(x: 20, y: -116, width: 960, height: 32)
        let viewport = CGRect(x: 0, y: -90, width: 1000, height: 800)

        XCTAssertFalse(OverviewRenderer.shouldRender(frame: sectionFrame, visibleContentRect: viewport))
        XCTAssertTrue(
            OverviewRenderer.shouldRender(
                frame: sectionFrame.union(labelFrame),
                visibleContentRect: viewport
            )
        )
    }

    @MainActor
    func testLayoutPublicationCanIncludePaletteInOneUpdate() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5),
            normalBorderColor: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6),
            hoveredBorderColor: SettingsColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.7),
            selectedBorderColor: SettingsColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)
        )
        var layout = OverviewLayout()
        layout.scale = 1.25
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        view.updateLayout(
            layout,
            state: .open,
            searchQuery: "term",
            selectedWindowHandle: nil,
            palette: palette
        )

        XCTAssertEqual(view.layout.scale, 1.25)
        XCTAssertEqual(view.searchQuery, "term")
        assertColor(view.palette.backdrop, equals: [0.2, 0.3, 0.4, 0.5])
    }

    @MainActor
    func testAnimationProgressIsPanelLocalAndSurvivesDiscreteLayoutUpdates() {
        let first = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayId: 101
        )
        let second = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayId: 202
        )
        let layout = OverviewLayout()
        first.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        second.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        OverviewFrameTrace.shared.beginCapture()
        defer { OverviewFrameTrace.shared.endCapture() }

        first.updateAnimationProgress(0.35, generation: 7, sequence: 1)
        XCTAssertEqual(first.presentationProgress, 0.35)
        XCTAssertEqual(second.presentationProgress, 0)
        XCTAssertEqual(first.tracePendingInvalidations, 1)
        XCTAssertEqual(second.tracePendingInvalidations, 0)

        second.updateAnimationProgress(0.7, generation: 7, sequence: 1)
        first.updateLayout(layout, state: .opening, searchQuery: "updated", selectedWindowHandle: nil)

        XCTAssertEqual(first.presentationProgress, 0.35)
        XCTAssertEqual(second.presentationProgress, 0.7)
        XCTAssertEqual(first.tracePendingInvalidations, 1)
        XCTAssertEqual(second.tracePendingInvalidations, 1)

        first.updateLayout(layout, state: .open, searchQuery: "updated", selectedWindowHandle: nil)
        XCTAssertEqual(first.presentationProgress, 1)
    }

    @MainActor
    func testOverviewFrameTraceSeparatesInvalidationAndDrawTiming() throws {
        let view = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            displayId: 303
        )
        view.updateLayout(.init(), state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let graphicsContext = NSGraphicsContext(cgContext: bitmap, flipped: false)

        OverviewFrameTrace.shared.beginCapture()
        view.updateAnimationProgress(0.5, generation: 9, sequence: 4)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        OverviewFrameTrace.shared.endCapture()

        let trace = OverviewFrameTrace.shared.dump()
        XCTAssertTrue(trace.contains("event=invalidation"))
        XCTAssertTrue(trace.contains("event=draw"))
        XCTAssertTrue(trace.contains("disp=303 gen=9 seq=4"))
    }

    @MainActor
    func testOverviewFrameTraceDoesNotCarryPendingStateAcrossCaptureRestart() throws {
        let drawnAfterStop = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            displayId: 304
        )
        let notDrawnAfterStop = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            displayId: 305
        )
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let graphicsContext = NSGraphicsContext(cgContext: bitmap, flipped: false)

        OverviewFrameTrace.shared.beginCapture()
        drawnAfterStop.updateAnimationProgress(0.25, generation: 10, sequence: 1)
        notDrawnAfterStop.updateAnimationProgress(0.25, generation: 10, sequence: 1)
        OverviewFrameTrace.shared.endCapture()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        drawnAfterStop.draw(drawnAfterStop.bounds)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(drawnAfterStop.tracePendingInvalidations, 0)
        XCTAssertEqual(notDrawnAfterStop.tracePendingInvalidations, 1)

        OverviewFrameTrace.shared.beginCapture()
        drawnAfterStop.updateAnimationProgress(0.75, generation: 11, sequence: 1)
        notDrawnAfterStop.updateAnimationProgress(0.75, generation: 11, sequence: 1)
        XCTAssertEqual(drawnAfterStop.tracePendingInvalidations, 1)
        XCTAssertEqual(notDrawnAfterStop.tracePendingInvalidations, 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        drawnAfterStop.draw(drawnAfterStop.bounds)
        notDrawnAfterStop.draw(notDrawnAfterStop.bounds)
        NSGraphicsContext.restoreGraphicsState()
        OverviewFrameTrace.shared.endCapture()

        let trace = OverviewFrameTrace.shared.dump()
        XCTAssertTrue(trace.contains("disp=304 gen=11 seq=1"))
        XCTAssertTrue(trace.contains("disp=305 gen=11 seq=1"))
        XCTAssertFalse(trace.contains("pending=2"))
    }

    private func assertColor(
        _ color: CGColor,
        equals expected: [CGFloat],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let components = color.components else {
            XCTFail("Expected RGB color components", file: file, line: line)
            return
        }

        XCTAssertEqual(components.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(components, expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001, file: file, line: line)
        }
    }
}
