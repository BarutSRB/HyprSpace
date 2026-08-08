// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct SingleWindowFit: Equatable {
    enum Mode: String, CaseIterable, Identifiable, Equatable {
        case fill
        case custom
        case containerPrimarySpan

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .fill: "Full Screen"
            case .custom: "Custom (W:H)"
            case .containerPrimarySpan: "Container Primary Span"
            }
        }
    }

    var mode: Mode
    var width: Double
    var height: Double

    init(
        mode: Mode = .fill,
        width: Double = SingleWindowFit.defaultWidth,
        height: Double = SingleWindowFit.defaultHeight
    ) {
        self.mode = mode
        self.width = width
        self.height = height
    }

    static let defaultWidth: Double = 1920
    static let defaultHeight: Double = 1080
    static let fullScreen = SingleWindowFit(mode: .fill)

    static let dwindleModes: [Mode] = [.fill, .custom]
    static let niriModes: [Mode] = [.fill, .custom, .containerPrimarySpan]

    /// Upper bound (px) for a custom single-window-fit dimension parsed from config.
    ///
    /// Generous over any real display (8K ≈ 7680 px) yet far inside `Int`'s
    /// representable range, so re-serializing via `Int(value)` can never trap.
    /// Larger, or any non-finite, values are rejected at the parse gate and fall
    /// back to full screen like any other invalid config — instead of being
    /// accepted here and aborting the process on the next settings save.
    static let maximumCustomDimension: Double = 1_000_000

    var hasValidCustomSize: Bool {
        width > 0 && height > 0 && width.isFinite && height.isFinite
    }

    func frame(in workingFrame: CGRect) -> CGRect {
        switch mode {
        case .fill,
             .containerPrimarySpan:
            return workingFrame
        case .custom:
            guard hasValidCustomSize else { return workingFrame }
            let w = min(CGFloat(width), workingFrame.width)
            let h = min(CGFloat(height), workingFrame.height)
            return CGRect(
                x: workingFrame.minX + (workingFrame.width - w) / 2,
                y: workingFrame.minY + (workingFrame.height - h) / 2,
                width: w,
                height: h
            )
        }
    }
}

extension SingleWindowFit {
    var serialized: String {
        switch mode {
        case .fill: "fill"
        case .containerPrimarySpan: "container_primary_span"
        case .custom: "\(Self.format(width))x\(Self.format(height))"
        }
    }

    init(serialized raw: String) {
        let token = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch token {
        case "fill",
             "":
            self = .fullScreen
        case "container_primary_span":
            self = SingleWindowFit(mode: .containerPrimarySpan)
        default:
            if token.contains("x"), let fit = Self.parseCustom(token) {
                self = fit
            } else {
                self = .fullScreen
            }
        }
    }

    private static func parseCustom(_ token: String) -> SingleWindowFit? {
        let parts = token.split(separator: "x", maxSplits: 1)
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w > 0, h > 0,
              w.isFinite, h.isFinite,
              w <= maximumCustomDimension, h <= maximumCustomDimension
        else { return nil }
        return SingleWindowFit(mode: .custom, width: w, height: h)
    }

    private static func format(_ value: Double) -> String {
        // Guard the Int conversion: inf/NaN and finite values beyond Int.max all
        // satisfy value == value.rounded(), yet String(Int(value)) traps on them.
        // The TOML parse path rejects these upstream, but the custom-dimension UI
        // fields feed .custom directly via the memberwise init, bypassing parsing,
        // so the trap site itself must be defensive.
        value.isFinite && abs(value) <= Double(Int.max) && value == value.rounded()
            ? String(Int(value)) : String(value)
    }
}
