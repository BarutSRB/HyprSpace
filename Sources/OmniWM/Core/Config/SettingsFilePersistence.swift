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
        var targetURL: URL?
        do {
            try ensureDirectoryExists()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                let defaults = SettingsExport.defaults()
                save(defaults)
                return defaults
            }

            let resolvedTargetURL = try Self.settingsTarget(for: fileURL)
            targetURL = resolvedTargetURL
            let snapshot = try readSnapshot(at: resolvedTargetURL)
            lastObservedFingerprint = snapshot.fingerprint
            lastPersistedExport = snapshot.export
            return snapshot.export
        } catch {
            report("Failed to load \(fileURL.path): \(error.localizedDescription)")
            let defaults = SettingsExport.defaults()
            if let targetURL {
                recoverCorruptFile(at: targetURL, with: defaults)
            }
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
        let targetURL = try Self.settingsTarget(for: fileURL)
        try saveImmediately(export, to: targetURL)
    }

    private func saveImmediately(_ export: SettingsExport, to targetURL: URL) throws {
        let observedFingerprint = currentFingerprint()
        if let fingerprint = observedFingerprint,
           fingerprint == lastObservedFingerprint,
           export == lastPersistedExport
        {
            refreshSettingsFileWatcher(for: fingerprint)
            return
        }

        let previous = FileManager.default.fileExists(atPath: targetURL.path) ? try? Data(contentsOf: targetURL) : nil
        let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: previous)
        try data.write(to: targetURL, options: .atomic)

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
            let targetURL = try Self.settingsTarget(for: fileURL)
            let snapshot = try readSnapshot(at: targetURL)
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

    private func readSnapshot(at targetURL: URL) throws -> FileSnapshot {
        let handle = try FileHandle(forReadingFrom: targetURL)
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

    private static func settingsTarget(for url: URL) throws -> URL {
        var fileStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }

        guard result == 0 else {
            let code = errno
            guard code != ENOENT else { return url }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let fileType = fileStatus.st_mode & S_IFMT
        guard fileType == S_IFLNK else {
            guard fileType == S_IFREG else { throw POSIXError(.EFTYPE) }
            return url
        }

        let resolvedURL = try canonicalURL(for: url)
        var targetStatus = stat()
        let targetResult = resolvedURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &targetStatus)
        }

        guard targetResult == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard targetStatus.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return resolvedURL
    }

    private static func canonicalURL(for url: URL) throws -> URL {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            errno = 0
            guard let resolvedPath = Darwin.realpath(path, nil) else {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            defer { Darwin.free(resolvedPath) }
            return URL(
                fileURLWithFileSystemRepresentation: resolvedPath,
                isDirectory: false,
                relativeTo: nil
            )
        }
    }

    private func recoverCorruptFile(at targetURL: URL, with defaults: SettingsExport) {
        let corruptURL = directoryURL.appendingPathComponent(Self.corruptFileName, isDirectory: false)

        do {
            let corruptData = try Data(contentsOf: targetURL)
            try corruptData.write(to: corruptURL, options: .atomic)
            try saveImmediately(defaults, to: targetURL)
        } catch {
            report("Failed to recover corrupt settings file: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        Log.config.error(message)
    }
}
