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
    func testDanglingSymlinkSaveAndLoadPreserveLinkWithoutCreatingTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("missing.toml", isDirectory: false)
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        assertPOSIXError(.ENOENT) {
            try persistence.saveImmediately(SettingsExport.defaults())
        }
        XCTAssertEqual(makePersistence(in: fixture).load(), SettingsExport.defaults())

        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
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
    func testCorruptSymlinkTargetRecoveryPreservesLinkBackupAndPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let corruptData = Data([0xFF, 0x00, 0xFE])
        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        try corruptData.write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: targetURL.path)

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let loaded = makePersistence(in: fixture).load()

        XCTAssertEqual(loaded, SettingsExport.defaults())
        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(
            try Data(contentsOf: fixture.configDirectory
                .appendingPathComponent(SettingsFilePersistence.corruptFileName)),
            corruptData
        )
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(contentsOf: targetURL)), SettingsExport.defaults())
        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
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
