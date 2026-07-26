// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Darwin
import Foundation

struct RuntimeQuakeTerminalFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct IssueDraft: Codable, Equatable {
    var title: String = ""
    var actual: String = ""
    var expected: String = ""
    var repro: String = ""
    var affectedApps: String = ""
    var category: String = ""
    var layout: String = ""
    var regression: String = ""
    var regressionVersion: String = ""
    var polishedBody: String = ""
}

enum MonitorSetupStatus: String, Codable, Equatable, Sendable {
    case notPresented
    case dismissed
    case completed
}

struct RuntimeState: Codable, Equatable {
    var windowRestoreCatalog: PersistedWindowRestoreCatalog?
    var updaterLastCheckedAt: Date?
    var updaterSkippedReleaseTag: String?
    var commandPaletteLastMode: String?
    var quakeTerminalUseCustomFrame: Bool?
    var quakeTerminalCustomFrame: RuntimeQuakeTerminalFrame?
    var issueDraft: IssueDraft?
    var hasSeenIssueWalkthrough: Bool?
    var monitorSetupStatus: MonitorSetupStatus?
}

@MainActor
final class RuntimeStateStore {
    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.stateDirectory
    nonisolated static let fileName = "runtime-state.json"
    nonisolated static let defaultCommandPaletteLastMode = CommandPaletteMode.windows
    nonisolated static let defaultQuakeTerminalUseCustomFrame = false
    nonisolated static let defaultMonitorSetupStatus = MonitorSetupStatus.notPresented
    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private var state: RuntimeState
    private var pendingState: RuntimeState?
    private var saveScheduled = false

    init(
        directory: URL = RuntimeStateStore.defaultDirectoryURL,
        deferSaves: Bool = true
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves
        state = Self.readState(from: directory.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    func load() -> RuntimeState {
        state
    }

    func save(_ state: RuntimeState) {
        self.state = state
        write(state)
    }

    func scheduleSave() {
        if !deferSaves {
            pendingState = nil
            write(state)
            return
        }

        pendingState = state
        guard !saveScheduled else { return }
        saveScheduled = true

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            saveScheduled = false
            flushNow()
        }
    }

    func flushNow() {
        guard let state = pendingState else { return }
        pendingState = nil
        write(state)
    }

    var windowRestoreCatalog: PersistedWindowRestoreCatalog? {
        get { state.windowRestoreCatalog }
        set {
            guard state.windowRestoreCatalog != newValue else { return }
            state.windowRestoreCatalog = newValue
            scheduleSave()
        }
    }

    var updaterLastCheckedAt: Date? {
        get { state.updaterLastCheckedAt }
        set {
            guard state.updaterLastCheckedAt != newValue else { return }
            state.updaterLastCheckedAt = newValue
            scheduleSave()
        }
    }

    var updaterSkippedReleaseTag: String? {
        get { state.updaterSkippedReleaseTag }
        set {
            guard state.updaterSkippedReleaseTag != newValue else { return }
            state.updaterSkippedReleaseTag = newValue
            scheduleSave()
        }
    }

    var commandPaletteLastMode: CommandPaletteMode {
        get {
            state.commandPaletteLastMode.flatMap(CommandPaletteMode.init(rawValue:)) ?? Self
                .defaultCommandPaletteLastMode
        }
        set {
            guard commandPaletteLastMode != newValue else { return }
            state.commandPaletteLastMode = newValue.rawValue
            scheduleSave()
        }
    }

    var quakeTerminalUseCustomFrame: Bool {
        get { state.quakeTerminalUseCustomFrame ?? Self.defaultQuakeTerminalUseCustomFrame }
        set {
            guard quakeTerminalUseCustomFrame != newValue else { return }
            state.quakeTerminalUseCustomFrame = newValue
            if !newValue {
                state.quakeTerminalCustomFrame = nil
            }
            scheduleSave()
        }
    }

    var quakeTerminalCustomFrame: CGRect? {
        get { state.quakeTerminalCustomFrame?.frame }
        set {
            let frame = newValue.map(RuntimeQuakeTerminalFrame.init(frame:))
            guard state.quakeTerminalCustomFrame != frame else { return }
            state.quakeTerminalCustomFrame = frame
            if frame == nil {
                state.quakeTerminalUseCustomFrame = false
            }
            scheduleSave()
        }
    }

    var issueDraft: IssueDraft? {
        get { state.issueDraft }
        set {
            guard state.issueDraft != newValue else { return }
            state.issueDraft = newValue
            scheduleSave()
        }
    }

    var hasSeenIssueWalkthrough: Bool {
        get { state.hasSeenIssueWalkthrough ?? false }
        set {
            guard hasSeenIssueWalkthrough != newValue else { return }
            state.hasSeenIssueWalkthrough = newValue
            scheduleSave()
        }
    }

    var monitorSetupStatus: MonitorSetupStatus {
        get { state.monitorSetupStatus ?? Self.defaultMonitorSetupStatus }
        set {
            guard monitorSetupStatus != newValue else { return }
            state.monitorSetupStatus = newValue
            scheduleSave()
        }
    }

    private func write(_ state: RuntimeState) {
        do {
            try writeState(state)
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    private func writeState(_ state: RuntimeState) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Self.applyPermissions(S_IRWXU, to: directoryURL)
        let data = try JSONEncoder().encode(state)
        try Self.writePrivateData(data, to: fileURL)
    }

    private static func writePrivateData(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            try applyPermissions(S_IRUSR | S_IWUSR, to: tempURL)
            try replaceItem(at: fileURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private static func applyPermissions(_ permissions: mode_t, to url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.chmod(path, permissions)
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> CInt in
            guard let sourcePath else { return -1 }
            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> CInt in
                guard let destinationPath else { return -1 }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readState(from url: URL) -> RuntimeState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RuntimeState()
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(RuntimeState.self, from: data)
        } catch {
            Log.config.error("Failed to load \(url.path): \(error.localizedDescription)")
            return RuntimeState()
        }
    }

    private func report(_ message: String) {
        Log.config.error(message)
    }
}
