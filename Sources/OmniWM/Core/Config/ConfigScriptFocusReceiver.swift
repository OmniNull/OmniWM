// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class ConfigScriptFocusReceiver: NSObject {
    enum Value {
        case workspace(UUID?, String?)
        case window(WindowToken?)
        case monitor(Monitor.ID?, String?)
    }

    private struct Publication {
        let controller: WMController
        let value: Value
    }

    private var publication: Publication?

    init(controller: WMController, kinds: Set<ConfigScriptEventKind>) {
        super.init()
        let center = NotificationCenter.default
        if kinds.contains(.workspaceActive) {
            center.addObserver(
                self,
                selector: #selector(workspace),
                name: .omniwmFocusedWorkspaceChanged,
                object: controller
            )
        }
        if kinds.contains(.windowActive) {
            center.addObserver(self, selector: #selector(window), name: .omniwmFocusChanged, object: controller)
        }
        if kinds.contains(.monitorFocused) {
            center.addObserver(
                self,
                selector: #selector(monitor),
                name: .omniwmFocusedMonitorChanged,
                object: controller
            )
        }
    }

    func post(_ value: consuming Value, controller: WMController, name: Notification.Name, info: [AnyHashable: Any]) {
        var previous: Publication? = Publication(controller: controller, value: consume value)
        swap(&publication, &previous)
        defer { swap(&publication, &previous) }
        NotificationCenter.default.post(name: name, object: controller, userInfo: info.isEmpty ? nil : info)
    }

    @objc private func workspace(_: NSNotification) {
        guard let publication = publication.take(), case let .workspace(id, name) = publication.value,
              publication.controller.scriptFocusObservers.workspace?.focusReceiver === self else { return }
        ConfigScriptEventObservers.workspaceChanged(id, name: name, controller: publication.controller)
    }

    @objc private func window(_: NSNotification) {
        guard let publication = publication.take(), case let .window(token) = publication.value,
              publication.controller.scriptFocusObservers.window?.focusReceiver === self else { return }
        ConfigScriptEventObservers.windowChanged(token, controller: publication.controller)
    }

    @objc private func monitor(_: NSNotification) {
        guard let publication = publication.take(), case let .monitor(id, name) = publication.value,
              publication.controller.scriptFocusObservers.monitor?.focusReceiver === self else { return }
        ConfigScriptEventObservers.monitorChanged(id, name: name, controller: publication.controller)
    }
}
