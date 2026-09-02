// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DisplayConfigurationObserver: NSObject {
    enum DisplayEvent: Sendable {
        case connected(Monitor)
        case disconnected(Monitor.ID)
        case reconfigured(Monitor)
    }

    typealias EventHandler = @MainActor (DisplayEvent) -> Void

    private var onEvent: EventHandler?
    private var previousMonitors: [Monitor.ID: Monitor] = [:]
    private var debounceTask: Task<Void, Never>?
    private let monitorSampler: @MainActor () -> [Monitor]

    private let debounceInterval: UInt64 = 100_000_000

    init(monitorSampler: @escaping @MainActor () -> [Monitor] = { Monitor.current() }) {
        self.monitorSampler = monitorSampler
        super.init()
        updatePreviousMonitors(monitorSampler())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        onEvent = handler
    }

    @objc private nonisolated func screensDidChange() {
        Task { @MainActor [weak self] in
            self?.debouncedScreenChange()
        }
    }

    private func debouncedScreenChange() {
        debounceTask?.cancel()

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: debounceInterval)
            guard !Task.isCancelled else { return }
            sampleNow()
        }
    }

    func sampleNow() {
        let currentMonitors = monitorSampler()
        guard Monitor.isUsableConfiguration(currentMonitors) else { return }
        let currentById = Dictionary(uniqueKeysWithValues: currentMonitors.map { ($0.id, $0) })
        let currentIds = Set(currentById.keys)
        let previousIds = Set(previousMonitors.keys)

        let disconnectedIds = previousIds.subtracting(currentIds)
        for monitorId in disconnectedIds {
            onEvent?(.disconnected(monitorId))
        }

        let connectedIds = currentIds.subtracting(previousIds)
        for monitorId in connectedIds {
            if let monitor = currentById[monitorId] {
                onEvent?(.connected(monitor))
            }
        }

        let existingIds = currentIds.intersection(previousIds)
        for monitorId in existingIds {
            guard let current = currentById[monitorId],
                  let previous = previousMonitors[monitorId] else { continue }

            if Self.requiresReconfiguration(previous: previous, current: current) {
                onEvent?(.reconfigured(current))
            }
        }

        updatePreviousMonitors(currentMonitors)
    }

    static func requiresReconfiguration(previous: Monitor, current: Monitor) -> Bool {
        previous != current
    }

    private func updatePreviousMonitors(_ monitors: [Monitor]) {
        previousMonitors = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
    }
}
