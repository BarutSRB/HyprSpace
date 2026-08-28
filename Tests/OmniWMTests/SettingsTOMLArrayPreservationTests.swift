// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsTOMLArrayPreservationTests: XCTestCase {
    private let firstRuleID = UUID(uuid: (
        0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
        0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
    ))
    private let secondRuleID = UUID(uuid: (
        0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xCC,
        0xDD, 0xDD, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE
    ))

    func testAppRuleExtensionsFollowExplicitIDsThroughReorderAndUpdate() throws {
        let fixture = try explicitAppRuleFixture()
        var changed = fixture.export
        var first = changed.appRules[0]
        var second = changed.appRules[1]
        first.layout = .tile
        second.assignToWorkspace = "web"
        changed.appRules = [second, first]

        let encoded = try SettingsTOMLCodec.encode(changed, preservingUnknownKeysFrom: fixture.data)
        let firstSection = try section("appRules", containing: firstRuleID.uuidString, in: encoded)
        let secondSection = try section("appRules", containing: secondRuleID.uuidString, in: encoded)

        XCTAssertTrue(firstSection.contains(#"extensionMarker = "first""#))
        XCTAssertTrue(firstSection.contains(#"layout = "tile""#))
        XCTAssertFalse(firstSection.contains(#"extensionMarker = "second""#))
        XCTAssertTrue(secondSection.contains(#"extensionMarker = "second""#))
        XCTAssertTrue(secondSection.contains(#"assignToWorkspace = "web""#))
        XCTAssertFalse(secondSection.contains(#"extensionMarker = "first""#))
    }

    func testDeletedIdentifiedAppRuleDoesNotResurrectExtension() throws {
        let fixture = try explicitAppRuleFixture()
        var changed = fixture.export
        changed.appRules.removeFirst()

        let encoded = try SettingsTOMLCodec.encode(changed, preservingUnknownKeysFrom: fixture.data)
        let text = try utf8String(encoded)

        XCTAssertFalse(text.contains(firstRuleID.uuidString))
        XCTAssertFalse(text.contains(#"extensionMarker = "first""#))
        XCTAssertTrue(text.contains(secondRuleID.uuidString))
        XCTAssertTrue(text.contains(#"extensionMarker = "second""#))
    }

    func testMonitorExtensionsFollowUUIDDisplayIDAndNameIdentities() throws {
        let displayUUID = "12345678-90AB-CDEF-1234-567890ABCDEF"
        let original = monitorExport(displayUUID: displayUUID, updated: false)
        let previous = try monitorData(for: original, displayUUID: displayUUID)
        let changed = monitorExport(displayUUID: displayUUID, updated: true)

        let encoded = try SettingsTOMLCodec.encode(changed, preservingUnknownKeysFrom: previous)
        let uuidSection = try section("monitorRoutingOverrides", containing: displayUUID, in: encoded)
        let displaySection = try section("monitorRoutingOverrides", containing: "monitorDisplayId = 200", in: encoded)
        let nameSection = try section(
            "monitorRoutingOverrides",
            containing: #"monitorName = "Name Monitor""#,
            in: encoded
        )
        let orientationSection = try section(
            "monitorOrientationOverrides",
            containing: #"monitorName = "Portrait""#,
            in: encoded
        )

        XCTAssertTrue(uuidSection.contains(#"extensionMarker = "uuid""#))
        XCTAssertTrue(uuidSection.contains(#"monitorName = "Renamed UUID Monitor""#))
        XCTAssertTrue(displaySection.contains(#"extensionMarker = "display""#))
        XCTAssertTrue(displaySection.contains(#"monitorName = "Renamed Display ID Monitor""#))
        XCTAssertTrue(nameSection.contains(#"extensionMarker = "name""#))
        XCTAssertTrue(nameSection.contains("gridColumn = 3"))
        XCTAssertTrue(orientationSection.contains(#"extensionMarker = "orientation""#))
        XCTAssertTrue(orientationSection.contains(#"orientation = "horizontal""#))
    }

    func testDeletedUUIDMonitorDoesNotTransferExtensionToWeakerNameIdentity() throws {
        let displayUUID = "12345678-90AB-CDEF-1234-567890ABCDEF"
        var original = SettingsExport.defaults()
        original.monitorRoutingSettings = [MonitorRoutingSettings(
            monitorName: "Shared Name",
            monitorDisplayUUID: displayUUID,
            gridColumn: 0,
            gridRow: 0
        )]
        let previous = try addingMarker(
            "uuid",
            after: #"monitorName = "Shared Name""#,
            to: SettingsTOMLCodec.encode(original)
        )
        var changed = original
        changed.monitorRoutingSettings = [MonitorRoutingSettings(
            monitorName: "Shared Name",
            gridColumn: 1,
            gridRow: 0
        )]

        let encoded = try SettingsTOMLCodec.encode(changed, preservingUnknownKeysFrom: previous)
        let text = try utf8String(encoded)

        XCTAssertTrue(text.contains(#"monitorName = "Shared Name""#))
        XCTAssertFalse(text.contains("extensionMarker"))
    }

    func testCanonicalIdlessAppRulePreservesExtensionByUniqueKnownContent() throws {
        var original = SettingsExport.defaults()
        original.appRules = [AppRule(bundleId: "com.example.Unique", layout: .float)]
        let canonical = try utf8String(SettingsTOMLCodec.encode(original))
        let idLine = try XCTUnwrap(canonical.split(separator: "\n").first { $0.hasPrefix("id = ") })
        let previous = Data(canonical
            .replacingOccurrences(of: "\(idLine)\n", with: "")
            .replacingOccurrences(
                of: #"bundleId = "com.example.Unique""#,
                with: #"bundleId = "com.example.Unique""# + "\nextensionMarker = \"unique\""
            ).utf8)
        let loaded = try SettingsTOMLCodec.decode(previous)

        let encoded = try SettingsTOMLCodec.encode(loaded, preservingUnknownKeysFrom: previous)
        let section = try section("appRules", containing: "com.example.Unique", in: encoded)

        XCTAssertTrue(section.contains(#"extensionMarker = "unique""#))
        XCTAssertTrue(section.contains("id = \""))
    }

    func testEmptyMonitorNamePreservesExtensionByUniqueKnownContent() throws {
        var original = SettingsExport.defaults()
        original.monitorRoutingSettings = [MonitorRoutingSettings(
            monitorName: "",
            gridColumn: 0,
            gridRow: 0
        )]
        let previous = try addingMarker(
            "empty-name",
            after: "monitorName = \"\"",
            to: SettingsTOMLCodec.encode(original)
        )
        var changed = original
        changed.gapSize += 1

        let encoded = try SettingsTOMLCodec.encode(changed, preservingUnknownKeysFrom: previous)
        let section = try section("monitorRoutingOverrides", containing: "monitorName = \"\"", in: encoded)

        XCTAssertTrue(section.contains(#"extensionMarker = "empty-name""#))

        var unsafe = original
        unsafe.monitorRoutingSettings[0].gridColumn = 1
        XCTAssertThrowsError(try SettingsTOMLCodec.encode(unsafe, preservingUnknownKeysFrom: previous)) { error in
            XCTAssertEqual(
                error as? SettingsTOMLCodecError,
                .cannotSafelyPreserveArrayElement("monitorRoutingOverrides[0]")
            )
        }
    }

    @MainActor
    func testAmbiguousIdlessExtensionsBlockSaveWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMArrayAmbiguity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var original = SettingsExport.defaults()
        original.appRules = [
            AppRule(bundleId: "com.example.Duplicate", layout: .float),
            AppRule(bundleId: "com.example.Duplicate", layout: .float)
        ]
        let ambiguous = try idlessDuplicateData(from: SettingsTOMLCodec.encode(original))
        let settingsURL = directory.appendingPathComponent(SettingsFilePersistence.fileName)
        try ambiguous.write(to: settingsURL)
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        var loaded = try XCTUnwrap(persistence.loadOutcome().export)
        loaded.gapSize += 1

        XCTAssertThrowsError(try persistence.saveImmediately(loaded)) { error in
            XCTAssertEqual(
                error as? SettingsTOMLCodecError,
                .cannotSafelyPreserveArrayElement("appRules[0]")
            )
        }
        XCTAssertTrue(persistence.settingsWritesBlocked)
        XCTAssertEqual(try Data(contentsOf: settingsURL), ambiguous)
    }

    private func explicitAppRuleFixture() throws -> (export: SettingsExport, data: Data) {
        var export = SettingsExport.defaults()
        export.appRules = [
            AppRule(id: firstRuleID, bundleId: "com.example.First", layout: .float),
            AppRule(id: secondRuleID, bundleId: "com.example.Second", layout: .tile)
        ]
        var data = try SettingsTOMLCodec.encode(export)
        data = try addingMarker("first", after: #"id = "11111111-2222-3333-4444-555555555555""#, to: data)
        data = try addingMarker("second", after: #"id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE""#, to: data)
        return (export, data)
    }

    private func addingMarker(_ marker: String, after anchor: String, to data: Data) throws -> Data {
        let text = try utf8String(data)
        guard text.contains(anchor) else {
            throw NSError(domain: "SettingsTOMLArrayPreservationTests", code: 1)
        }
        return Data(text.replacingOccurrences(
            of: anchor,
            with: "\(anchor)\nextensionMarker = \"\(marker)\""
        ).utf8)
    }

    private func section(_ name: String, containing needle: String, in data: Data) throws -> String {
        let sections = try utf8String(data)
            .components(separatedBy: "[[\(name)]]")
            .dropFirst()
        return try XCTUnwrap(sections.first { $0.contains(needle) })
    }

    private func idlessDuplicateData(from data: Data) throws -> Data {
        var sections = try utf8String(data).components(separatedBy: "[[appRules]]")
        guard sections.count == 3 else {
            throw NSError(domain: "SettingsTOMLArrayPreservationTests", code: 2)
        }
        for index in 1 ... 2 {
            var lines = sections[index].components(separatedBy: "\n")
            guard let idIndex = lines.firstIndex(where: { $0.hasPrefix("id = ") }) else {
                throw NSError(domain: "SettingsTOMLArrayPreservationTests", code: 3)
            }
            lines.remove(at: idIndex)
            lines.insert("extensionMarker = \"\(index == 1 ? "first" : "second")\"", at: 1)
            sections[index] = lines.joined(separator: "\n")
        }
        return Data(sections.joined(separator: "[[appRules]]").utf8)
    }

    private func monitorExport(displayUUID: String, updated: Bool) -> SettingsExport {
        var export = SettingsExport.defaults()
        export.monitorRoutingSettings = updated ? [
            MonitorRoutingSettings(monitorName: "Name Monitor", gridColumn: 3, gridRow: 1),
            MonitorRoutingSettings(
                monitorName: "Renamed UUID Monitor",
                monitorDisplayUUID: displayUUID,
                gridColumn: 4,
                gridRow: 2
            ),
            MonitorRoutingSettings(
                monitorName: "Renamed Display ID Monitor",
                monitorDisplayId: 200,
                gridColumn: 5,
                gridRow: 3
            )
        ] : [
            MonitorRoutingSettings(
                monitorName: "UUID Monitor",
                monitorDisplayUUID: displayUUID,
                gridColumn: 0,
                gridRow: 0
            ),
            MonitorRoutingSettings(
                monitorName: "Display ID Monitor",
                monitorDisplayId: 200,
                gridColumn: 1,
                gridRow: 0
            ),
            MonitorRoutingSettings(monitorName: "Name Monitor", gridColumn: 2, gridRow: 0)
        ]
        export.monitorOrientationSettings = [MonitorOrientationSettings(
            monitorName: "Portrait",
            orientation: updated ? .horizontal : .vertical
        )]
        return export
    }

    private func monitorData(for export: SettingsExport, displayUUID: String) throws -> Data {
        var data = try SettingsTOMLCodec.encode(export)
        data = try addingMarker("uuid", after: #"monitorName = "UUID Monitor""#, to: data)
        data = try addingMarker("display", after: #"monitorName = "Display ID Monitor""#, to: data)
        data = try addingMarker("name", after: #"monitorName = "Name Monitor""#, to: data)
        data = try addingMarker("orientation", after: #"monitorName = "Portrait""#, to: data)
        return Data(try utf8String(data)
            .replacingOccurrences(of: displayUUID, with: displayUUID.lowercased()).utf8)
    }

    private func utf8String(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
