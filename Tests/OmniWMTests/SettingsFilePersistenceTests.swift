// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsFilePersistenceTests: XCTestCase {
    @MainActor
    func testSaveThroughSymlinkPreservesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfilesDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)

        let realFileURL = dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        let initialExport = SettingsExport.defaults()
        let initialData = try SettingsTOMLCodec.encode(initialExport)
        try initialData.write(to: realFileURL)

        let symlinkURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFileURL)

        let persistence = SettingsFilePersistence(directory: configDirectory, startWatching: false, deferSaves: false)
        var export = persistence.load()
        export.gapSize += 1
        try persistence.saveImmediately(export)

        let attributes = try FileManager.default.attributesOfItem(atPath: symlinkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            realFileURL.path
        )

        let persisted = try SettingsTOMLCodec.decode(try Data(contentsOf: realFileURL))
        XCTAssertEqual(persisted.gapSize, export.gapSize)
    }

    @MainActor
    func testSaveThroughDanglingSymlinkPreservesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsDanglingSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfilesDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)

        let realFileURL = dotfilesDirectory.appendingPathComponent("omniwm.toml", isDirectory: false)
        let initialData = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        try initialData.write(to: realFileURL)

        let symlinkURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFileURL)

        // Target removed after the symlink was created, but before the write: settings.toml
        // is now a dangling symlink, which is what should still be preserved.
        try FileManager.default.removeItem(at: realFileURL)

        let persistence = SettingsFilePersistence(directory: configDirectory, startWatching: false, deferSaves: false)
        var export = SettingsExport.defaults()
        export.gapSize += 1
        try persistence.saveImmediately(export)

        let attributes = try FileManager.default.attributesOfItem(atPath: symlinkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            realFileURL.path
        )

        let persisted = try SettingsTOMLCodec.decode(try Data(contentsOf: realFileURL))
        XCTAssertEqual(persisted.gapSize, export.gapSize)
    }

    @MainActor
    func testSaveThroughCyclicSymlinkThrowsAndPreservesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCyclicSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let symlinkURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkURL)

        let persistence = SettingsFilePersistence(directory: configDirectory, startWatching: false, deferSaves: false)
        XCTAssertThrowsError(try persistence.saveImmediately(SettingsExport.defaults()))

        let attributes = try FileManager.default.attributesOfItem(atPath: symlinkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            symlinkURL.path
        )
    }

    @MainActor
    func testSaveThroughCrossDirectoryCyclicSymlinkThrowsAndPreservesSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsCrossDirCyclicSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let otherDirectory = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        // Two relative symlinks pointing at each other across sibling directories: each hop's
        // resolved path grows a fresh `../` segment, so this only trips the cycle guard if
        // resolvingSymlink normalizes paths between hops instead of comparing them raw.
        let symlinkURL = configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        let otherLinkURL = otherDirectory.appendingPathComponent("link2", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "../other/link2")
        try FileManager.default.createSymbolicLink(
            atPath: otherLinkURL.path,
            withDestinationPath: "../config/\(SettingsFilePersistence.fileName)"
        )

        let persistence = SettingsFilePersistence(directory: configDirectory, startWatching: false, deferSaves: false)
        XCTAssertThrowsError(try persistence.saveImmediately(SettingsExport.defaults()))

        let attributes = try FileManager.default.attributesOfItem(atPath: symlinkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            "../other/link2"
        )
    }
}
