// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import GhosttyKit

enum QuakeGhosttyGlassStyle: Sendable, Equatable {
    case regular
    case clear
}

struct QuakeGhosttyRGB: Sendable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct QuakeGhosttyAppearance: Sendable, Equatable {
    let glassStyle: QuakeGhosttyGlassStyle?
    let backgroundColor: QuakeGhosttyRGB?
    let opacity: Double

    init(
        red: UInt8?,
        green: UInt8?,
        blue: UInt8?,
        opacity: Double,
        backgroundBlur: Int16
    ) {
        glassStyle = switch backgroundBlur {
        case -1:
            .regular
        case -2:
            .clear
        default:
            nil
        }
        if let red, let green, let blue {
            backgroundColor = QuakeGhosttyRGB(red: red, green: green, blue: blue)
        } else {
            backgroundColor = nil
        }
        self.opacity = min(max(opacity, 0), 1)
    }

    init(config: ghostty_config_t) {
        var background = ghostty_config_color_s()
        let backgroundKey = "background"
        let hasBackground = ghostty_config_get(
            config,
            &background,
            backgroundKey,
            UInt(backgroundKey.utf8.count)
        )

        var opacity = 1.0
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(
            config,
            &opacity,
            opacityKey,
            UInt(opacityKey.utf8.count)
        )

        var backgroundBlur: Int16 = 0
        let backgroundBlurKey = "background-blur"
        _ = ghostty_config_get(
            config,
            &backgroundBlur,
            backgroundBlurKey,
            UInt(backgroundBlurKey.utf8.count)
        )

        self.init(
            red: hasBackground ? background.r : nil,
            green: hasBackground ? background.g : nil,
            blue: hasBackground ? background.b : nil,
            opacity: opacity,
            backgroundBlur: backgroundBlur
        )
    }
}

enum QuakeGhosttyConfigLoadStep: Equatable {
    case makeConfig
    case loadDefaultFiles
    case loadRecursiveFiles
    case loadFile
    case finalize
}

struct QuakeGhosttyConfigOperations: @unchecked Sendable {
    var makeConfig: @Sendable () -> ghostty_config_t?
    var loadDefaultFiles: @Sendable (ghostty_config_t) -> Void
    var loadRecursiveFiles: @Sendable (ghostty_config_t) -> Void
    var loadFile: @Sendable (ghostty_config_t, String) -> Void
    var finalize: @Sendable (ghostty_config_t) -> Void
    var freeConfig: @Sendable (ghostty_config_t) -> Void
    var recordStep: @Sendable (QuakeGhosttyConfigLoadStep) -> Void

    static let live = QuakeGhosttyConfigOperations(
        makeConfig: ghostty_config_new,
        loadDefaultFiles: ghostty_config_load_default_files,
        loadRecursiveFiles: ghostty_config_load_recursive_files,
        loadFile: { config, path in
            path.withCString {
                ghostty_config_load_file(config, $0)
            }
        },
        finalize: ghostty_config_finalize,
        freeConfig: ghostty_config_free,
        recordStep: { _ in }
    )
}

struct QuakeGhosttyConfigBuilder: Sendable {
    var temporaryDirectory: URL
    var operations: QuakeGhosttyConfigOperations

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-quake-ghostty", isDirectory: true),
        operations: QuakeGhosttyConfigOperations = .live
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.operations = operations
    }

    func build(
        opacity: Double,
        backgroundEffect: QuakeTerminalBackgroundEffect
    ) -> ghostty_config_t? {
        operations.recordStep(.makeConfig)
        guard let config = operations.makeConfig() else { return nil }

        do {
            operations.recordStep(.loadDefaultFiles)
            operations.loadDefaultFiles(config)
            operations.recordStep(.loadRecursiveFiles)
            operations.loadRecursiveFiles(config)
            try withOverrideFile(
                opacity: opacity,
                backgroundEffect: backgroundEffect
            ) { url in
                operations.recordStep(.loadFile)
                operations.loadFile(config, url.path)
            }
            operations.recordStep(.finalize)
            operations.finalize(config)
            return config
        } catch {
            operations.freeConfig(config)
            Log.terminal.error("Failed to build ghostty config: \(error)")
            return nil
        }
    }

    static func overrideContent(
        opacity: Double,
        backgroundEffect: QuakeTerminalBackgroundEffect
    ) -> String {
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), opacity)
        return """
        background-opacity = \(value)
        background-blur = \(backgroundEffect.ghosttyBackgroundBlurValue)

        """
    }

    private func withOverrideFile<T>(
        opacity: Double,
        backgroundEffect: QuakeTerminalBackgroundEffect,
        body: (URL) throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory
            .appendingPathComponent("quake-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("ghostty")
        try Self.overrideContent(
            opacity: opacity,
            backgroundEffect: backgroundEffect
        ).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}
