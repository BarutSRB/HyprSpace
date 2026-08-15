// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

@MainActor
final class SettingsFilePersistence {
    struct FileFingerprint: Equatable {
        // Atomic external editors replace the path with a new inode; mtime+size alone
        // can match a just-written file closely enough to suppress a real reload.
        let deviceID: UInt64
        let inode: UInt64
        let modificationTimeNanoseconds: Int64
        let statusChangeTimeNanoseconds: Int64
        let fileSize: UInt64
    }

    private struct FileSnapshot {
        let export: SettingsExport
        let fingerprint: FileFingerprint
    }

    private struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64

        init(_ fingerprint: FileFingerprint) {
            deviceID = fingerprint.deviceID
            inode = fingerprint.inode
        }
    }

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.configDirectory
    nonisolated static let fileName = "settings.toml"
    nonisolated static let corruptFileName = "settings.toml.corrupt"
    nonisolated static var fileURL: URL {
        defaultDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    let directoryURL: URL
    let fileURL: URL

    private let deferSaves: Bool
    private var directoryFileDescriptor: CInt = -1
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var settingsFileDescriptor: CInt = -1
    private var settingsFileWatcher: DispatchSourceFileSystemObject?
    private var watchedSettingsFileIdentity: FileIdentity?
    private var pendingExport: SettingsExport?
    private var saveScheduled = false
    private var lastWrittenFingerprint: FileFingerprint?
    private var lastObservedFingerprint: FileFingerprint?
    private var lastPersistedExport: SettingsExport?
    private var onExternalChange: (@MainActor (SettingsExport) -> Void)?

    init(
        directory: URL = SettingsFilePersistence.defaultDirectoryURL,
        startWatching: Bool = true,
        deferSaves: Bool = true
    ) {
        directoryURL = directory
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.deferSaves = deferSaves

        if startWatching {
            startWatchers()
        }
    }

    deinit {
        settingsFileWatcher?.cancel()
        if settingsFileWatcher == nil, settingsFileDescriptor >= 0 {
            close(settingsFileDescriptor)
        }
        directoryWatcher?.cancel()
        if directoryWatcher == nil, directoryFileDescriptor >= 0 {
            close(directoryFileDescriptor)
        }
    }

    func setExternalChangeHandler(_ handler: @escaping @MainActor (SettingsExport) -> Void) {
        onExternalChange = handler
    }

    func load() -> SettingsExport {
        do {
            try ensureDirectoryExists()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let defaults = SettingsExport.defaults()
                save(defaults)
                return defaults
            }

            let snapshot = try readSnapshot()
            lastObservedFingerprint = snapshot.fingerprint
            lastPersistedExport = snapshot.export
            return snapshot.export
        } catch {
            report("Failed to load \(fileURL.path): \(error.localizedDescription)")
            moveCorruptFileAsideIfPresent()
            let defaults = SettingsExport.defaults()
            save(defaults)
            return defaults
        }
    }

    func save(_ export: SettingsExport) {
        do {
            try saveImmediately(export)
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    func saveImmediately(_ export: SettingsExport) throws {
        try ensureDirectoryExists()
        let observedFingerprint = currentFingerprint()
        if let fingerprint = observedFingerprint,
           fingerprint == lastObservedFingerprint,
           export == lastPersistedExport
        {
            refreshSettingsFileWatcher(for: fingerprint)
            return
        }

        let previous = FileManager.default.fileExists(atPath: fileURL.path) ? try? Data(contentsOf: fileURL) : nil
        let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        try data.write(to: Self.resolvingSymlink(fileURL), options: .atomic)

        let fingerprint = currentFingerprint()
        lastWrittenFingerprint = fingerprint
        lastObservedFingerprint = fingerprint
        lastPersistedExport = export
        refreshSettingsFileWatcher(for: fingerprint)
    }

    func scheduleSave(_ export: @autoclosure () -> SettingsExport) {
        if !deferSaves {
            pendingExport = nil
            save(export())
            return
        }

        pendingExport = export()
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
        guard let export = pendingExport else { return }
        pendingExport = nil
        save(export)
    }

    func reloadIfChanged() -> SettingsExport? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            report("Ignoring external reload because \(fileURL.path) no longer exists.")
            return nil
        }

        do {
            let snapshot = try readSnapshot()
            lastObservedFingerprint = snapshot.fingerprint
            lastPersistedExport = snapshot.export
            return snapshot.export
        } catch {
            report("Ignoring invalid external settings edit at \(fileURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    private func startWatchers() {
        do {
            try ensureDirectoryExists()
        } catch {
            report("Failed to create settings directory \(directoryURL.path): \(error.localizedDescription)")
            return
        }

        startDirectoryWatcher()
        refreshSettingsFileWatcher()
    }

    private func startDirectoryWatcher() {
        directoryFileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard directoryFileDescriptor >= 0 else {
            report("Failed to watch settings directory \(directoryURL.path).")
            return
        }

        let fileDescriptor = directoryFileDescriptor
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            self?.handleDirectoryWriteEvent()
        }
        watcher.setCancelHandler { [weak self] in
            close(fileDescriptor)
            self?.directoryFileDescriptor = -1
        }
        directoryWatcher = watcher
        watcher.resume()
    }

    private func handleDirectoryWriteEvent() {
        handlePossibleSettingsFileChange()
    }

    private func handleSettingsFileEvent() {
        handlePossibleSettingsFileChange()
    }

    private func handlePossibleSettingsFileChange() {
        let observedFingerprint = currentFingerprint()
        refreshSettingsFileWatcher(for: observedFingerprint)

        if observedFingerprint == lastWrittenFingerprint {
            lastObservedFingerprint = observedFingerprint
            return
        }

        guard observedFingerprint != lastObservedFingerprint else { return }
        guard let export = reloadIfChanged() else { return }
        onExternalChange?(export)
    }

    private func refreshSettingsFileWatcher(for observedFingerprint: FileFingerprint? = nil) {
        let fingerprint = observedFingerprint ?? currentFingerprint()
        guard let fingerprint else {
            cancelSettingsFileWatcher()
            return
        }

        let identity = FileIdentity(fingerprint)
        guard settingsFileWatcher == nil || watchedSettingsFileIdentity != identity else { return }

        cancelSettingsFileWatcher()

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            settingsFileDescriptor = -1
            watchedSettingsFileIdentity = nil
            report("Failed to watch settings file \(fileURL.path).")
            return
        }

        settingsFileDescriptor = fileDescriptor
        watchedSettingsFileIdentity = identity

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            self?.handleSettingsFileEvent()
        }
        watcher.setCancelHandler { [weak self] in
            close(fileDescriptor)
            if self?.settingsFileDescriptor == fileDescriptor {
                self?.settingsFileDescriptor = -1
            }
        }
        settingsFileWatcher = watcher
        watcher.resume()
    }

    private func cancelSettingsFileWatcher() {
        settingsFileWatcher?.cancel()
        settingsFileWatcher = nil
        settingsFileDescriptor = -1
        watchedSettingsFileIdentity = nil
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func readSnapshot() throws -> FileSnapshot {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        guard let data = try handle.readToEnd() else {
            throw CocoaError(.fileReadUnknown)
        }

        var statBuffer = stat()
        guard Darwin.fstat(handle.fileDescriptor, &statBuffer) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return FileSnapshot(
            export: try SettingsTOMLCodec.decode(data),
            fingerprint: Self.fingerprint(from: statBuffer)
        )
    }

    private func currentFingerprint() -> FileFingerprint? {
        var statBuffer = stat()
        let result = fileURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.fstatat(AT_FDCWD, path, &statBuffer, 0)
        }

        guard result == 0 else { return nil }
        return Self.fingerprint(from: statBuffer)
    }

    private static func fingerprint(from statBuffer: stat) -> FileFingerprint {
        FileFingerprint(
            deviceID: UInt64(statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            modificationTimeNanoseconds: nanoseconds(from: statBuffer.st_mtimespec),
            statusChangeTimeNanoseconds: nanoseconds(from: statBuffer.st_ctimespec),
            fileSize: UInt64(statBuffer.st_size)
        )
    }

    private static func nanoseconds(from timestamp: timespec) -> Int64 {
        Int64(timestamp.tv_sec) * nanosecondsPerSecond + Int64(timestamp.tv_nsec)
    }

    private static func resolvingSymlink(_ url: URL) throws -> URL {
        var resolved = url.standardizedFileURL
        var visitedPaths = Set<String>()
        while let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
            guard visitedPaths.insert(resolved.path).inserted else {
                throw POSIXError(.ELOOP)
            }
            resolved = (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : resolved.deletingLastPathComponent().appendingPathComponent(destination)
            ).standardizedFileURL
        }
        return resolved
    }

    private func moveCorruptFileAsideIfPresent() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let corruptURL = directoryURL.appendingPathComponent(Self.corruptFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: corruptURL)

        do {
            try FileManager.default.moveItem(at: fileURL, to: corruptURL)
        } catch {
            report("Failed to move corrupt settings file aside: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        Log.config.error(message)
    }
}
