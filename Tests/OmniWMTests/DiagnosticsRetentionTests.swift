// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class DiagnosticsRetentionTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .sorted()
    }

    private func setModified(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testWipeRemovesAllDiagnosticsFilesAndKeepsOthers() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-trace-1.log", in: dir)
        _ = try write("omniwm-diagnostics-1.log", in: dir)
        _ = try write("omniwm-crash-1.log", in: dir)
        _ = try write("omniwm-performance-1.log", in: dir)
        _ = try write("keep.txt", in: dir)

        DiagnosticsRetention.wipe(directory: dir)

        XCTAssertEqual(names(in: dir), ["keep.txt"])
    }

    func testWipeWithPrefixesKeepsTraces() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-trace-1.log", in: dir)
        _ = try write("omniwm-diagnostics-1.log", in: dir)
        _ = try write("omniwm-crash-1.log", in: dir)

        DiagnosticsRetention.wipe(directory: dir, prefixes: ["omniwm-diagnostics-", "omniwm-crash-"])

        XCTAssertEqual(names(in: dir), ["omniwm-trace-1.log"])
    }

    func testWipeKeepingNewestRetainsMostRecentCaptures() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for index in 0 ..< 8 {
            let url = try write("omniwm-performance-\(index).log", in: dir)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1000 + Double(index))],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }

        DiagnosticsRetention.wipe(
            directory: dir,
            prefixes: ["omniwm-performance-"],
            keepingNewest: 3
        )

        XCTAssertEqual(
            names(in: dir),
            ["omniwm-performance-5.log", "omniwm-performance-6.log", "omniwm-performance-7.log"]
        )
    }

    func testWipeExceptPreservesExcludedURL() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try write("omniwm-diagnostics-old.log", in: dir)
        let keep = try write("omniwm-diagnostics-new.log", in: dir)

        DiagnosticsRetention.wipe(directory: dir, prefixes: ["omniwm-diagnostics-"], except: [keep])

        XCTAssertEqual(names(in: dir), ["omniwm-diagnostics-new.log"])
    }

    func testIssueEvidenceIncludesExactPendingCrashAndNewestCompletedTrace() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let pendingCrash = try write("omniwm-crash-pending.log", in: dir)
        let otherCrash = try write("omniwm-crash-other.log", in: dir)
        let olderTrace = try write("omniwm-trace-1-2.log", in: dir)
        let newerTrace = try write("omniwm-trace-3-4.log", in: dir)
        _ = try write("omniwm-trace-5.partial.log", in: dir)
        _ = try write("omniwm-diagnostics-6.log", in: dir)
        _ = try write(".omniwm-trace-7.tmp", in: dir)
        _ = try write("unrelated.log", in: dir)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("omniwm-trace-8-9.log", isDirectory: true),
            withIntermediateDirectories: false
        )
        try setModified(now.addingTimeInterval(-30), for: pendingCrash)
        try setModified(now, for: otherCrash)
        try setModified(now.addingTimeInterval(-20), for: olderTrace)
        try setModified(now.addingTimeInterval(-10), for: newerTrace)

        let evidence = DiagnosticsFileScanner.issueEvidence(
            in: dir,
            pendingCrashURL: pendingCrash
        )

        XCTAssertEqual(evidence, [.crash(pendingCrash), .trace(newerTrace)])
    }

    func testIssueEvidenceExcludesMissingPendingCrashAndIncompleteTrace() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("omniwm-crash-other.log", in: dir)
        _ = try write("omniwm-trace-1.partial.log", in: dir)
        let missing = dir.appendingPathComponent("omniwm-crash-missing.log", isDirectory: false)

        let evidence = DiagnosticsFileScanner.issueEvidence(
            in: dir,
            pendingCrashURL: missing
        )

        XCTAssertTrue(evidence.isEmpty)
    }

    func testStaleTemporaryCleanupIsNarrowAndAgeBounded() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let staleDiagnostics = try write(".omniwm-diagnostics-old.tmp", in: dir)
        let staleTrace = try write(".omniwm-trace-old.tmp", in: dir)
        let stalePerformance = try write(".omniwm-performance-old.tmp", in: dir)
        let recentDiagnostics = try write(".omniwm-diagnostics-recent.tmp", in: dir)
        let unrelatedHidden = try write(".omniwm-other-old.tmp", in: dir)
        let visibleTemporary = try write("omniwm-trace-old.tmp", in: dir)
        for url in [staleDiagnostics, staleTrace, stalePerformance, unrelatedHidden, visibleTemporary] {
            try setModified(now.addingTimeInterval(-7200), for: url)
        }
        try setModified(now.addingTimeInterval(-120), for: recentDiagnostics)

        DiagnosticsRetention.removeStaleTemporaryFiles(directory: dir, now: now)

        XCTAssertEqual(
            names(in: dir),
            [
                ".omniwm-diagnostics-recent.tmp",
                ".omniwm-other-old.tmp",
                "omniwm-trace-old.tmp"
            ]
        )
    }
}
