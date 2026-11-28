// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        let projection = controller.interactionWorkspaceProjection()
        let currentMonitorId = projection.monitor?.id
        let currentWorkspaceId = projection.workspace?.id

        let focusChanged = notifyWindowFocusIfNeeded(controller: controller)
        let workspaceChanged = notifyWorkspaceIfNeeded(currentWorkspaceId, controller: controller)
        let monitorChanged = notifyMonitorIfNeeded(currentMonitorId, controller: controller)

        return ChangeSet(
            focusChanged: focusChanged,
            workspaceChanged: workspaceChanged,
            monitorChanged: monitorChanged
        )
    }

    private func notifyWindowFocusIfNeeded(controller: WMController) -> Bool {
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

            post(
                .omniwmFocusChanged,
                controller: controller,
                info: info,
                receiver: controller.scriptFocusObservers.window?.focusReceiver,
                value: .window(currentToken)
            )
            lastNotifiedFocusedToken = currentToken
            lastNotifiedFocusedWindowId = currentWindowId
            return true
        }
        return false
    }

    private func notifyWorkspaceIfNeeded(
        _ currentWorkspaceId: WorkspaceDescriptor.ID?,
        controller: WMController
    ) -> Bool {
        guard currentWorkspaceId != lastNotifiedWorkspaceId else { return false }
        var workspaceInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceId] = oldId
            if let name = controller.workspaceManager.descriptor(for: oldId)?
                .name { workspaceInfo[OmniWMFocusNotificationKey.oldWorkspaceName] = name }
        }
        let newName = currentWorkspaceId.flatMap { controller.workspaceManager.descriptor(for: $0)?.name }
        if let newId = currentWorkspaceId {
            workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceId] = newId
            if let newName { workspaceInfo[OmniWMFocusNotificationKey.newWorkspaceName] = newName }
        }
        post(
            .omniwmFocusedWorkspaceChanged,
            controller: controller,
            info: workspaceInfo,
            receiver: controller.scriptFocusObservers.workspace?.focusReceiver,
            value: .workspace(currentWorkspaceId, newName)
        )
        lastNotifiedWorkspaceId = currentWorkspaceId
        return true
    }

    private func notifyMonitorIfNeeded(_ currentMonitorId: Monitor.ID?, controller: WMController) -> Bool {
        guard currentMonitorId != lastNotifiedMonitorId else { return false }
        var monitorInfo: [AnyHashable: Any] = [:]
        if let oldId = lastNotifiedMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.oldMonitorIndex] = oldId.displayId
            if let name = controller.workspaceManager.monitor(byId: oldId)?
                .name { monitorInfo[OmniWMFocusNotificationKey.oldMonitorName] = name }
        }
        let newName = currentMonitorId.flatMap { controller.workspaceManager.monitor(byId: $0)?.name }
        if let newId = currentMonitorId {
            monitorInfo[OmniWMFocusNotificationKey.newMonitorIndex] = newId.displayId
            if let newName { monitorInfo[OmniWMFocusNotificationKey.newMonitorName] = newName }
        }
        post(
            .omniwmFocusedMonitorChanged,
            controller: controller,
            info: monitorInfo,
            receiver: controller.scriptFocusObservers.monitor?.focusReceiver,
            value: .monitor(
                currentMonitorId,
                newName
            )
        )
        lastNotifiedMonitorId = currentMonitorId
        return true
    }

    private func post(
        _ name: Notification.Name, controller: WMController, info: [AnyHashable: Any],
        receiver: ConfigScriptFocusReceiver?, value: @autoclosure () -> ConfigScriptFocusReceiver.Value
    ) {
        if let receiver {
            receiver.post(value(), controller: controller, name: name, info: info)
        } else {
            NotificationCenter.default.post(name: name, object: controller, userInfo: info.isEmpty ? nil : info)
        }
    }
}
