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

    private struct FileContents {
        let data: Data
        let fingerprint: FileFingerprint
    }

    private enum BackupSlotState {
        case absent
        case matching
        case occupied
    }

    private struct FileIdentity: Equatable {
        let deviceID: UInt64
        let inode: UInt64

        init(_ fingerprint: FileFingerprint) {
            deviceID = fingerprint.deviceID
            inode = fingerprint.inode
        }
    }

    private struct MigrationRewrite {
        let data: Data
        let backupURL: URL
    }

    private enum ExistingSettings {
        case absent
        case decoded(data: Data, result: SettingsTOMLDecodeResult)
        case invalid(data: Data, reason: String)

        var data: Data? {
            switch self {
            case .absent:
                nil
            case let .decoded(data, _),
                 let .invalid(data, _):
                data
            }
        }
    }

    private static let nanosecondsPerSecond: Int64 = 1_000_000_000

    nonisolated static let defaultDirectoryURL = OmniWMStoragePaths.live.configDirectory
    nonisolated static let fileName = "settings.toml"
    nonisolated static let corruptFileName = "settings.toml.corrupt"
    nonisolated static let secondaryCorruptFileName = "settings.toml.corrupt.1"
    nonisolated static let corruptFileNames = [corruptFileName, secondaryCorruptFileName]
    nonisolated static let preVersionOneFileName = "settings.toml.pre-v1"
    nonisolated static let secondaryPreVersionOneFileName = "settings.toml.pre-v1.1"
    nonisolated static let preVersionOneFileNames = [preVersionOneFileName, secondaryPreVersionOneFileName]
    nonisolated static func migrationBackupFileNames(for targetVersion: Int) -> [String] {
        let primary = "settings.toml.pre-v\(targetVersion)"
        return [primary, "\(primary).1"]
    }

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
    private var lastRejectedFingerprint: FileFingerprint?
    private var lastPersistedExport: SettingsExport?
    private var writeBlockNotice: SettingsConfigNotice?
    private var onExternalChange: (@MainActor (SettingsFileLoadOutcome) -> Void)?
    private var onSaveNotice: (@MainActor (SettingsConfigNotice) -> Void)?

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

    var settingsWritesBlocked: Bool {
        writeBlockNotice != nil
    }

    func setExternalChangeHandler(_ handler: @escaping @MainActor (SettingsFileLoadOutcome) -> Void) {
        onExternalChange = handler
    }

    func setSaveNoticeHandler(_ handler: @escaping @MainActor (SettingsConfigNotice) -> Void) {
        onSaveNotice = handler
    }

    func load() -> SettingsExport {
        loadOutcome().export ?? SettingsExport.defaults()
    }

    func loadOutcome() -> SettingsFileLoadOutcome {
        do {
            try ensureDirectoryExists()
            let targetURL = try Self.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                writeBlockNotice = nil
                let defaults = SettingsExport.defaults()
                let notice = try saveImmediately(defaults, to: targetURL)
                return SettingsFileLoadOutcome(export: defaults, notice: notice)
            }

            let contents = try readContents(at: targetURL)
            return decodeContents(
                contents,
                at: targetURL,
                fallback: SettingsExport.defaults(),
                isInitialLoad: true
            )
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            let notice = SettingsConfigNotice.persistenceWriteBlocked(reason: reason)
            writeBlockNotice = notice
            report("Failed to load \(fileURL.path): \(reason)")
            return SettingsFileLoadOutcome(
                export: SettingsExport.defaults(),
                notice: notice
            )
        }
    }

    func save(_ export: SettingsExport) {
        do {
            if let notice = try saveImmediately(export) {
                onSaveNotice?(notice)
            }
        } catch {
            report("Failed to save \(fileURL.path): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveImmediately(_ export: SettingsExport) throws -> SettingsConfigNotice? {
        do {
            if let reason = writeBlockNotice?.blockingReason {
                throw SettingsFilePersistenceError.writesBlocked(reason)
            }
            try ensureDirectoryExists()
            let targetURL = try Self.settingsTarget(for: fileURL)
            return try saveImmediately(export, to: targetURL)
        } catch {
            if writeBlockNotice == nil {
                let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
                writeBlockNotice = .persistenceWriteBlocked(reason: reason)
            }
            if let writeBlockNotice {
                onSaveNotice?(writeBlockNotice)
            }
            throw error
        }
    }

    private func saveImmediately(_ export: SettingsExport, to targetURL: URL) throws -> SettingsConfigNotice? {
        let observedFingerprint = currentFingerprint()
        if let fingerprint = observedFingerprint,
           fingerprint == lastObservedFingerprint,
           export == lastPersistedExport
        {
            refreshSettingsFileWatcher(for: fingerprint)
            return nil
        }

        let existing = try inspectExistingSettings(at: targetURL)
        if case let .decoded(data, result) = existing, let migration = result.migration {
            return try rewriteMigration(
                originalData: data,
                decoded: result,
                export: export,
                migration: migration,
                targetURL: targetURL
            )
        }
        return try preserveAndPersist(export, over: existing, at: targetURL)
    }

    private func inspectExistingSettings(at targetURL: URL) throws -> ExistingSettings {
        guard let data = try existingData(at: targetURL) else { return .absent }
        do {
            return .decoded(data: data, result: try SettingsTOMLCodec.decodeForLoad(data))
        } catch let error as SettingsTOMLCodecError {
            guard case let .unsupportedSchemaVersion(found, supported) = error else {
                return .invalid(data: data, reason: SettingsTOMLCodec.diagnosticDescription(for: error))
            }
            let notice = SettingsConfigNotice.unsupportedVersion(found: found, supported: supported)
            writeBlockNotice = notice
            report("Refusing to overwrite unsupported settings at \(fileURL.path): \(error.localizedDescription)")
            throw error
        } catch {
            return .invalid(data: data, reason: SettingsTOMLCodec.diagnosticDescription(for: error))
        }
    }

    private func rewriteMigration(
        originalData: Data,
        decoded: SettingsTOMLDecodeResult,
        export: SettingsExport,
        migration: SettingsMigrationReport,
        targetURL: URL
    ) throws -> SettingsConfigNotice {
        var backupURL: URL?
        do {
            let rewrite = try prepareMigrationRewrite(
                originalData: originalData,
                decoded: decoded,
                export: export,
                migration: migration
            )
            backupURL = rewrite.backupURL
            try persist(rewrite.data, at: targetURL, export: export)
            reportMigration(migration, backupURL: rewrite.backupURL)
            return .migrated(report: migration, backupURL: rewrite.backupURL)
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            writeBlockNotice = .migrationWriteBlocked(
                report: migration,
                backupURL: backupURL,
                reason: reason
            )
            report("Failed to preserve and upgrade \(fileURL.path); writes are blocked: \(reason)")
            throw error
        }
    }

    private func preserveAndPersist(
        _ export: SettingsExport,
        over existing: ExistingSettings,
        at targetURL: URL
    ) throws -> SettingsConfigNotice? {
        do {
            let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: existing.data)
            try persist(data, at: targetURL, export: export)
            return nil
        } catch let error as SettingsTOMLCodecError {
            switch error {
            case .cannotSafelyPreservePreviousData:
                guard case let .invalid(data, reason) = existing else {
                    return try blockUnsafePreservation(error)
                }
                return try recoverInvalidDuringSave(data, reason: reason, export: export, targetURL: targetURL)
            case .cannotSafelyPreserveArrayElement:
                return try blockUnsafePreservation(error)
            case .invalidSchemaVersion,
                 .unsupportedSchemaVersion,
                 .migrationInvariant:
                throw error
            }
        }
    }

    private func blockUnsafePreservation(_ error: SettingsTOMLCodecError) throws -> SettingsConfigNotice? {
        let reason = error.localizedDescription
        writeBlockNotice = .persistenceWriteBlocked(reason: reason)
        report("Refusing to overwrite \(fileURL.path); writes are blocked: \(reason)")
        throw error
    }

    private func recoverInvalidDuringSave(
        _ invalidData: Data,
        reason: String,
        export: SettingsExport,
        targetURL: URL
    ) throws -> SettingsConfigNotice {
        do {
            let backupURL = try recoverInvalidSettings(invalidData, at: targetURL, replacingWith: export)
            report("Recovered invalid settings from \(fileURL.path) to \(backupURL.path): \(reason)")
            return .recoveredInvalid(backupURL: backupURL, reason: reason)
        } catch {
            let recoveryReason = SettingsTOMLCodec.diagnosticDescription(for: error)
            let combinedReason = "\(reason) Recovery failed: \(recoveryReason)"
            writeBlockNotice = .persistenceWriteBlocked(reason: combinedReason)
            report("Failed to recover invalid settings at \(fileURL.path): \(combinedReason)")
            throw error
        }
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
        reloadOutcomeIfChanged()?.export
    }

    func reloadOutcomeIfChanged() -> SettingsFileLoadOutcome? {
        do {
            let targetURL = try Self.settingsTarget(for: fileURL)
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                report("Ignoring external reload because \(fileURL.path) no longer exists.")
                return nil
            }
            let contents = try readContents(at: targetURL)
            return decodeContents(
                contents,
                at: targetURL,
                fallback: lastPersistedExport ?? SettingsExport.defaults(),
                isInitialLoad: false
            )
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            report("Ignoring invalid external settings edit at \(fileURL.path): \(reason)")
            return nil
        }
    }

    private func decodeContents(
        _ contents: FileContents,
        at targetURL: URL,
        fallback: SettingsExport,
        isInitialLoad: Bool
    ) -> SettingsFileLoadOutcome {
        do {
            let result = try SettingsTOMLCodec.decodeForLoad(contents.data)
            return applyDecodedContents(result, contents: contents, targetURL: targetURL)
        } catch {
            return applyRejectedContents(error, contents: contents, fallback: fallback, isInitialLoad: isInitialLoad)
        }
    }

    private func applyDecodedContents(
        _ result: SettingsTOMLDecodeResult,
        contents: FileContents,
        targetURL: URL
    ) -> SettingsFileLoadOutcome {
        guard let migration = result.migration else {
            writeBlockNotice = nil
            lastObservedFingerprint = contents.fingerprint
            lastRejectedFingerprint = nil
            lastPersistedExport = result.export
            refreshSettingsFileWatcher(for: contents.fingerprint)
            return SettingsFileLoadOutcome(export: result.export, notice: nil)
        }
        return rewriteMigratedContents(
            result,
            migration: migration,
            contents: contents,
            targetURL: targetURL
        )
    }

    private func rewriteMigratedContents(
        _ result: SettingsTOMLDecodeResult,
        migration: SettingsMigrationReport,
        contents: FileContents,
        targetURL: URL
    ) -> SettingsFileLoadOutcome {
        var backupURL: URL?
        do {
            let rewrite = try prepareMigrationRewrite(
                originalData: contents.data,
                decoded: result,
                export: result.export,
                migration: migration
            )
            backupURL = rewrite.backupURL
            try persist(rewrite.data, at: targetURL, export: result.export)
            reportMigration(migration, backupURL: rewrite.backupURL)
            return SettingsFileLoadOutcome(
                export: result.export,
                notice: .migrated(
                    report: migration,
                    backupURL: rewrite.backupURL
                )
            )
        } catch {
            let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
            let notice = SettingsConfigNotice.migrationWriteBlocked(
                report: migration,
                backupURL: backupURL,
                reason: reason
            )
            writeBlockNotice = notice
            lastObservedFingerprint = contents.fingerprint
            lastPersistedExport = result.export
            refreshSettingsFileWatcher(for: contents.fingerprint)
            report(
                "Applied migrated settings from \(fileURL.path) in memory, but left the file untouched and blocked writes: \(reason)"
            )
            for message in migration.messages {
                reportNotice("Settings migration: \(message)")
            }
            return SettingsFileLoadOutcome(
                export: result.export,
                notice: notice
            )
        }
    }

    private func applyRejectedContents(
        _ error: Error,
        contents: FileContents,
        fallback: SettingsExport,
        isInitialLoad: Bool
    ) -> SettingsFileLoadOutcome {
        if let codecError = error as? SettingsTOMLCodecError,
           case let .unsupportedSchemaVersion(found, supported) = codecError
        {
            return applyUnsupportedVersion(
                found: found,
                supported: supported,
                contents: contents,
                fallback: fallback,
                isInitialLoad: isInitialLoad
            )
        }
        let reason = SettingsTOMLCodec.diagnosticDescription(for: error)
        writeBlockNotice = nil
        lastRejectedFingerprint = contents.fingerprint
        report("Ignoring invalid settings at \(fileURL.path): \(reason)")
        return SettingsFileLoadOutcome(export: nil, notice: .invalidRejected(reason: reason))
    }

    private func applyUnsupportedVersion(
        found: Int,
        supported: Int,
        contents: FileContents,
        fallback: SettingsExport,
        isInitialLoad: Bool
    ) -> SettingsFileLoadOutcome {
        let notice = SettingsConfigNotice.unsupportedVersion(found: found, supported: supported)
        let reason = notice.blockingReason ?? "Unsupported settings schema."
        writeBlockNotice = notice
        lastObservedFingerprint = contents.fingerprint
        lastRejectedFingerprint = nil
        if lastPersistedExport == nil {
            lastPersistedExport = fallback
        }
        refreshSettingsFileWatcher(for: contents.fingerprint)
        report("Refusing unsupported settings at \(fileURL.path): \(reason) Writes are blocked.")
        return SettingsFileLoadOutcome(export: isInitialLoad ? fallback : nil, notice: notice)
    }

    private func prepareMigrationRewrite(
        originalData: Data,
        decoded: SettingsTOMLDecodeResult,
        export: SettingsExport,
        migration: SettingsMigrationReport
    ) throws -> MigrationRewrite {
        guard let migratedData = decoded.migratedData else {
            throw SettingsTOMLCodecError.migrationInvariant(
                "Settings migration to schema version \(migration.toVersion) did not produce TOML data."
            )
        }
        let data = try SettingsTOMLCodec.encode(export, preservingUnknownKeysFrom: migratedData)
        let backupURL = try secureBackup(
            originalData,
            fileNames: Self.migrationBackupFileNames(for: migration.toVersion),
            exhaustedError: .migrationBackupSlotsExhausted(targetVersion: migration.toVersion)
        )
        return MigrationRewrite(data: data, backupURL: backupURL)
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

    func handlePossibleSettingsFileChange() {
        let observedFingerprint = currentFingerprint()
        refreshSettingsFileWatcher(for: observedFingerprint)

        if observedFingerprint == lastWrittenFingerprint {
            lastObservedFingerprint = observedFingerprint
            return
        }

        guard observedFingerprint != lastObservedFingerprint else { return }
        guard observedFingerprint != lastRejectedFingerprint else { return }
        guard let outcome = reloadOutcomeIfChanged() else { return }
        if outcome.export != nil {
            pendingExport = nil
        }
        onExternalChange?(outcome)
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

    private func readContents(at targetURL: URL) throws -> FileContents {
        let handle = try FileHandle(forReadingFrom: targetURL)
        defer {
            try? handle.close()
        }

        let data = try handle.readToEnd() ?? Data()

        var statBuffer = stat()
        guard Darwin.fstat(handle.fileDescriptor, &statBuffer) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return FileContents(
            data: data,
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

        let resolvedURL: URL
        do {
            resolvedURL = try canonicalURL(for: url)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw SettingsFilePersistenceError.danglingSettingsSymlink(url.path)
        }
        var targetStatus = stat()
        let targetResult = resolvedURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &targetStatus)
        }

        guard targetResult == 0 else {
            let code = errno
            if code == ENOENT {
                throw SettingsFilePersistenceError.danglingSettingsSymlink(url.path)
            }
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

    private func existingData(at targetURL: URL) throws -> Data? {
        var fileStatus = stat()
        let result = targetURL.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.lstat(path, &fileStatus)
        }

        guard result == 0 else {
            let code = errno
            guard code == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return nil
        }

        guard fileStatus.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return try readContents(at: targetURL).data
    }

    @discardableResult
    private func recoverInvalidSettings(
        _ invalidData: Data,
        at targetURL: URL,
        replacingWith export: SettingsExport
    ) throws -> URL {
        let backupURL = try secureBackup(
            invalidData,
            fileNames: Self.corruptFileNames,
            exhaustedError: .corruptBackupSlotsExhausted
        )
        let replacement = try SettingsTOMLCodec.encode(export)
        try persist(replacement, at: targetURL, export: export)
        return backupURL
    }

    private func secureBackup(
        _ data: Data,
        fileNames: [String],
        exhaustedError: SettingsFilePersistenceError
    ) throws -> URL {
        var firstAbsentURL: URL?
        for fileName in fileNames {
            let slotURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            switch Self.backupSlotState(at: slotURL, matching: data) {
            case .matching:
                return slotURL
            case .absent:
                if firstAbsentURL == nil {
                    firstAbsentURL = slotURL
                }
            case .occupied:
                break
            }
        }

        guard let firstAbsentURL else {
            throw exhaustedError
        }
        try Self.writeExclusive(data, to: firstAbsentURL)
        return firstAbsentURL
    }

    private static func backupSlotState(at url: URL, matching expectedData: Data) -> BackupSlotState {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }

        guard fileDescriptor >= 0 else {
            return errno == ENOENT ? .absent : .occupied
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
        }

        var fileStatus = stat()
        guard Darwin.fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG
        else {
            return .occupied
        }
        do {
            return (try handle.readToEnd() ?? Data()) == expectedData ? .matching : .occupied
        } catch {
            return .occupied
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> CInt in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func persist(_ data: Data, at targetURL: URL, export: SettingsExport) throws {
        try data.write(to: targetURL, options: .atomic)
        writeBlockNotice = nil
        let fingerprint = currentFingerprint()
        lastWrittenFingerprint = fingerprint
        lastObservedFingerprint = fingerprint
        lastRejectedFingerprint = nil
        lastPersistedExport = export
        refreshSettingsFileWatcher(for: fingerprint)
    }

    private func reportMigration(_ migration: SettingsMigrationReport, backupURL: URL) {
        reportNotice(
            "Migrated \(fileURL.path) from schema version \(migration.fromVersion) "
                + "to \(migration.toVersion); exact backup: \(backupURL.path)"
        )
        for message in migration.messages {
            reportNotice("Settings migration: \(message)")
        }
    }

    private func reportNotice(_ message: String) {
        Log.config.notice(message)
    }

    private func report(_ message: String) {
        Log.config.error(message)
    }
}
