// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class LaunchOverlayTests: XCTestCase {
    func testEmptyScreensCompletesSynchronously() {
        let controller = LaunchOverlayController()
        var completions = 0
        controller.play(screens: []) { completions += 1 }
        XCTAssertEqual(completions, 1)
    }

    func testWordmarkPathIsNonEmpty() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertFalse(OmniWMBrandMark.omniWordmarkPath(in: rect).isEmpty)
        XCTAssertGreaterThan(OmniWMBrandMark.omniWordmarkAspect, 0)
    }

    func testStatusItemImageIsUntinted() {
        let image = OmniWMBrandMark.statusItemImage(pointSize: 18)
        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testTextChoreographyCyclesThroughExpectedWords() {
        XCTAssertEqual(LaunchTextChoreography.prefix, "Do what you love")
        XCTAssertEqual(LaunchTextChoreography.wordTracks.map(\.text), ["easier.", "faster.", "better."])
        XCTAssertEqual(LaunchTextChoreography.wordTracks.last?.text, "better.")
    }

    func testTextChoreographyTrackInvariants() {
        for track in LaunchTextChoreography.wordTracks {
            let count = track.times.count
            XCTAssertEqual(track.verticalOffsets.count, count)
            XCTAssertEqual(track.opacities.count, count)
            XCTAssertEqual(track.timings.count, count - 1)
            XCTAssertEqual(track.times, track.times.sorted())
            XCTAssertEqual(track.times.first ?? -1, 0, accuracy: 1e-9)
            XCTAssertEqual(
                track.times.last ?? -1,
                LaunchTextChoreography.exitWindow.lowerBound,
                accuracy: 1e-9
            )
        }
    }

    func testTextChoreographyWindowsAreOrderedWithinTotalDuration() {
        let windows = [
            LaunchTextChoreography.taglineEntryWindow,
            LaunchTextChoreography.swapWindows[0],
            LaunchTextChoreography.swapWindows[1],
            LaunchTextChoreography.exitWindow
        ]
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            XCTAssertLessThan(earlier.upperBound, later.lowerBound)
        }
        XCTAssertLessThanOrEqual(
            LaunchTextChoreography.exitWindow.upperBound,
            LaunchTextChoreography.totalDuration
        )
        XCTAssertEqual(LaunchOverlayView.totalDuration, LaunchTextChoreography.totalDuration)
    }

    func testTaglineLayoutIsCenteredBelowWordmarkAndContained() {
        let boundsCases = [
            CGRect(x: 0, y: 0, width: 640, height: 480),
            CGRect(x: 0, y: 0, width: 1728, height: 1117)
        ]
        for bounds in boundsCases {
            let layout = LaunchOverlayLayout(bounds: bounds)
            XCTAssertEqual(layout.taglineRect.midX, bounds.midX, accuracy: 0.001)
            XCTAssertLessThan(layout.taglineRect.maxY, layout.wordmarkRect.minY)
            XCTAssertTrue(bounds.contains(layout.taglineRect))
            XCTAssertTrue(bounds.contains(layout.tickerClipRect))
            XCTAssertTrue(layout.tickerClipRect.contains(layout.tickerRect))
            XCTAssertEqual(layout.prefixRect.minX, layout.taglineRect.minX, accuracy: 0.001)
            XCTAssertGreaterThan(layout.tickerRect.minX, layout.prefixRect.maxX)
            XCTAssertEqual(layout.tickerRect.maxX, layout.taglineRect.maxX, accuracy: 0.001)
        }
    }

    func testTickerReservesWidestWordWidth() {
        let layout = LaunchOverlayLayout(bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
        let font = NSFont.systemFont(ofSize: layout.fontSize, weight: .semibold)
        let widestWord = LaunchTextChoreography.words
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        XCTAssertGreaterThanOrEqual(layout.tickerRect.width, widestWord)
    }
}
