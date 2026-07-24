// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

protocol MonitorSettingsType: Codable, Identifiable, Equatable {
    var monitorName: String { get set }
    var monitorDisplayUUID: String? { get set }
    var monitorDisplayId: CGDirectDisplayID? { get set }
}

enum MonitorSettingsStore {
    static func get<T: MonitorSettingsType>(for monitor: Monitor, in settings: [T]) -> T? {
        if let monitorUUID = monitor.displayUUID {
            return uniqueMatch(in: settings) {
                $0.monitorDisplayUUID == monitorUUID
            }
        }

        return uniqueMatch(in: settings) {
            $0.monitorDisplayUUID == nil &&
                $0.monitorDisplayId == monitor.displayId &&
                Monitor.namesMatch($0.monitorName, monitor.name)
        }
    }

    static func update<T: MonitorSettingsType>(
        _ item: T,
        for monitor: Monitor,
        in settings: inout [T]
    ) {
        var stampedItem = item
        stampedItem.monitorName = monitor.name
        stampedItem.monitorDisplayUUID = monitor.displayUUID
        stampedItem.monitorDisplayId = monitor.displayId

        if let uuid = monitor.displayUUID {
            if replaceMatches(with: stampedItem, in: &settings, where: {
                $0.monitorDisplayUUID == uuid ||
                    ($0.monitorDisplayUUID == nil &&
                        $0.monitorDisplayId == monitor.displayId &&
                        Monitor.namesMatch($0.monitorName, monitor.name))
            }) {
                return
            }
        } else if replaceMatches(with: stampedItem, in: &settings, where: {
            $0.monitorDisplayUUID == nil &&
                $0.monitorDisplayId == monitor.displayId &&
                Monitor.namesMatch($0.monitorName, monitor.name)
        }) {
            return
        }

        settings.append(stampedItem)
    }

    static func remove<T: MonitorSettingsType>(for monitor: Monitor, from settings: inout [T]) {
        if let monitorUUID = monitor.displayUUID {
            settings.removeAll {
                $0.monitorDisplayUUID == monitorUUID ||
                    ($0.monitorDisplayUUID == nil &&
                        $0.monitorDisplayId == monitor.displayId &&
                        Monitor.namesMatch($0.monitorName, monitor.name))
            }
            return
        }

        settings.removeAll {
            $0.monitorDisplayUUID == nil &&
                $0.monitorDisplayId == monitor.displayId &&
                Monitor.namesMatch($0.monitorName, monitor.name)
        }
    }

    private static func uniqueMatch<T>(
        in settings: [T],
        where predicate: (T) -> Bool
    ) -> T? {
        var match: T?
        for setting in settings where predicate(setting) {
            guard match == nil else { return nil }
            match = setting
        }
        return match
    }

    private static func replaceMatches<T>(
        with item: T,
        in settings: inout [T],
        where predicate: (T) -> Bool
    ) -> Bool {
        let matches = settings.indices.filter {
            predicate(settings[$0])
        }
        guard let first = matches.first else { return false }
        settings[first] = item
        for index in matches.dropFirst().reversed() {
            settings.remove(at: index)
        }
        return true
    }
}
