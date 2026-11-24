// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import ScriptARCCounters

@MainActor
private final class ScriptARCNativeFocusClient: NSObject {
    private(set) var notifications = 0
    static let names: [Notification.Name] = [
        .omniwmFocusChanged, .omniwmFocusedWorkspaceChanged, .omniwmFocusedMonitorChanged
    ]

    init(controller: WMController, names: [Notification.Name] = names) {
        super.init()
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(receive), name: name, object: controller
            )
        }
    }

    @objc private func receive(_: NSNotification) {
        notifications += 1
    }
}

@MainActor
private final class ScriptARCReentrantFocusClient: NSObject {
    var onNext: (@MainActor () -> Void)?

    func observe(_ controller: WMController) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(receive), name: .omniwmFocusChanged, object: controller
        )
    }

    @objc private func receive(_: NSNotification) {
        let callback = onNext
        onNext = nil
        callback?()
    }
}

private struct ScriptARCFocusValues {
    let workspace: WorkspaceDescriptor
    let monitor: Monitor
    let window: WindowToken
}

@MainActor
extension ScriptARCFixture {
    func focusEvents(directory: URL) async throws {
        try await loadMissingScript(in: directory)
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: token)!
        let monitor = manager.monitors.first!
        _ = manager.setActiveWorkspace(workspace, on: monitor.id)
        let values = ScriptARCFocusValues(
            workspace: manager.descriptor(for: workspace)!,
            monitor: monitor,
            window: token
        )
        controller.automationSessionToken = UUID().uuidString
        _ = manager.setManagedReplacementMetadata(
            .init(bundleId: "focus.fixture", workspaceId: workspace, mode: .tiling), for: token
        )
        let client = ScriptARCNativeFocusClient(controller: controller)
        defer { NotificationCenter.default.removeObserver(client) }
        let focusKinds: [ConfigScriptEventKind] = [.workspaceActive, .windowActive, .monitorFocused]
        for report in [false, true] {
            nativeFocus(client)
            if report { script_arc_report("native/focus", "native", 0) }
            for kind in focusKinds {
                focusProducer(kind, values)
                if report { script_arc_report("absent/" + kind.rawValue, "native/focus", 0) }
            }
        }
        for (kind, name) in [
            (ConfigScriptEventKind.workspaceActive, Notification.Name.omniwmFocusedWorkspaceChanged),
            (.windowActive, .omniwmFocusChanged), (.monitorFocused, .omniwmFocusedMonitorChanged)
        ] {
            let listener = ScriptARCNativeFocusClient(controller: controller, names: [name])
            defer { NotificationCenter.default.removeObserver(listener) }
            for report in [false, true] {
                let before = listener.notifications
                nativeFocus(client)
                precondition(listener.notifications == before + 1)
                if report { script_arc_report("native/" + kind.rawValue + "+listener", "native/focus", 0) }
            }
        }
        for kind in focusKinds {
            try await subscribedFocus(kind, values: values, client: client)
        }
        try await modeAndReloadEvents(directory: directory)
    }

    func ownedFocusEvents() async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: token)!
        let monitor = manager.monitors.first!
        let kinds: [ConfigScriptEventKind] = [.workspaceActive, .windowActive, .monitorFocused]
        let renamed = Monitor(
            id: monitor.id, displayId: monitor.displayId, frame: monitor.frame, visibleFrame: monitor.visibleFrame,
            hasNotch: monitor.hasNotch, notchRange: monitor.notchRange, notchHeight: monitor.notchHeight,
            backingScale: monitor.backingScale, name: "display " + UUID().uuidString, displayUUID: monitor.displayUUID,
            isMain: monitor.isMain
        )
        manager.applyMonitorConfigurationChange([renamed])
        let dynamic = manager.createDynamicWorkspace(named: String(Int.max), on: monitor.id)!
        let session = "focus/" + UUID().uuidString
        let bundle = "bundle." + UUID().uuidString
        controller.automationSessionToken = session
        _ = manager.setManagedReplacementMetadata(
            .init(bundleId: bundle, workspaceId: workspace, mode: .tiling), for: token
        )
        let values = ScriptARCFocusValues(
            workspace: dynamic,
            monitor: manager.monitor(byId: monitor.id)!,
            window: token
        )
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: session)
        let queue = try await acceptTitleScript("""
        omniwm.on("workspace.active", function(e) assert(e.name == "\(dynamic.name)") end)
        omniwm.on("window.active", function(e) assert(e.id == "\(id)" and e.bundleId == "\(bundle)") end)
        omniwm.on("monitor.focused", function(e) assert(e.name == "\(renamed.name)") end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            for kind in kinds {
                focusProducer(kind, values)
                try await finishWorker(seed: false)
                if report { script_arc_report("owned/" + kind.rawValue, "event/" + kind.rawValue, 1) }
            }
        }
    }

    private func modeAndReloadEvents(directory: URL) async throws {
        try await loadMissingScript(in: directory)
        for report in [false, true] {
            modeProducer()
            if report { script_arc_report("absent/keybinds.submap", "native", 0) }
            reloadProducer(subscribed: false)
            if report { script_arc_report("absent/config.reloaded", "native", 0) }
        }
        let queue = try await acceptTitleScript("""
        omniwm.on("keybinds.submap", function(e) assert(e.name == "normal") end)
        omniwm.on("config.reloaded", function(e) assert(e.id == nil and e.name == nil) end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            modeProducer()
            try await finishWorker(seed: false)
            if report { script_arc_report("event/keybinds.submap", "absent/keybinds.submap", 1) }
            reloadProducer(subscribed: true)
            try await finishWorker(seed: false)
            if report { script_arc_report("event/config.reloaded", "absent/config.reloaded", 1) }
        }
    }

    @inline(never)
    private func modeProducer() {
        let controller = controller
        script_arc_begin()
        ConfigScriptEventObservers.modeChanged(.normal, controller: controller)
        script_arc_end()
    }

    @inline(never)
    private func reloadProducer(subscribed: Bool) {
        let script = script
        let controller = controller
        script_arc_begin()
        script.publishReloaded(subscribed, controller: controller)
        script_arc_end()
    }

    private func subscribedFocus(
        _ kind: ConfigScriptEventKind, values: ScriptARCFocusValues, client: ScriptARCNativeFocusClient
    ) async throws {
        let queue = try await acceptTitleScript("""
        omniwm.on("\(kind.rawValue)", function(e) assert(e.id and e.missed == nil) end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            focusProducer(kind, values)
            try await finishWorker(seed: false)
            if report { script_arc_report("event/" + kind.rawValue, "absent/" + kind.rawValue, 1) }
            nativeFocus(client)
            try await finishWorker(seed: false)
            if report { script_arc_report(
                "native/" + kind.rawValue + "+script",
                "native/" + kind.rawValue + "+listener",
                1
            ) }
        }
    }

    @inline(never)
    private func nativeFocus(_ client: ScriptARCNativeFocusClient) {
        let dispatcher = FocusNotificationDispatcher(controller: controller)
        let before = client.notifications
        script_arc_begin()
        let changes = dispatcher.notifyFocusChangesIfNeeded()
        script_arc_end()
        precondition(changes.focusChanged && changes.workspaceChanged && changes.monitorChanged)
        precondition(client.notifications == before + ScriptARCNativeFocusClient.names.count)
    }

    @inline(never)
    private func focusProducer(_ kind: ConfigScriptEventKind, _ values: borrowing ScriptARCFocusValues) {
        let controller = controller
        switch kind {
        case .workspaceActive:
            script_arc_begin()
            ConfigScriptEventObservers.workspaceChanged(
                values.workspace.id,
                name: values.workspace.name,
                controller: controller
            )
            script_arc_end()
        case .windowActive:
            script_arc_begin()
            ConfigScriptEventObservers.windowChanged(values.window, controller: controller)
            script_arc_end()
        case .monitorFocused:
            script_arc_begin()
            ConfigScriptEventObservers.monitorChanged(
                values.monitor.id,
                name: values.monitor.name,
                controller: controller
            )
            script_arc_end()
        default: preconditionFailure("Expected a focus event")
        }
    }

    private func checkNativeFocusOrder(token: WindowToken, nativeFirst: Bool) {
        let outer = "outer/" + UUID().uuidString
        let nested = "nested/" + UUID().uuidString
        let resumed = "resumed/" + UUID().uuidString
        let native = ScriptARCReentrantFocusClient()
        let center = NotificationCenter.default
        if nativeFirst { native.observe(controller) }
        var seen: [String?] = []
        let scriptListener = ConfigScriptEventObservers(controller: controller, kinds: [.windowActive]) { _, event in
            seen.append(event.id)
        }
        if !nativeFirst { native.observe(controller) }
        defer {
            scriptListener.stop()
            center.removeObserver(native)
        }
        controller.automationSessionToken = outer
        native.onNext = {
            self.controller.automationSessionToken = nested
            FocusNotificationDispatcher(controller: self.controller).notifyFocusChangesIfNeeded()
            self.controller.automationSessionToken = resumed
        }
        FocusNotificationDispatcher(controller: controller).notifyFocusChangesIfNeeded()
        let expected = nativeFirst ? [nested, resumed] : [outer, nested]
        precondition(seen == expected.map { IPCWindowOpaqueID.encode(token: token, sessionToken: $0) })
    }

    func checkNestedQueueReplacement() async throws {
        let center = NotificationCenter.default
        let receiver = ScriptARCReentrantFocusClient()
        let nestedReceiver = ScriptARCReentrantFocusClient()
        let token = controller.workspaceManager.nativeManagedFocusToken!
        let last = "inner/" + UUID().uuidString
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: last)
        let source = """
        local seen = 0
        omniwm.on("window.active", function(e) seen += 1; assert(e.id == "\(id)") end)
        omniwm.command("Inspect", function() assert(seen == 1) end)
        """
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let replacement = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        let previous = try await acceptTitleScript("omniwm.on('window.active', function() error('retired') end)")
        await previous.waitForAuditPark()
        let worker = previous.worker!
        receiver.observe(controller)
        defer {
            center.removeObserver(receiver)
            center.removeObserver(nestedReceiver)
        }
        var posts: [String] = []
        func post(_ session: String) {
            posts.append(session)
            controller.automationSessionToken = session
            FocusNotificationDispatcher(controller: controller).notifyFocusChangesIfNeeded()
        }
        receiver.onNext = {
            precondition(previous.hasPendingWork)
            nestedReceiver.observe(self.controller)
            nestedReceiver.onNext = {
                precondition(previous.hasPendingWork)
                precondition(self.script.apply(.init(versions: [:], result: .success(replacement)), hyperMask: mask))
                receiver.onNext = { post(last) }
                post("replacement")
            }
            post("same generation")
        }
        post("outer")
        let next = script.callbackQueue!
        precondition(next !== previous && next.hasPendingWork)
        precondition(posts == ["outer", "same generation", "replacement", last])
        precondition(controller.enqueueConfigFunction(script.acceptedCommands.first!.function) == .executed)
        await worker.value
        await next.waitForAuditPark()
        precondition(!previous.hasPendingWork && script.diagnostic == nil)
    }

    func checkFocusEpochAndRetirement() async throws {
        let nativeWindow = controller.workspaceManager.nativeManagedFocusToken ?? token
        let workspace = controller.workspaceManager.workspace(for: nativeWindow)!
        let oldSession = "focus/e\u{301}/" + UUID().uuidString
        let oldBundle = "app." + UUID().uuidString
        let id = IPCWindowOpaqueID.encode(token: nativeWindow, sessionToken: oldSession)
        controller.automationSessionToken = oldSession
        let manager = controller.workspaceManager
        _ = manager.setManagedReplacementMetadata(
            .init(bundleId: oldBundle, workspaceId: workspace, mode: .tiling), for: nativeWindow
        )
        let queue = try await acceptTitleScript("""
        local seen = ""
        omniwm.on("window.active", function(e) seen = e.id .. "|" .. e.bundleId end)
        omniwm.command("Read focus", function() error(seen) end)
        """)
        await queue.waitForAuditPark()
        ConfigScriptEventObservers.windowChanged(nativeWindow, controller: controller)
        controller.automationSessionToken = oldSession.precomposedStringWithCanonicalMapping
        _ = manager.setManagedReplacementMetadata(
            .init(bundleId: "replacement", workspaceId: workspace, mode: .tiling), for: nativeWindow
        )
        let command = script.acceptedCommands.first { $0.name == "Read focus" }!.function
        precondition(controller.enqueueConfigFunction(command) == .executed)
        await queue.waitForAuditPark()
        precondition(script.diagnostic?.contains(id + "|" + oldBundle) == true)
        let previousRegistration = controller.scriptFocusObservers.window!
        let queueWithNewListener = try await acceptTitleScript("""
        omniwm.on("workspace.active", function() error("unexpected retired window delivery") end)
        """)
        await queueWithNewListener.waitForAuditPark()
        previousRegistration.publishNative(.windowActive, .init(), controller: controller)
        precondition(!queueWithNewListener.hasPendingWork && queueWithNewListener.isParked && script
            .diagnostic == nil)
        _ = manager.setManagedFocus(nativeWindow, in: workspace, onMonitor: manager.monitors.first?.id)
        checkNativeFocusOrder(token: nativeWindow, nativeFirst: true)
        checkNativeFocusOrder(token: nativeWindow, nativeFirst: false)
    }
}
