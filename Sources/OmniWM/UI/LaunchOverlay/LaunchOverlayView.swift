// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import QuartzCore

struct LaunchTextChoreography {
    struct WordTrack {
        let text: String
        let times: [CFTimeInterval]
        let verticalOffsets: [CGFloat]
        let opacities: [CGFloat]
        let timings: [Timing]
    }

    enum Timing {
        case hold
        case move

        var function: CAMediaTimingFunction {
            switch self {
            case .hold:
                CAMediaTimingFunction(name: .linear)
            case .move:
                CAMediaTimingFunction(name: .easeInEaseOut)
            }
        }
    }

    static let prefix = "Do what you love"
    static let words = ["easier.", "faster.", "better."]
    static let totalDuration: CFTimeInterval = 3.6
    static let wordmarkWriteWindow: ClosedRange<CFTimeInterval> = 0.18 ... 1.60
    static let taglineEntryWindow: ClosedRange<CFTimeInterval> = 0.90 ... 1.20
    static let swapWindows: [ClosedRange<CFTimeInterval>] = [1.70 ... 1.95, 2.35 ... 2.60]
    static let exitWindow: ClosedRange<CFTimeInterval> = 3.10 ... 3.55

    static let wordTracks = [
        WordTrack(
            text: words[0],
            times: [
                0,
                taglineEntryWindow.lowerBound,
                taglineEntryWindow.upperBound,
                swapWindows[0].lowerBound,
                swapWindows[0].upperBound,
                exitWindow.lowerBound
            ],
            verticalOffsets: [-1, -1, 0, 0, 1, 1],
            opacities: [0, 0, 1, 1, 0, 0],
            timings: [.hold, .move, .hold, .move, .hold]
        ),
        WordTrack(
            text: words[1],
            times: [
                0,
                swapWindows[0].lowerBound,
                swapWindows[0].upperBound,
                swapWindows[1].lowerBound,
                swapWindows[1].upperBound,
                exitWindow.lowerBound
            ],
            verticalOffsets: [-1, -1, 0, 0, 1, 1],
            opacities: [0, 0, 1, 1, 0, 0],
            timings: [.hold, .move, .hold, .move, .hold]
        ),
        WordTrack(
            text: words[2],
            times: [0, swapWindows[1].lowerBound, swapWindows[1].upperBound, exitWindow.lowerBound],
            verticalOffsets: [-1, -1, 0, 0],
            opacities: [0, 0, 1, 1],
            timings: [.hold, .move, .hold]
        )
    ]
}

@MainActor
struct LaunchOverlayLayout {
    private struct TextMetrics {
        let prefixWidth: CGFloat
        let wordWidth: CGFloat
        let wordGap: CGFloat
        let lineHeight: CGFloat
        let totalWidth: CGFloat
    }

    let wordmarkRect: CGRect
    let taglineRect: CGRect
    let prefixRect: CGRect
    let tickerRect: CGRect
    let tickerClipRect: CGRect
    let fontSize: CGFloat

    init(bounds: CGRect) {
        let wordmarkWidth = min(bounds.width * 0.45, 600)
        let wordmarkHeight = wordmarkWidth / OmniWMBrandMark.omniWordmarkAspect
        wordmarkRect = CGRect(
            x: bounds.midX - wordmarkWidth / 2,
            y: bounds.midY - wordmarkHeight / 2,
            width: wordmarkWidth,
            height: wordmarkHeight
        )

        let availableWidth = bounds.width * 0.8
        var resolvedFontSize = min(max(bounds.width * 0.018, 18), 28)
        var metrics = Self.textMetrics(fontSize: resolvedFontSize)
        if metrics.totalWidth > availableWidth {
            resolvedFontSize *= availableWidth / metrics.totalWidth
            metrics = Self.textMetrics(fontSize: resolvedFontSize)
        }
        fontSize = resolvedFontSize

        let taglineX = bounds.midX - metrics.totalWidth / 2
        let taglineY = max(
            bounds.minY + 24,
            wordmarkRect.minY - max(18, resolvedFontSize * 0.75) - metrics.lineHeight
        )
        prefixRect = CGRect(
            x: taglineX,
            y: taglineY,
            width: metrics.prefixWidth,
            height: metrics.lineHeight
        )
        tickerRect = CGRect(
            x: prefixRect.maxX + metrics.wordGap,
            y: taglineY,
            width: metrics.wordWidth,
            height: metrics.lineHeight
        )
        tickerClipRect = tickerRect.insetBy(dx: -6, dy: -6)
        taglineRect = CGRect(
            x: taglineX,
            y: taglineY,
            width: metrics.totalWidth,
            height: metrics.lineHeight
        )
    }

    private static func textMetrics(fontSize: CGFloat) -> TextMetrics {
        let prefixFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let wordFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let prefixWidth = ceil((LaunchTextChoreography.prefix as NSString).size(withAttributes: [.font: prefixFont])
            .width)
        let wordWidth = ceil(
            LaunchTextChoreography.words
                .map { ($0 as NSString).size(withAttributes: [.font: wordFont]).width }
                .max() ?? 0
        )
        let wordGap = ceil(fontSize * 0.26)
        let lineHeight = ceil(
            max(
                prefixFont.ascender - prefixFont.descender + prefixFont.leading,
                wordFont.ascender - wordFont.descender + wordFont.leading
            ) + 6
        )
        return TextMetrics(
            prefixWidth: prefixWidth,
            wordWidth: wordWidth,
            wordGap: wordGap,
            lineHeight: lineHeight,
            totalWidth: prefixWidth + wordGap + wordWidth
        )
    }
}

@MainActor
final class LaunchOverlayPanel: NSPanel {
    private let overlay: LaunchOverlayView

    init(screen: NSScreen) {
        overlay = LaunchOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            scale: screen.backingScaleFactor
        )
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlay
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func startAnimation(at startTime: CFTimeInterval) {
        overlay.startAnimation(at: startTime)
    }

    func teardown() {
        overlay.teardown()
    }
}

@MainActor
final class LaunchOverlayView: NSView {
    static let totalDuration = LaunchTextChoreography.totalDuration

    private let scale: CGFloat
    private let wordmark = CAShapeLayer()
    private let writeMask = CAShapeLayer()
    private let prefix = CATextLayer()
    private let ticker = CALayer()
    private var wordLayers: [CATextLayer] = []
    private var tickerTravel: CGFloat = 0

    init(frame: CGRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildLayers() {
        guard let host = layer else { return }
        host.contentsScale = scale
        let layout = LaunchOverlayLayout(bounds: bounds)
        configureWordmark(wordRect: layout.wordmarkRect)
        configurePrefix(frame: layout.prefixRect, fontSize: layout.fontSize)
        configureTicker(layout: layout)
        for sublayer in [wordmark, prefix, ticker] as [CALayer] {
            sublayer.contentsScale = scale
            host.addSublayer(sublayer)
        }
    }

    private func configureWordmark(wordRect: CGRect) {
        wordmark.frame = wordRect
        wordmark.path = OmniWMBrandMark.omniWordmarkPath(in: wordmark.bounds)
        wordmark.fillColor = NSColor.white.cgColor
        wordmark.strokeColor = NSColor.clear.cgColor
        applyTextShadow(to: wordmark)

        let line = CGMutablePath()
        line.move(to: CGPoint(x: wordmark.bounds.minX, y: wordmark.bounds.midY))
        line.addLine(to: CGPoint(x: wordmark.bounds.maxX, y: wordmark.bounds.midY))
        writeMask.frame = wordmark.bounds
        writeMask.path = line
        writeMask.fillColor = NSColor.clear.cgColor
        writeMask.strokeColor = NSColor.white.cgColor
        writeMask.lineWidth = wordmark.bounds.height * 1.5
        writeMask.lineCap = .round
        writeMask.strokeEnd = 0
        writeMask.contentsScale = scale
        wordmark.mask = writeMask
    }

    private func configurePrefix(frame: CGRect, fontSize: CGFloat) {
        configureTextLayer(
            prefix,
            text: LaunchTextChoreography.prefix,
            font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            frame: frame
        )
        prefix.opacity = 0
    }

    private func configureTicker(layout: LaunchOverlayLayout) {
        ticker.frame = layout.tickerClipRect
        ticker.masksToBounds = true
        tickerTravel = ticker.bounds.height
        let textFrame = layout.tickerRect.offsetBy(
            dx: -layout.tickerClipRect.minX,
            dy: -layout.tickerClipRect.minY
        )
        for track in LaunchTextChoreography.wordTracks {
            let textLayer = CATextLayer()
            configureTextLayer(
                textLayer,
                text: track.text,
                font: NSFont.systemFont(ofSize: layout.fontSize, weight: .semibold),
                frame: textFrame
            )
            textLayer.opacity = 0
            textLayer.transform = CATransform3DMakeTranslation(0, -tickerTravel, 0)
            ticker.addSublayer(textLayer)
            wordLayers.append(textLayer)
        }
    }

    private func configureTextLayer(_ textLayer: CATextLayer, text: String, font: NSFont, frame: CGRect) {
        textLayer.frame = frame
        textLayer.string = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ]
        )
        textLayer.alignmentMode = .left
        textLayer.contentsScale = scale
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        applyTextShadow(to: textLayer)
    }

    private func applyTextShadow(to textLayer: CALayer) {
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOpacity = 0.58
        textLayer.shadowRadius = 4
        textLayer.shadowOffset = CGSize(width: 0, height: -1)
    }

    func startAnimation(at t0: CFTimeInterval) {
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let hand = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.5, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        writeMask.strokeEnd = 1
        run(
            "strokeEnd",
            [0, 1],
            over: shifted(LaunchTextChoreography.wordmarkWriteWindow, by: t0),
            timing: hand,
            on: writeMask
        )

        prefix.opacity = 1
        prefix.transform = CATransform3DIdentity
        run(
            "opacity",
            [0, 1],
            over: shifted(LaunchTextChoreography.taglineEntryWindow, by: t0),
            timing: easeOut,
            on: prefix
        )
        run(
            "transform.translation.y",
            [-6, 0],
            over: shifted(LaunchTextChoreography.taglineEntryWindow, by: t0),
            timing: easeOut,
            on: prefix
        )

        for (textLayer, track) in zip(wordLayers, LaunchTextChoreography.wordTracks) {
            addWordTrack(track, to: textLayer, at: t0)
        }

        if let host = layer {
            host.opacity = 0
            host.transform = CATransform3DMakeTranslation(-bounds.width * 1.3, 0, 0)
            run(
                "opacity",
                [1, 0],
                over: shifted(LaunchTextChoreography.exitWindow, by: t0),
                timing: easeOut,
                on: host
            )
            run(
                "transform.translation.x",
                [0, -bounds.width * 1.3],
                over: shifted(LaunchTextChoreography.exitWindow, by: t0),
                timing: easeOut,
                on: host
            )
        }
        CATransaction.commit()
    }

    func teardown() {
        layer?.removeAllAnimations()
        wordmark.removeAllAnimations()
        writeMask.removeAllAnimations()
        prefix.removeAllAnimations()
        ticker.removeAllAnimations()
        for textLayer in wordLayers {
            textLayer.removeAllAnimations()
        }
    }

    private func addWordTrack(
        _ track: LaunchTextChoreography.WordTrack,
        to textLayer: CATextLayer,
        at t0: CFTimeInterval
    ) {
        guard let duration = track.times.last,
              let finalOffset = track.verticalOffsets.last,
              let finalOpacity = track.opacities.last
        else { return }

        textLayer.opacity = Float(finalOpacity)
        textLayer.transform = CATransform3DMakeTranslation(0, finalOffset * tickerTravel, 0)

        let keyTimes = track.times.map { NSNumber(value: $0 / duration) }
        let translation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        translation.values = track.verticalOffsets.map { NSNumber(value: Double($0 * tickerTravel)) }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = track.opacities.map { NSNumber(value: Double($0)) }

        for animation in [translation, opacity] {
            animation.keyTimes = keyTimes
            animation.timingFunctions = track.timings.map(\.function)
            animation.beginTime = textLayer.convertTime(t0, from: nil)
            animation.duration = duration
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }
        textLayer.add(translation, forKey: "wordTranslation")
        textLayer.add(opacity, forKey: "wordOpacity")
    }

    private func shifted(
        _ window: ClosedRange<CFTimeInterval>,
        by offset: CFTimeInterval
    ) -> ClosedRange<CFTimeInterval> {
        (window.lowerBound + offset) ... (window.upperBound + offset)
    }

    private func run(
        _ keyPath: String,
        _ values: [CGFloat],
        over window: ClosedRange<CFTimeInterval>,
        timing: CAMediaTimingFunction? = nil,
        on layer: CALayer
    ) {
        let animation: CAPropertyAnimation
        if values.count <= 2 {
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.fromValue = values.first
            basic.toValue = values.last
            basic.timingFunction = timing
            animation = basic
        } else {
            let keyframe = CAKeyframeAnimation(keyPath: keyPath)
            keyframe.values = values
            animation = keyframe
        }
        animation.beginTime = layer.convertTime(window.lowerBound, from: nil)
        animation.duration = window.upperBound - window.lowerBound
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
    }
}
