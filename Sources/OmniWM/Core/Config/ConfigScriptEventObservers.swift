// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct ConfigScriptFocusObservers {
    var workspace: ConfigScriptEventObservers?
    var window: ConfigScriptEventObservers?
    var monitor: ConfigScriptEventObservers?

    mutating func remove(_ observer: ConfigScriptEventObservers) {
        if workspace === observer { workspace = nil }
        if window === observer { window = nil }
        if monitor === observer { monitor = nil }
    }
}

@MainActor
final class ConfigScriptEventObservers {
    private(set) weak var controller: WMController?
    let kinds: Set<ConfigScriptEventKind>
    let nativeInput: ConfigScriptEventInput
    let focusReceiver: ConfigScriptFocusReceiver?
    var windowStates = ConfigScriptObservedWindowStates()
    var catalogMonitorContext: WorkspaceManager.MonitorResolutionContext?
    private var queue: ConfigScriptCallbackQueue?
    private let deliver: (@MainActor (ConfigScriptEventKind, ConfigScriptEventPayload) -> Void)?

    var hasSynchronousDelivery: Bool {
        deliver != nil
    }

    init(
        controller: WMController, kinds: Set<ConfigScriptEventKind>,
        queue: ConfigScriptCallbackQueue? = nil,
        deliver: (@MainActor (ConfigScriptEventKind, ConfigScriptEventPayload) -> Void)? = nil
    ) {
        self.controller = controller
        self.kinds = kinds
        nativeInput = controller.registerConfigEventInput()
        self.queue = queue
        self.deliver = deliver
        if kinds.contains(.workspaceActive) || kinds.contains(.windowActive) || kinds.contains(.monitorFocused) {
            focusReceiver = ConfigScriptFocusReceiver(controller: controller, kinds: kinds)
        } else {
            focusReceiver = nil
        }
        for kind in kinds {
            switch kind {
            case .workspaceActive: controller.scriptFocusObservers.workspace = self
            case .windowActive: controller.scriptFocusObservers.window = self
            case .monitorFocused: controller.scriptFocusObservers.monitor = self
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
        queue = nil
        guard let controller else { return }
        detachWindowEdges(from: controller)
        detachWindowStates(from: controller)
        detachTopologyEdges(from: controller)
        if let focusReceiver { NotificationCenter.default.removeObserver(focusReceiver) }
        controller.scriptFocusObservers.remove(self)
        if controller.scriptModeObserver === self { controller.scriptModeObserver = nil }
        self.controller = nil
    }

    static func modeChanged(_ kind: KeyboardModeKind, controller: WMController) {
        publishRegistered(.keybindsSubmap, in: &controller.scriptModeObserver, controller: controller) {
            .init(name: kind == .named ? controller.keyboardModeName ?? kind.rawValue : kind.rawValue)
        }?()
    }

    static func workspaceChanged(_ id: WorkspaceDescriptor.ID?, name: String?, controller: WMController) {
        publishRegistered(.workspaceActive, in: &controller.scriptFocusObservers.workspace, controller: controller) {
            let value: ConfigScriptNativeEvent.ID = if let id { .workspace(id) } else { .none }
            return .init(id: value, name: name)
        }?()
    }

    static func windowChanged(_ token: WindowToken?, controller: WMController) {
        publishRegistered(.windowActive, in: &controller.scriptFocusObservers.window, controller: controller) {
            guard let token else { return .init() }
            var identity = controller.workspaceManager.configWindow(for: token)
            var bundle = identity?.takeBundle()
            if bundle == nil { bundle = controller.appInfoCache.cachedBundleId(for: token.pid) }
            return .init(
                id: .window(token, controller.scriptSession.identity, controller.scriptSession.epoch),
                bundleId: consume bundle
            )
        }?()
    }

    static func monitorChanged(_ id: Monitor.ID?, name: String?, controller: WMController) {
        publishRegistered(.monitorFocused, in: &controller.scriptFocusObservers.monitor, controller: controller) {
            let value: ConfigScriptNativeEvent.ID = if let id { .monitor(id) } else { .none }
            return .init(id: value, name: name)
        }?()
    }

    private static func publishRegistered(
        _ kind: ConfigScriptEventKind, in registration: inout ConfigScriptEventObservers?, controller: WMController,
        event: @MainActor () -> ConfigScriptNativeEvent
    ) -> (@MainActor () -> Void)? {
        guard let registration else { return nil }
        let value = event()
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.eventPublished)
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        if let deliver = registration.deliver {
            let payload = value.payload()
            return { deliver(kind, payload) }
        }
        ConfigScriptCallbackQueue.publish(kind, consume value, in: &registration.queue, controller: controller)
        return nil
    }

    func publishNative(_ kind: ConfigScriptEventKind, _ event: consuming ConfigScriptNativeEvent) {
        guard let controller else { return }
        publishNative(kind, consume event, controller: controller)
    }

    func publishNative(
        _ kind: ConfigScriptEventKind,
        _ event: consuming ConfigScriptNativeEvent,
        controller: WMController
    ) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.eventPublished)
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        if let deliver {
            deliver(kind, event.payload())
        } else {
            ConfigScriptCallbackQueue.publish(kind, consume event, in: &queue, controller: controller)
        }
    }

    func publishNative(
        _ kind: ConfigScriptEventKind, _ event: consuming ConfigScriptNativeEvent, in manager: WorkspaceManager
    ) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.eventPublished)
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        if let deliver {
            deliver(kind, event.payload())
        } else {
            ConfigScriptCallbackQueue.publish(
                kind, consume event, in: &queue, manager: manager, observer: self
            )
        }
    }

    func hasPendingMinimize(_ token: WindowToken, epoch: UInt64) -> Bool {
        queue?.hasPendingMinimize(token, epoch: epoch) == true
    }

    func recordMissedMinimizations(_ count: Int) {
        queue?.recordMissedMinimizations(count)
    }

    func recordMissedEdges(_ count: Int, kind: ConfigScriptEventKind) {
        queue?.recordMissedEdges(count, kind: kind)
    }

    func publishTitle(_ title: consuming ConfigScriptWindowTitle, controller: WMController) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.eventPublished)
            ConfigScriptLatencyTrace.eventPayloadBuilt()
        #endif
        if let deliver {
            let id = ConfigScriptWindowID.string(title.token, session: title.session)
            deliver(.windowTitle, title.payload(id: id))
        } else {
            ConfigScriptCallbackQueue.publishTitle(consume title, in: &queue, controller: controller)
        }
    }
}
