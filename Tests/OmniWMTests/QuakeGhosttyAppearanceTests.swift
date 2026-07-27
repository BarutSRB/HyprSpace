// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

final class QuakeGhosttyAppearanceTests: XCTestCase {
    func testRegularGlassSentinel() {
        let appearance = makeAppearance(backgroundBlur: -1)

        XCTAssertEqual(appearance.glassStyle, .regular)
    }

    func testClearGlassSentinel() {
        let appearance = makeAppearance(backgroundBlur: -2)

        XCTAssertEqual(appearance.glassStyle, .clear)
    }

    func testNonGlassValuesDoNotProduceGlassStyle() {
        for backgroundBlur in [Int16.min, -3, 0, 1, 20, Int16.max] {
            XCTAssertNil(makeAppearance(backgroundBlur: backgroundBlur).glassStyle)
        }
    }

    func testCopiesRGBBytes() {
        let appearance = QuakeGhosttyAppearance(
            red: 12,
            green: 34,
            blue: 56,
            opacity: 1,
            backgroundBlur: -1
        )

        XCTAssertEqual(
            appearance.backgroundColor,
            QuakeGhosttyRGB(red: 12, green: 34, blue: 56)
        )
    }

    func testIncompleteRGBBytesProduceNoColor() {
        let appearance = QuakeGhosttyAppearance(
            red: 12,
            green: nil,
            blue: 56,
            opacity: 1,
            backgroundBlur: -1
        )

        XCTAssertNil(appearance.backgroundColor)
    }

    func testOpacityIsNormalizedToUnitRange() {
        XCTAssertEqual(makeAppearance(opacity: -0.25).opacity, 0)
        XCTAssertEqual(makeAppearance(opacity: 0.42).opacity, 0.42)
        XCTAssertEqual(makeAppearance(opacity: 1.25).opacity, 1)
    }

    func testQuakeOverrideOwnsEveryBackgroundEffectMode() {
        for effect in QuakeTerminalBackgroundEffect.allCases {
            XCTAssertEqual(
                QuakeGhosttyConfigBuilder.overrideContent(
                    opacity: 0.8,
                    backgroundEffect: effect
                ),
                """
                background-opacity = 0.80
                background-blur = \(effect.ghosttyBackgroundBlurValue)

                """
            )
        }
    }

    @MainActor
    func testGlassViewConfiguresNativeEffectWithoutInterceptingInput() {
        let view = QuakeTerminalGlassView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let tint = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.8)

        view.configure(
            style: .clear,
            backgroundColor: tint.withAlphaComponent(1),
            backgroundOpacity: 0.8,
            isKeyWindow: true
        )

        let glassEffectView = view.subviews.compactMap { $0 as? NSGlassEffectView }.first
        XCTAssertEqual(glassEffectView?.style, .clear)
        XCTAssertEqual(glassEffectView?.tintColor, tint)
        XCTAssertEqual(glassEffectView?.cornerRadius, 0)
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 20)))
    }

    @MainActor
    func testGlassViewAppliesGhosttyInactiveTint() {
        let view = QuakeTerminalGlassView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let overlay = view.subviews.last

        view.configure(
            style: .regular,
            backgroundColor: .white,
            backgroundOpacity: 0.8,
            isKeyWindow: false
        )
        XCTAssertEqual(overlay?.alphaValue, 0.35)

        view.updateKeyStatus(true, backgroundColor: .white)
        XCTAssertEqual(overlay?.alphaValue, 0)

        view.updateKeyStatus(false, backgroundColor: .black)
        XCTAssertEqual(overlay?.alphaValue, 0.85)
    }

    private func makeAppearance(
        opacity: Double = 1,
        backgroundBlur: Int16 = 0
    ) -> QuakeGhosttyAppearance {
        QuakeGhosttyAppearance(
            red: nil,
            green: nil,
            blue: nil,
            opacity: opacity,
            backgroundBlur: backgroundBlur
        )
    }
}
