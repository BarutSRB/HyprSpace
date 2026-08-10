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

    var hasValidCustomSize: Bool {
        width > 0 && height > 0 && width.isFinite && height.isFinite
    }

    var usesFullscreenLayoutFrame: Bool {
        mode == .fill || (mode == .custom && !hasValidCustomSize)
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
        case .custom: hasValidCustomSize ? "\(Self.format(width))x\(Self.format(height))" : "fill"
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
              let width = Double(parts[0]), let height = Double(parts[1])
        else { return nil }
        let fit = SingleWindowFit(mode: .custom, width: width, height: height)
        return fit.hasValidCustomSize ? fit : nil
    }

    private static func format(_ value: Double) -> String {
        if let integer = Int(exactly: value) {
            return String(integer)
        }
        return String(value)
    }
}
