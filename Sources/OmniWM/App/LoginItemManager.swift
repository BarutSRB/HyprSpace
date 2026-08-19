// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import Observation
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@MainActor
@Observable
final class LoginItemManager {
    private let service: any LoginItemService

    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var lastErrorDescription: String?

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (isEnabled || requiresApproval) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
        refresh()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
