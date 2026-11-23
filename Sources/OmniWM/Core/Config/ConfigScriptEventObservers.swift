// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import OmniWMIPC

@MainActor
final class ConfigScriptEventObservers: NSObject {
    typealias MonitorIdentity = (id: Monitor.ID, name: String)

    private(set) weak var controller: WMController?
    let kinds: Set<ConfigScriptEventKind>
    var windowStates = ConfigScriptObservedWindowStates()
    var workspaceMonitorAssignments: [WorkspaceDescriptor.ID: MonitorIdentity] = [:]
    private let deliver: @MainActor (ConfigScriptEventKind, ConfigScriptEventPayload) -> Void

    init(
        controller: WMController, kinds: Set<ConfigScriptEventKind>,
        deliver: @escaping @MainActor (ConfigScriptEventKind, ConfigScriptEventPayload) -> Void
    ) {
        self.controller = controller
        self.kinds = kinds
        self.deliver = deliver
        super.init()
        let center = NotificationCenter.default
        for kind in kinds {
            switch kind {
            case .workspaceActive:
                center.addObserver(
                    self,
                    selector: #selector(workspaceChanged),
                    name: .omniwmFocusedWorkspaceChanged,
                    object: controller
                )
            case .windowActive:
                center.addObserver(
                    self,
                    selector: #selector(windowChanged),
                    name: .omniwmFocusChanged,
                    object: controller
                )
            case .monitorFocused:
                center.addObserver(
                    self,
                    selector: #selector(monitorChanged),
                    name: .omniwmFocusedMonitorChanged,
                    object: controller
                )
            case .keybindsSubmap:
                controller.scriptModeObserver = self
            default:
                break
            }
        }
        installWindowEdges(on: controller, kinds: kinds)
        installWindowStates(on: controller, kinds: kinds)
        installTopologyEdges(on: controller, kinds: kinds)
    }

    func stop() {
        guard let controller else { return }
        detachWindowEdges(from: controller)
        detachWindowStates(from: controller)
        detachTopologyEdges(from: controller)
        NotificationCenter.default.removeObserver(self, name: nil, object: controller)
        if controller.scriptModeObserver === self { controller.scriptModeObserver = nil }
        self.controller = nil
    }

    func modeChanged(_ kind: KeyboardModeKind) {
        emit(.keybindsSubmap, .init(name: kind.rawValue))
    }

    @objc private func workspaceChanged(_ notification: NSNotification) {
        let info = notification.userInfo
        let id = info?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID
        emit(
            .workspaceActive,
            .init(id: id?.uuidString, name: info?[OmniWMFocusNotificationKey.newWorkspaceName] as? String)
        )
    }

    @objc private func windowChanged(_ notification: NSNotification) {
        guard let token = notification.userInfo?[OmniWMFocusNotificationKey.newWindowToken] as? WindowToken,
              let controller = notification.object as? WMController
        else {
            emit(.windowActive, .init())
            return
        }
        let bundleId = controller.workspaceManager.withEntry(token) {
            $0.target.hostedMetadata?.appId ?? $0.managedReplacementMetadata?.bundleId
        } ?? nil
        emit(.windowActive, .init(
            id: IPCWindowOpaqueID.encode(token: token, sessionToken: controller.automationSessionToken),
            bundleId: bundleId ?? controller.appInfoCache.cachedBundleId(for: token.pid)
        ))
    }

    @objc private func monitorChanged(_ notification: NSNotification) {
        let info = notification.userInfo
        let displayId = info?[OmniWMFocusNotificationKey.newMonitorIndex] as? CGDirectDisplayID
        emit(.monitorFocused, .init(
            id: displayId.map { IPCDisplayRef.identifier(Monitor.ID(displayId: $0)) },
            name: info?[OmniWMFocusNotificationKey.newMonitorName] as? String
        ))
    }

    func emit(_ kind: ConfigScriptEventKind, _ payload: ConfigScriptEventPayload) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.eventPublished)
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        deliver(kind, payload)
    }
}
