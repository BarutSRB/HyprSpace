// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum OmniWMFocusNotificationKey {
    static let oldWorkspaceId = "oldWorkspaceId"
    static let newWorkspaceId = "newWorkspaceId"
    static let oldWorkspaceName = "oldWorkspaceName"
    static let newWorkspaceName = "newWorkspaceName"
    static let oldMonitorIndex = "oldMonitorIndex"
    static let newMonitorIndex = "newMonitorIndex"
    static let oldMonitorName = "oldMonitorName"
    static let newMonitorName = "newMonitorName"
    static let oldWindowId = "oldWindowId"
    static let newWindowId = "newWindowId"
    static let oldWindowToken = "oldWindowToken"
    static let newWindowToken = "newWindowToken"
    static let oldHandleId = "oldHandleId"
    static let newHandleId = "newHandleId"
}

extension Notification.Name {
    static let omniwmFocusChanged = Notification.Name("OmniWM.FocusChanged")
    static let omniwmFocusedWorkspaceChanged = Notification.Name("OmniWM.FocusedWorkspaceChanged")
    static let omniwmFocusedMonitorChanged = Notification.Name("OmniWM.FocusedMonitorChanged")
}

@MainActor
final class FocusNotificationDispatcher {
    struct ChangeSet: Equatable {
        let focusChanged: Bool
        let workspaceChanged: Bool
        let monitorChanged: Bool
    }

    weak var controller: WMController?

    private var lastNotifiedWorkspaceId: WorkspaceDescriptor.ID?
    private var lastNotifiedMonitorId: Monitor.ID?
    private var lastNotifiedFocusedToken: WindowToken?
    private var lastNotifiedFocusedWindowId: Int?

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func notifyFocusChangesIfNeeded() -> ChangeSet {
        guard let controller else {
            return ChangeSet(focusChanged: false, workspaceChanged: false, monitorChanged: false)
        }
        var focusChanged = false

        let projection = controller.interactionWorkspaceProjection()
        let currentMonitorId = projection.monitor?.id
        let currentWorkspaceId = projection.workspace?.id

        let currentToken = controller.workspaceManager.nativeManagedFocusToken
        let currentWindowId = currentToken
            .flatMap { controller.workspaceManager.entry(for: $0)?.windowId }

        if currentToken != lastNotifiedFocusedToken || currentWindowId != lastNotifiedFocusedWindowId {
            var info: [AnyHashable: Any] = [:]
            if let oldToken = lastNotifiedFocusedToken {
                info[OmniWMFocusNotificationKey.oldWindowToken] = oldToken
                info[OmniWMFocusNotificationKey.oldHandleId] = oldToken
            }
            if let newToken = currentToken {
                info[OmniWMFocusNotificationKey.newWindowToken] = newToken
                info[OmniWMFocusNotificationKey.newHandleId] = newToken
            }
            if let oldWindowId = lastNotifiedFocusedWindowId {
                info[OmniWMFocusNotificationKey.oldWindowId] = oldWindowId
            }
            if let newWindowId = currentWindowId { info[OmniWMFocusNotificationKey.newWindowId] = newWindowId }

            NotificationCenter.default.post(
                name: .omniwmFocusChanged,
                object: controller,
                userInfo: info.isEmpty ? nil : info
            )
            lastNotifiedFocusedToken = currentToken
            lastNotifiedFocusedWindowId = currentWindowId
            focusChanged = true
        }

        var workspaceInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceId] = oldId
            if let name = controller.workspaceManager.descriptor(for: oldId)?
                .name { workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceName] = name }
        }
        if let newId = currentWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceId] = newId
            if let name = controller.workspaceManager.descriptor(for: newId)?
                .name { workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceName] = name }
        }
        let workspaceChanged = postNotificationIfChanged(
            name: .omniwmFocusedWorkspaceChanged,
            current: currentWorkspaceId,
            last: &lastNotifiedWorkspaceId,
            info: workspaceInfo,
            sender: controller
        )

        var monitorInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.oldMonitorIndex] = oldId.displayId
            if let name = controller.workspaceManager.monitor(byId: oldId)?
                .name { monitorInfo[OmniWMFocusNotificationKey.oldMonitorName] = name }
        }
        if let newId = currentMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.newMonitorIndex] = newId.displayId
            if let name = controller.workspaceManager.monitor(byId: newId)?
                .name { monitorInfo[OmniWMFocusNotificationKey.newMonitorName] = name }
        }
        let monitorChanged = postNotificationIfChanged(
            name: .omniwmFocusedMonitorChanged,
            current: currentMonitorId,
            last: &lastNotifiedMonitorId,
            info: monitorInfo,
            sender: controller
        )

        return ChangeSet(
            focusChanged: focusChanged,
            workspaceChanged: workspaceChanged,
            monitorChanged: monitorChanged
        )
    }

    private func postNotificationIfChanged<T: Equatable>(
        name: Notification.Name,
        current: T?,
        last: inout T?,
        info: [AnyHashable: Any],
        sender: AnyObject
    ) -> Bool {
        guard current != last else { return false }
        NotificationCenter.default.post(
            name: name,
            object: sender,
            userInfo: info.isEmpty ? nil : info
        )
        last = current
        return true
    }
}
