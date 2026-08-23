// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class AppInfoCache {
    struct AppInfo {
        let name: String?
        let bundleId: String?
        let icon: NSImage?
        let activationPolicy: NSApplication.ActivationPolicy
    }

    private var cache: [pid_t: AppInfo] = [:]
    private var insertionOrder: [pid_t] = []
    private let maxEntries = 128

    func evict(pid: pid_t) {
        guard cache.removeValue(forKey: pid) != nil else { return }
        insertionOrder.removeAll { $0 == pid }
    }

    func info(for pid: pid_t) -> AppInfo? {
        if let cached = cache[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let info = AppInfo(
            name: app.localizedName,
            bundleId: app.bundleIdentifier,
            icon: app.icon,
            activationPolicy: app.activationPolicy
        )
        if cache.count >= maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[pid] = info
        insertionOrder.append(pid)
        return info
    }

    func name(for pid: pid_t) -> String? {
        info(for: pid)?.name
    }

    func bundleId(for pid: pid_t) -> String? {
        info(for: pid)?.bundleId
    }

    func hasCachedInfo(for pid: pid_t) -> Bool {
        cache[pid] != nil
    }
}
