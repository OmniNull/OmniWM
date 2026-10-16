// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import QuartzCore

extension ShellWidgetPackage {
    func traceContext(
        _ key: ShellBarKey,
        view: String,
        continuing context: ShellFrameTraceContext? = nil
    ) -> ShellFrameTraceContext? {
        guard var trace = context ?? ShellFrameTrace.shared.makeContext(parent: ShellFrameTrace.current) else {
            return nil
        }
        trace.widget = RuntimeTraceLimits.boundedString(name, maxBytes: 128)
        trace.generation = generation
        trace.display = key.monitor.displayId
        trace.placement = key.placement == .island ? "island" : "bar"
        trace.slice = key.island.rawValue
        trace.view = view
        return trace
    }

    func pacedTimedRender() -> Bool {
        guard let interval else { return true }
        let now = ContinuousClock.now
        if let last = lastTimedRender, now - last < .seconds(interval) {
            return false
        }
        lastTimedRender = now
        return true
    }

    func retireStringsIfNeeded(_ script: ShellScript) async {
        guard omni_vm_string_count(script.vm) > Self.stringLimit || omni_vm_string_bytes(script.vm) > Self
            .stringByteLimit
        else {
            return
        }
        omni_vm_reset_strings(script.vm)
        for (key, instance) in script.instances {
            await renderVisible(key, instance)
        }
    }

    func renderVisible(
        _ key: ShellBarKey,
        _ instance: OpaquePointer,
        changed: UInt64? = nil,
        allowed: UInt64 = .max
    ) async {
        guard !closing, let state = states[key] else { return }
        if let changed {
            state.invalidations[0] |= changed
            state.invalidations[1] |= changed
        }
        let visible = state.bar?.surface?.visible != false
        for index in 0 ..< 2 {
            let view: ShellWidgetView = index == 0 ? .bar : .popout
            guard view == .bar || popout == key else { continue }
            let pending = state.invalidations[view.rawValue] & allowed
            if changed != nil {
                let dependencies = state.deps[view.rawValue] | state.backgroundDemand
                guard pending & dependencies != 0 else { continue }
            }
            await render(key, instance, view, changed: pending, visible: visible)
            if visible { state.invalidations[view.rawValue] &= ~allowed }
        }
    }

    func render(
        _ key: ShellBarKey,
        _ instance: OpaquePointer,
        _ view: ShellWidgetView,
        changed: UInt64 = 0,
        visible: Bool = true
    ) async {
        guard !closing, let script, script.instances[key] == instance else { return }
        hydrate(key, instance)
        collectIfNeeded(script.vm)
        let trace = traceContext(key, view: view == .bar ? "bar" : "popout")
        let admission = omni_instance_begin_update(instance, view.wire, changed, visible)
        guard admission == OMNI_OK else {
            fail(admission)
            return
        }
        defer { omni_instance_cancel_update(instance, view.wire) }
        while !closing, self.script === script {
            let started = trace == nil ? 0 : CACurrentMediaTime()
            var step = omni_render_step_stats()
            let status = omni_instance_step_update(
                instance, view.wire, Self.renderBudget, &step, &errorBuffer, errorBuffer.count
            )
            recordRenderStep(step, status: status, started: started, trace: trace, vm: script.vm)
            flushMessages(key, instance)
            guard status == OMNI_OK else {
                states[key]?.deps[view.rawValue] = .max
                fail(status, deps: step.render.deps)
                return
            }
            if step.unit_status != OMNI_OK { log(1) { _ in lastError() } }
            if step.kind == OMNI_RENDER_ASSEMBLE, step.render.changed != 0, let state = states[key] {
                var size = 0
                if let bytes = omni_instance_output(instance, view.wire, &size) {
                    state.sequences[view.rawValue] += 1
                    outbox.publish(
                        name: name, generation: generation, key: ShellTreeKey(bar: key, view: view),
                        sequence: state.sequences[view.rawValue],
                        output: UnsafeRawBufferPointer(start: bytes, count: size), trace: trace
                    )
                }
            }
            if step.done {
                states[key]?.deps[view.rawValue] = step.render.deps
                if states[key]?.backgroundDemand != step.background_deps {
                    states[key]?.backgroundDemand = step.background_deps
                    publishBackgroundDemand()
                }
                return
            }
            await Task.yield()
        }
    }

    private func recordRenderStep(
        _ step: omni_render_step_stats,
        status: omni_status,
        started: CFTimeInterval,
        trace: ShellFrameTraceContext?,
        vm: OpaquePointer
    ) {
        if let trace, step.kind != OMNI_RENDER_IDLE {
            ShellFrameTrace.shared.record(.init(
                event: .render,
                context: trace,
                duration: CACurrentMediaTime() - started,
                cpuNs: step.render.cpu_ns,
                encodeCpuNs: step.render.encode_cpu_ns,
                vmBytes: omni_vm_bytes_in_use(vm),
                count: step.kind == OMNI_RENDER_ASSEMBLE ? 0 : 1,
                status: Int(status == OMNI_OK ? step.unit_status.rawValue : status.rawValue),
                detail: "kind=\(step.kind.rawValue) owner=\(step.owner.owner) unit=\(step.unit_id) unit_epoch=\(step.unit_epoch) changed=\(step.render.changed) cpu_includes_encode=true"
            ))
        }
    }

    func publishBackgroundDemand() {
        let demand = states.values.reduce(0) { $0 | $1.backgroundDemand }
        guard demand != publishedBackgroundDemand else { return }
        publishedBackgroundDemand = demand
        outbox.demand(name: name, generation: generation, background: demand)
    }

    func applySettings(_ instance: OpaquePointer) {
        var empty = ShellValueWriter()
        empty.null()
        let value = settings.isEmpty ? empty.bytes : settings
        _ = value.withUnsafeBufferPointer {
            omni_instance_set_value(instance, ShellDataKey.settings.rawValue, $0.baseAddress, $0.count)
        }
    }

    func flushMessages(_ key: ShellBarKey, _ instance: OpaquePointer) {
        if let script { drainServices(in: script) }
        let message = { (kind: omni_message_kind, index: Int) -> String in
            var length = 0
            guard let text = omni_instance_message(instance, kind, index, &length) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
        }
        let logs = omni_instance_message_count(instance, OMNI_MESSAGE_LOG)
        if logs > 0 {
            log(logs) { message(OMNI_MESSAGE_LOG, $0) }
        }
        let requests = (0 ..< omni_instance_message_count(instance, OMNI_MESSAGE_REQUEST)).map {
            ShellWidgetScriptRequest(bar: key, text: message(OMNI_MESSAGE_REQUEST, $0))
        }
        omni_instance_clear_messages(instance)
        if !requests.isEmpty {
            outbox.request(name: name, generation: generation, requests: requests)
        }
    }

    func log(_ count: Int, _ line: (Int) -> String) {
        startLogWindowIfNeeded()
        let allowed = min(count, Self.logLimit - logsInWindow)
        for index in 0 ..< allowed {
            let text = line(index)
            Log.shell.notice("Widget \(self.name): \(text)")
        }
        logsInWindow += allowed
        droppedLogs += count - allowed
    }

    private func startLogWindowIfNeeded() {
        let now = ContinuousClock.now
        guard now - logWindowStart >= Self.logWindow else { return }
        if droppedLogs > 0 {
            Log.shell.notice("Widget \(self.name): dropped \(self.droppedLogs) log lines")
        }
        logWindowStart = now
        logsInWindow = 0
        droppedLogs = 0
    }

    func fail(_ status: omni_status, deps: UInt64 = 0) {
        outbox.fail(
            name: name,
            generation: generation,
            failure: ShellScriptFailure(status: status, message: lastError()),
            deps: deps
        )
    }

    private func collectIfNeeded(_ vm: OpaquePointer) {
        let used = omni_vm_bytes_in_use(vm)
        guard used > liveAfterCollect + (Self.memoryLimit - liveAfterCollect) / 2 else { return }
        omni_vm_collect(vm)
        liveAfterCollect = omni_vm_bytes_in_use(vm)
    }

    func lastError() -> String {
        errorBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
