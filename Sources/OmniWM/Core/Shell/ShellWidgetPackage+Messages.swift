// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func receive(_ message: ShellWidgetMessage) async {
        if case let .capture(request) = message {
            await receiveCapture(request)
            return
        }
        if captureContext != nil {
            switch message {
            case .services: services.captureWakeConsumed()
            case .providers: providerInbox.captureWakeConsumed()
            case .resources: resourceInbox.captureWakeConsumed()
            default: break
            }
        }
        guard !closing, let script else {
            acknowledgeDropped(message)
            return
        }
        recordWake(message)
        let changed = refreshData(for: message)
        await process(message, in: script, changed: changed)
        guard !closing, self.script === script else { return }
        await retireStringsIfNeeded(script)
        flushConfigurationRequests()
    }

    private func process(_ message: ShellWidgetMessage, in script: ShellScript, changed: UInt64) async {
        switch message {
        case let .update(next):
            await deliverChanges(adoptData(next), in: script)
        case .dataChanged:
            await deliverChanges(changed, in: script)
        case let .interval(next):
            interval = next
        case let .bars(bars):
            await sync(bars, in: script)
        case let .window(context):
            await syncWindow(context, in: script)
        case let .removeWindow(id):
            removeWindow(id, in: script)
        case let .catalog(enabled, catalog, schema):
            await updateConfigurationCatalog(enabled: enabled, catalog: catalog, schema: schema, in: script)
        case let .components(source):
            await updateComponents(source, in: script)
        case let .settings(next):
            await updateSettings(next, in: script)
        case let .invoke(key, view, action, clicked, event):
            await ShellFrameTrace.$context.withValue(event.trace) {
                await invoke(action, in: view, of: key, clicked: clicked, event: event)
            }
        case let .log(line):
            log(1) { _ in line }
        case let .gesture(pending):
            await invokeGesture(pending)
        case let .trigger(name, value):
            await trigger(name, value: value, in: script)
        case let .popout(key, open, trace):
            await ShellFrameTrace.$context.withValue(trace) {
                await setPopout(.bar(key), open: open, in: script)
            }
        case .services:
            await deliverServices(in: script)
        case .providers:
            await deliverProviders(in: script)
        case .resources:
            await deliverResources(in: script)
        case let .nativeInput(input):
            await deliverNativeInput(input, in: script)
        case .permissions:
            revalidatePermissions()
        case .capture: break
        }
    }

    private func invokeGesture(_ pending: ShellGestureBox.Pending) async {
        guard let gesture = pending.take() else { return }
        await ShellFrameTrace.$context.withValue(gesture.event.trace) {
            await invoke(
                gesture.action, in: gesture.view, of: gesture.instance,
                clicked: gesture.sequence, event: gesture.event
            )
        }
    }

    private func updateSettings(_ next: [UInt8], in script: ShellScript) async {
        guard next != settings else { return }
        settings = next
        for (key, instance) in script.instances {
            applySettings(instance)
            await renderVisible(key, instance, changed: ShellDataKey.settings.bit)
        }
    }

    private func acknowledgeDropped(_ message: ShellWidgetMessage) {
        if case let .nativeInput(input) = message { input.completion.resume(returning: false)
            return
        }
        let invocation: ShellGestureBox.Gesture
        switch message {
        case let .invoke(key, view, action, sequence, event):
            invocation = ShellGestureBox.Gesture(
                instance: key,
                view: view,
                action: action,
                sequence: sequence,
                event: event
            )
        case let .gesture(pending):
            guard let gesture = pending.take() else { return }
            invocation = gesture
        default: return
        }
        guard let id = invocation.event.invocationID else { return }
        outbox.beginInvoke(name: name, generation: generation)
        outbox.finishInvoke(
            name: name,
            generation: generation,
            key: ShellTreeKey(instance: invocation.instance, view: invocation.view),
            invocationID: id,
            failed: true
        )
    }

    private func recordWake(_ message: ShellWidgetMessage) {
        guard var trace = ShellFrameTrace.shared.makeContext() else { return }
        trace.widget = RuntimeTraceLimits.boundedString(name, maxBytes: 128)
        trace.generation = generation
        let reason: String = switch message {
        case .update,
             .dataChanged: "update"
        case .settings: "settings"
        case .components: "components"
        case .catalog: "catalog"
        case .bars: "bars"
        case .window: "window"
        case .removeWindow: "remove_window"
        case .invoke: "invoke"
        case .gesture: "gesture"
        case .popout: "popout"
        case .interval: "interval"
        case .trigger: "trigger"
        case .log: "log"
        case .services: "services"
        case .providers: "providers"
        case .resources: "resources"
        case .nativeInput: "native_input"
        case .capture: "capture"
        case .permissions: "permissions"
        }
        ShellFrameTrace.shared.record(.init(event: .packageWake, context: trace, count: 1, detail: reason))
    }

    func refreshData(for message: ShellWidgetMessage) -> UInt64 {
        guard let snapshot = latestData?.read(after: dataRevision) else { return 0 }
        dataRevision = snapshot.revision
        if case .update = message { return 0 }
        return adoptData(snapshot.data)
    }

    private func adoptData(_ next: ShellWidgetData) -> UInt64 {
        let changed = next.changedKeys(from: current)
        current = next
        for state in states.values {
            state.pendingData |= changed
            for view in ShellWidgetView.allCases { state.invalidations[view.rawValue] |= changed }
        }
        return changed
    }

    private func deliverChanges(_ changed: UInt64, in script: ShellScript) async {
        let paced = pacedTimedRender()
        for (key, instance) in script.instances {
            await renderVisible(key, instance, changed: changed, allowed: paced ? .max : ~ShellDataFeed.timedKeys)
        }
    }

    private func trigger(
        _ name: String,
        value: String?,
        in script: ShellScript,
        source: String? = nil,
        only key: ShellInstanceKey? = nil
    ) async {
        var writer = ShellValueWriter()
        writer.map(source == nil ? 2 : 3)
        writer.key("name")
        writer.string(name)
        writer.key("value")
        value.map { writer.string($0) } ?? writer.null()
        if let source {
            writer.key("source")
            writer.string(source)
        }
        let event = writer.bytes
        for (target, instance) in script.instances where key == nil || key == target {
            guard !closing, self.script === script else { return }
            let key = target
            hydrate(key, instance)
            let trace = traceContext(key, view: "trigger")
            ShellFrameTrace.shared.record(.handlerStart, context: trace)
            let status = event.withUnsafeBufferPointer { bytes in
                omni_instance_trigger(
                    instance,
                    bytes.baseAddress,
                    bytes.count,
                    Self.handlerBudget,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
            ShellFrameTrace.shared.record(.handlerEnd, context: trace)
            if status != OMNI_OK {
                fail(status)
            }
            flushMessages(key, instance)
            await ShellFrameTrace.$context.withValue(trace) {
                await renderVisible(key, instance)
            }
        }
    }

    private func setPopout(_ key: ShellInstanceKey, open: Bool, in script: ShellScript) async {
        guard let instance = script.instances[key] else { return }
        if open {
            popout = key
            await renderVisible(key, instance)
        } else {
            if popout == key {
                popout = nil
            }
            omni_instance_discard_output(instance, OMNI_VIEW_POPOUT)
        }
    }

    private func invoke(
        _ action: UInt32,
        in view: ShellWidgetView,
        of key: ShellInstanceKey,
        clicked: Int,
        event: ShellEvent
    ) async {
        var failed = true
        if event.invocationID != nil { outbox.beginInvoke(name: name, generation: generation) }
        defer {
            if let id = event.invocationID {
                outbox.finishInvoke(
                    name: name,
                    generation: generation,
                    key: ShellTreeKey(instance: key, view: view),
                    invocationID: id,
                    failed: failed
                )
            }
        }
        guard let script, let instance = script.instances[key],
              let published = states[key]?.sequences[view.rawValue],
              clicked <= published
        else {
            return
        }
        hydrate(key, instance)
        installProviderStateBeforeAction(action, view: view, instance: instance, script: script)
        let sourceID = event.sourceID
        let bytes = event.bytes
        let trace = traceContext(key, view: view.traceLabel, continuing: ShellFrameTrace.current)
        ShellFrameTrace.shared.record(.handlerStart, context: trace)
        let status = invokeHandler(action, view: view, instance: instance, sourceID: sourceID, bytes: bytes)
        ShellFrameTrace.shared.record(.handlerEnd, context: trace)
        failed = status != OMNI_OK
        if status == OMNI_ERR_COMPONENT {
            log(1) { _ in lastError() }
        } else if status != OMNI_OK, status != OMNI_ERR_STALE_ACTION {
            fail(status)
        }
        flushMessages(key, instance)
        await ShellFrameTrace.$context.withValue(trace) {
            await renderVisible(key, instance)
            if hasComponents {
                for (other, display) in script.instances where other != key {
                    await renderVisible(other, display)
                }
            }
        }
    }

    private func invokeHandler(
        _ action: UInt32,
        view: ShellWidgetView,
        instance: OpaquePointer,
        sourceID: UInt64,
        bytes: [UInt8]
    ) -> omni_status {
        bytes.withUnsafeBufferPointer { bytes in
            omni_instance_invoke(
                instance,
                view.wire,
                action,
                sourceID,
                bytes.baseAddress,
                bytes.count,
                Self.handlerBudget,
                &errorBuffer,
                errorBuffer.count
            )
        }
    }

    private func sync(_ bars: [ShellBarKey: ShellBarData], in script: ShellScript) async {
        for key in Array(script.instances.keys) {
            guard case let .bar(barKey) = key, bars[barKey] == nil else { continue }
            if let instance = script.instances.removeValue(forKey: key) {
                omni_instance_destroy(instance)
            }
            states.removeValue(forKey: key)
            if popout == key {
                popout = nil
            }
        }
        publishBackgroundDemand()
        for (barKey, bar) in bars {
            let key = ShellInstanceKey.bar(barKey)
            guard states[key]?.bar != bar else { continue }
            guard !closing, self.script === script else { return }
            let created = script.instances[key] == nil
            let previous = states[key]?.bar
            let revealed = previous?.surface?.visible == false && bar.surface?.visible != false
            guard let instance = script.instances[key] ?? create(key, in: script) else { continue }
            setValue(instance, .bar) { bar.write(to: &$0) }
            setValue(instance, .island) { writer in
                if let surface = bar.surface { surface.write(to: &writer) } else { writer.null() }
            }
            states[key]?.bar = bar
            if declaration.hasTrigger, created || bar.displayChanged(from: previous) {
                await trigger(
                    created ? "reloaded" : "displayChanged",
                    value: nil,
                    in: script,
                    source: "host",
                    only: key
                )
                continue
            }
            await renderVisible(
                key,
                instance,
                changed: revealed ? nil : ShellDataKey.bar.bit | ShellDataKey.island.bit
            )
        }
    }

    private func removeWindow(_ id: UUID, in script: ShellScript) {
        let key = ShellInstanceKey.window(id)
        guard let instance = script.instances.removeValue(forKey: key) else { return }
        omni_instance_destroy(instance)
        states.removeValue(forKey: key)
        drainServices(in: script)
        publishBackgroundDemand()
    }

    private func syncWindow(_ context: ShellWindowContext, in script: ShellScript) async {
        guard context.width.isFinite, context.height.isFinite,
              context.width > 0, context.height > 0, ShellComponentCatalog.validName(context.viewName) else { return }
        let key = ShellInstanceKey.window(context.id)
        guard states[key]?.window != context else { return }
        let created = script.instances[key] == nil
        let previous = states[key]?.window
        guard let instance = script.instances[key] ?? create(key, in: script) else { return }
        if created || previous?.width != context.width || previous?.height != context.height
            || previous?.viewName != context.viewName
        {
            let status = omni_instance_set_window_offer(
                instance, context.viewName, context.viewName.utf8.count, context.width, context.height
            )
            guard status == OMNI_OK else { fail(status)
                return
            }
        }
        states[key]?.window = context
        await renderVisible(
            key,
            instance,
            changed: created || previous?.visible == false && context.visible
                ? .max : nil
        )
    }

    private func create(_ key: ShellInstanceKey, in script: ShellScript) -> OpaquePointer? {
        guard let instance = omni_instance_create(script.vm) else {
            outbox.fail(
                name: name,
                generation: generation,
                failure: ShellScriptFailure(kind: .internalError, message: "the widget instance could not be created")
            )
            return nil
        }
        script.instances[key] = instance
        states[key] = InstanceState()
        applySettings(instance)
        guard applyConfigurationCatalog(instance) else {
            script.instances.removeValue(forKey: key)
            states.removeValue(forKey: key)
            omni_instance_destroy(instance)
            return nil
        }
        return instance
    }
}
