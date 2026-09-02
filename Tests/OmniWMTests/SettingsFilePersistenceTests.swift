// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsFilePersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configDirectory: URL
        let dotfilesDirectory: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testSaveThroughAbsoluteSymlinkPreservesLinkTargetAndPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        try SettingsTOMLCodec.encode(SettingsExport.defaults()).write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: targetURL.path)

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        var export = persistence.load()
        export.gapSize += 1
        try persistence.saveImmediately(export)

        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: targetURL)).gapSize, export.gapSize)
        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    @MainActor
    func testSaveThroughRelativeSymlinkUsesFilesystemResolution() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let storeURL = fixture.root.appendingPathComponent("store", isDirectory: true)
        let nestedURL = storeURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let targetURL = storeURL.appendingPathComponent("omniwm.toml", isDirectory: false)
        try SettingsTOMLCodec.encode(SettingsExport.defaults()).write(to: targetURL)

        let directoryLinkURL = fixture.root.appendingPathComponent("dotfiles-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: directoryLinkURL, withDestinationURL: nestedURL)

        let destination = "../dotfiles-link/../omniwm.toml"
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)

        let persistence = makePersistence(in: fixture)
        var export = persistence.load()
        export.gapSize += 1
        try persistence.saveImmediately(export)

        try assertSymlink(at: linkURL, destination: destination)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: targetURL)).gapSize, export.gapSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("omniwm.toml").path))
    }

    @MainActor
    func testDanglingSettingsSymlinkBlocksUntilRestartAfterTargetAppears() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("missing.toml", isDirectory: false)
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        let outcome = persistence.loadOutcome()
        guard let notice = outcome.notice, case let .persistenceWriteBlocked(reason) = notice else {
            return XCTFail("Expected dangling symlink to block settings writes")
        }
        XCTAssertEqual(
            reason,
            "The settings symlink at \(linkURL.path) points to a missing file; "
                + "create its target or replace the symlink, then restart OmniWM."
        )
        XCTAssertEqual(outcome.export, SettingsExport.defaults())
        XCTAssertTrue(persistence.settingsWritesBlocked)

        var appeared = SettingsExport.defaults()
        appeared.gapSize = 37
        let appearedData = try SettingsTOMLCodec.encode(appeared)
        try appearedData.write(to: targetURL)
        XCTAssertThrowsError(try persistence.saveImmediately(.defaults())) { error in
            guard let persistenceError = error as? SettingsFilePersistenceError,
                  case .writesBlocked = persistenceError
            else {
                return XCTFail("Expected writesBlocked, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), appearedData)

        let restarted = makePersistence(in: fixture)
        let restartedOutcome = restarted.loadOutcome()
        XCTAssertEqual(restartedOutcome.export, appeared)
        XCTAssertNil(restartedOutcome.notice)
        XCTAssertFalse(restarted.settingsWritesBlocked)

        try assertSymlink(at: linkURL, destination: targetURL.path)
    }

    @MainActor
    func testCrossDirectorySymlinkCycleThrowsELOOPAndPreservesLinks() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let otherDirectory = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        let settingsDestination = "../other/link2"
        let otherDestination = "../config/\(SettingsFilePersistence.fileName)"
        let linkURL = settingsURL(in: fixture)
        let otherLinkURL = otherDirectory.appendingPathComponent("link2", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: settingsDestination)
        try FileManager.default.createSymbolicLink(atPath: otherLinkURL.path, withDestinationPath: otherDestination)

        let persistence = makePersistence(in: fixture)
        assertPOSIXError(.ELOOP) {
            try persistence.saveImmediately(SettingsExport.defaults())
        }

        try assertSymlink(at: linkURL, destination: settingsDestination)
        try assertSymlink(at: otherLinkURL, destination: otherDestination)
    }

    @MainActor
    func testSymlinkToDirectoryThrowsEFTYPEAndPreservesLink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fixture.dotfilesDirectory)

        let persistence = makePersistence(in: fixture)
        assertPOSIXError(.EFTYPE) {
            try persistence.saveImmediately(SettingsExport.defaults())
        }

        try assertSymlink(at: linkURL, destination: fixture.dotfilesDirectory.path)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dotfilesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testCorruptSymlinkTargetIsLeftUntouchedAtStartupAndSecuredOnSave() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let corruptData = Data([0xFF, 0x00, 0xFE])
        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        try corruptData.write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: targetURL.path)

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        let outcome = persistence.loadOutcome()

        XCTAssertNil(outcome.export)
        guard let notice = outcome.notice, case .invalidRejected = notice else {
            return XCTFail("Expected the invalid startup file to be rejected without recovery")
        }
        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(try Data(contentsOf: targetURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))

        let saveNotice = try XCTUnwrap(persistence.saveImmediately(.defaults()))
        guard case .recoveredInvalid = saveNotice else {
            return XCTFail("Expected the explicit save to secure the rejected bytes")
        }
        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), corruptData)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: targetURL)), SettingsExport.defaults())
        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    @MainActor
    func testInvalidExternalReloadRemainsUnchangedUntilSaveSecuresExactBytes() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        var initial = SettingsExport.defaults()
        initial.gapSize = 17
        try SettingsTOMLCodec.encode(initial).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let loaded = persistence.load()

        let invalidData = Data("[general\nexternal-edit".utf8)
        try invalidData.write(to: settingsURL(in: fixture), options: .atomic)

        let rejected = try XCTUnwrap(persistence.reloadOutcomeIfChanged())
        guard let rejectedNotice = rejected.notice, case let .invalidRejected(rejectedReason) = rejectedNotice else {
            return XCTFail("Expected invalid external-edit notice")
        }
        XCTAssertNil(rejected.export)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture, index: 1).path))

        var desired = loaded
        desired.gapSize = 29
        let saveNotice = try XCTUnwrap(persistence.saveImmediately(desired))
        guard case let .recoveredInvalid(backupURL, recoveredReason) = saveNotice else {
            return XCTFail("Expected recovered-invalid save notice")
        }

        XCTAssertEqual(backupURL, corruptURL(in: fixture))
        XCTAssertEqual(recoveredReason, rejectedReason)
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), invalidData)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))), desired)
    }

    @MainActor
    func testDeferredSaveDoesNotOverwriteAcceptedExternalRestore() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let persistence = SettingsFilePersistence(
            directory: fixture.configDirectory,
            startWatching: false,
            deferSaves: true
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: fixture.root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )
        var restored = settings.toExport()
        restored.outerGapTop = 41

        settings.gapSize = 20
        try SettingsTOMLCodec.encode(restored).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.outerGapTop, 41)
        XCTAssertEqual(settings.gapSize, restored.gapSize)

        settings.flushNow()
        for _ in 0 ..< 4 {
            await Task.yield()
        }

        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: persistence.fileURL)), restored)
        XCTAssertEqual(settings.toExport(), restored)
    }

    @MainActor
    func testStartupEmptyFileIsLeftUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try Data().write(to: settingsURL(in: fixture))

        let loaded = makePersistence(in: fixture).load()

        XCTAssertEqual(loaded, SettingsExport.defaults())
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    @MainActor
    func testStartupStrictDecodeFailureIsLeftUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = try canonicalData { lines in
            let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("raiseOnMouseFocus = ") })
            lines.remove(at: index)
        }
        try invalidData.write(to: settingsURL(in: fixture))

        let outcome = makePersistence(in: fixture).loadOutcome()

        XCTAssertNil(outcome.export)
        guard let notice = outcome.notice, case let .invalidRejected(reason) = notice else {
            return XCTFail("Expected the invalid startup file to be rejected without recovery")
        }
        XCTAssertTrue(reason.contains("raiseOnMouseFocus"))
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    @MainActor
    func testStartupInvalidFileIsSecuredOnFirstSave() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = Data([0xFF, 0x80, 0xFE])
        try invalidData.write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        var desired = persistence.load()
        desired.gapSize = 23

        let saveNotice = try XCTUnwrap(persistence.saveImmediately(desired))

        guard case let .recoveredInvalid(backupURL, _) = saveNotice else {
            return XCTFail("Expected the first save to secure the rejected bytes")
        }
        XCTAssertEqual(backupURL, corruptURL(in: fixture))
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), invalidData)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))), desired)
    }

    @MainActor
    func testSaveRecoveryReusesMatchingBackupWithoutCreatingSecondSlot() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = Data([0xFF, 0x10, 0xFE])
        try invalidData.write(to: settingsURL(in: fixture))
        try invalidData.write(to: corruptURL(in: fixture))
        let originalInode = try fileInode(at: corruptURL(in: fixture))

        let persistence = makePersistence(in: fixture)
        XCTAssertEqual(persistence.load(), SettingsExport.defaults())
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
        try persistence.saveImmediately(.defaults())

        XCTAssertEqual(try fileInode(at: corruptURL(in: fixture)), originalInode)
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture, index: 1).path))
    }

    @MainActor
    func testStrictDecodeFailuresAreBackedUpBeforeLiveReplacement() throws {
        let invalidInputs = try [
            canonicalData { lines in
                let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("followsMouse = ") })
                lines.remove(at: index)
            },
            canonicalData { lines in
                let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("raiseOnMouseFocus = ") })
                lines.remove(at: index)
            },
            canonicalData { lines in
                let index = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("hyperKeyModifiers = ") })
                lines[index] = #"hyperKeyModifiers = "Control""#
            }
        ]

        for invalidData in invalidInputs {
            let fixture = try makeFixture()
            defer { fixture.remove() }

            try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
            let persistence = makePersistence(in: fixture)
            var desired = persistence.load()
            desired.gapSize += 7
            try invalidData.write(to: settingsURL(in: fixture), options: .atomic)

            try persistence.saveImmediately(desired)

            XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), invalidData)
            XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))), desired)
        }
    }

    @MainActor
    func testDistinctInvalidFilesUseBothImmutableBackupSlots() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let loaded = persistence.load()
        let firstInvalidData = Data([0xFF, 0x20, 0xFE])
        let secondInvalidData = Data([0xFF, 0x21, 0xFE])

        try firstInvalidData.write(to: settingsURL(in: fixture), options: .atomic)
        try persistence.saveImmediately(loaded)
        try secondInvalidData.write(to: settingsURL(in: fixture), options: .atomic)
        try persistence.saveImmediately(loaded)

        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture)), firstInvalidData)
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture, index: 1)), secondInvalidData)
    }

    @MainActor
    func testThirdDistinctInvalidFileFailsClosedUntilRestartAfterSlotClears() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        var desired = persistence.load()
        desired.gapSize += 4
        try Data([0x01]).write(to: corruptURL(in: fixture))
        try Data([0x02]).write(to: corruptURL(in: fixture, index: 1))
        let thirdInvalidData = Data([0xFF, 0x30, 0xFE])
        try thirdInvalidData.write(to: settingsURL(in: fixture), options: .atomic)

        XCTAssertThrowsError(try persistence.saveImmediately(desired)) { error in
            XCTAssertEqual(error as? SettingsFilePersistenceError, .corruptBackupSlotsExhausted)
        }
        XCTAssertTrue(persistence.settingsWritesBlocked)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), thirdInvalidData)

        try FileManager.default.removeItem(at: corruptURL(in: fixture, index: 1))
        XCTAssertThrowsError(try persistence.saveImmediately(desired)) { error in
            guard let persistenceError = error as? SettingsFilePersistenceError,
                  case .writesBlocked = persistenceError
            else {
                return XCTFail("Expected writesBlocked, got \(error)")
            }
        }
        let restarted = makePersistence(in: fixture)
        let restartedOutcome = restarted.loadOutcome()
        XCTAssertNil(restartedOutcome.export)
        guard let notice = restartedOutcome.notice, case .invalidRejected = notice else {
            return XCTFail("Expected the restarted load to leave the invalid file untouched")
        }
        let saveNotice = try XCTUnwrap(restarted.saveImmediately(desired))
        guard case .recoveredInvalid = saveNotice else {
            return XCTFail("Expected the save after restart to secure the rejected bytes")
        }

        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture, index: 1)), thirdInvalidData)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: settingsURL(in: fixture))), desired)
    }

    @MainActor
    func testSymlinkBackupSlotIsOccupiedEvenWhenTargetBytesMatch() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = Data([0xFF, 0x40, 0xFE])
        let symlinkTarget = fixture.dotfilesDirectory.appendingPathComponent("recovery.toml", isDirectory: false)
        try invalidData.write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: corruptURL(in: fixture), withDestinationURL: symlinkTarget)
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let desired = persistence.load()
        try invalidData.write(to: settingsURL(in: fixture), options: .atomic)

        try persistence.saveImmediately(desired)

        try assertSymlink(at: corruptURL(in: fixture), destination: symlinkTarget.path)
        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture, index: 1)), invalidData)
    }

    @MainActor
    func testNonregularBackupSlotsCauseRecoveryToFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try FileManager.default.createDirectory(at: corruptURL(in: fixture), withIntermediateDirectories: false)
        try Data([0x01]).write(to: corruptURL(in: fixture, index: 1))
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let desired = persistence.load()
        let invalidData = Data([0xFF, 0x50, 0xFE])
        try invalidData.write(to: settingsURL(in: fixture), options: .atomic)

        XCTAssertThrowsError(try persistence.saveImmediately(desired)) { error in
            XCTAssertEqual(error as? SettingsFilePersistenceError, .corruptBackupSlotsExhausted)
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
    }

    @MainActor
    func testUnreadableBackupSlotIsOccupiedAndSecondSlotIsUsed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = Data([0xFF, 0x60, 0xFE])
        try invalidData.write(to: corruptURL(in: fixture))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: corruptURL(in: fixture).path)
        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let desired = persistence.load()
        try invalidData.write(to: settingsURL(in: fixture), options: .atomic)

        try persistence.saveImmediately(desired)

        XCTAssertEqual(try Data(contentsOf: corruptURL(in: fixture, index: 1)), invalidData)
    }

    @MainActor
    func testBackupCreationFailureLeavesInvalidSettingsUntouched() throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.configDirectory.path
            )
            fixture.remove()
        }

        try SettingsTOMLCodec.encode(.defaults()).write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        let desired = persistence.load()
        let invalidData = Data([0xFF, 0x70, 0xFE])
        try invalidData.write(to: settingsURL(in: fixture), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.configDirectory.path)

        XCTAssertThrowsError(try persistence.saveImmediately(desired))

        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    @MainActor
    func testUnreadableLiveFileDoesNotFallBackToCanonicalRewrite() throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL(in: fixture).path
            )
            fixture.remove()
        }

        let originalData = try SettingsTOMLCodec.encode(.defaults())
        try originalData.write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        var desired = persistence.load()
        desired.gapSize += 3
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settingsURL(in: fixture).path)

        XCTAssertThrowsError(try persistence.saveImmediately(desired))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL(in: fixture).path)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfilesDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, configDirectory: configDirectory, dotfilesDirectory: dotfilesDirectory)
    }

    @MainActor
    private func makePersistence(in fixture: Fixture) -> SettingsFilePersistence {
        SettingsFilePersistence(directory: fixture.configDirectory, startWatching: false, deferSaves: false)
    }

    private func settingsURL(in fixture: Fixture) -> URL {
        fixture.configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
    }

    private func corruptURL(in fixture: Fixture, index: Int = 0) -> URL {
        fixture.configDirectory.appendingPathComponent(
            SettingsFilePersistence.corruptFileNames[index],
            isDirectory: false
        )
    }

    private func fileInode(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func canonicalData(_ mutate: (inout [String]) throws -> Void) throws -> Data {
        var lines = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
            .components(separatedBy: "\n")
        try mutate(&lines)
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func assertSymlink(
        at linkURL: URL,
        destination: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            destination,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertPOSIXError(
        _ expected: POSIXErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? POSIXError)?.code, expected, file: file, line: line)
        }
    }
}
