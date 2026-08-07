// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation
@testable import OmniWM

struct AeroSpaceAxDump: Equatable {
    var name: String
    var aeroSpaceLabel: String
    var observation: WindowClassificationObservation
}

struct AeroSpaceAxDumpCoverage: Equatable {
    var files: Int
    var skippedNonWindowRole: Int
    var skippedMissingWindowLevel: Int
    var loaded: Int
}

enum AeroSpaceAxDumpLoader {
    private static let syntheticPid: Int32 = 90000
    private static let syntheticWindowIdBase = 900_000

    static func dumpURLs() throws -> [URL] {
        guard let resourceURL = Bundle.module.resourceURL else { return [] }
        let directory = resourceURL.appendingPathComponent("Fixtures/AeroSpaceAxDumps", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "json5" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func load() throws -> (dumps: [AeroSpaceAxDump], coverage: AeroSpaceAxDumpCoverage) {
        let urls = try dumpURLs()
        var dumps: [AeroSpaceAxDump] = []
        var skippedNonWindowRole = 0
        var skippedMissingWindowLevel = 0

        for (index, url) in urls.enumerated() {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url),
                options: [.json5Allowed]
            )
            guard let dump = object as? [String: Any] else {
                throw AeroSpaceAxDumpError.malformed(url.lastPathComponent)
            }
            guard string(dump, "AXRole") == (kAXWindowRole as String) else {
                skippedNonWindowRole += 1
                continue
            }
            guard let level = windowLevel(dump) else {
                skippedMissingWindowLevel += 1
                continue
            }
            dumps.append(
                AeroSpaceAxDump(
                    name: url.deletingPathExtension().lastPathComponent,
                    aeroSpaceLabel: string(dump, "Aero.AxUiElementWindowType") ?? "",
                    observation: observation(dump, level: level, index: index)
                )
            )
        }

        return (
            dumps,
            AeroSpaceAxDumpCoverage(
                files: urls.count,
                skippedNonWindowRole: skippedNonWindowRole,
                skippedMissingWindowLevel: skippedMissingWindowLevel,
                loaded: dumps.count
            )
        )
    }

    private static func observation(
        _ dump: [String: Any],
        level: Int32,
        index: Int
    ) -> WindowClassificationObservation {
        let windowId = syntheticWindowIdBase + index
        let bundleId = string(dump, "Aero.App.appBundleId")
        let facts = AXWindowFacts(
            role: string(dump, "AXRole"),
            subrole: string(dump, "AXSubrole"),
            title: string(dump, "AXTitle"),
            hasCloseButton: hasElement(dump, "AXCloseButton"),
            hasFullscreenButton: hasElement(dump, "AXFullScreenButton"),
            fullscreenButtonEnabled: isEnabled(dump, "AXFullScreenButton"),
            hasZoomButton: hasElement(dump, "AXZoomButton"),
            hasMinimizeButton: hasElement(dump, "AXMinimizeButton"),
            appPolicy: activationPolicy(string(dump, "Aero.App.nsApp.activationPolicy")),
            bundleId: bundleId,
            attributeFetchSucceeded: true
        )
        let windowServer = WindowServerInfo(
            id: UInt32(windowId),
            pid: syntheticPid,
            level: level,
            frame: .zero,
            tags: 0,
            attributes: 0,
            parentId: 0,
            title: nil
        )
        return WindowClassificationObservation(
            tokenPid: syntheticPid,
            tokenWindowId: windowId,
            appName: nil,
            bundleId: bundleId,
            workspaceName: nil,
            rulesRevision: 0,
            input: WindowClassificationInput(
                appName: nil,
                ax: AXWindowFactsDTO(from: facts),
                sizeConstraints: nil,
                windowServer: WindowServerInfoDTO(from: windowServer),
                appFullscreen: false,
                manualOverride: nil
            ),
            observedDecision: WindowClassificationDecisionDTO(from: unobservedDecision)
        )
    }

    private static let unobservedDecision = WindowDecision(
        disposition: .undecided,
        source: .heuristic,
        layoutDecisionKind: .fallbackLayout,
        workspaceName: nil,
        ruleEffects: .none,
        admissionHints: .none,
        heuristicReasons: [],
        deferredReason: nil
    )

    private static func activationPolicy(_ value: String?) -> NSApplication.ActivationPolicy? {
        switch value {
        case "accessory": .accessory
        case "prohibited": .prohibited
        case "regular": .regular
        default: nil
        }
    }

    private static func windowLevel(_ dump: [String: Any]) -> Int32? {
        switch dump["Aero.windowLevel"] {
        case let value as String:
            switch value {
            case "normalWindow": 0
            case "alwaysOnTopWindow": 3
            default: nil
            }
        case let value as NSNumber: Int32(truncating: value)
        default: nil
        }
    }

    private static func string(_ dump: [String: Any], _ key: String) -> String? {
        dump[key] as? String
    }

    private static func hasElement(_ dump: [String: Any], _ key: String) -> Bool {
        dump[key] is [String: Any]
    }

    private static func isEnabled(_ dump: [String: Any], _ key: String) -> Bool? {
        guard let element = dump[key] as? [String: Any] else { return nil }
        guard let enabled = element["AXEnabled"] as? NSNumber else { return nil }
        return enabled.boolValue
    }
}

enum AeroSpaceAxDumpError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case let .malformed(name): "AeroSpace dump \(name) is not a JSON object"
        }
    }
}
