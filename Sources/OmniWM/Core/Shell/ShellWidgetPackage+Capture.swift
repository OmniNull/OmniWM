// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

extension ShellWidgetPackage {
    var utilityCaptureID: UInt64 {
        captureEndTask == nil ? captureContext?.capture ?? 0 : 0
    }

    func receiveCapture(_ request: ShellCaptureRequest) async {
        guard request.result == nil else { return }
        switch request.action {
        case let .begin(joined):
            guard !closing, let script, captureContext == nil else { request.finish(false)
                return
            }
            let context = request.context
            captureContext = context
            var stats = omni_capture_stats()
            captureVMStarted = omni_vm_capture_begin(script.vm, context.capture, &stats)
            services.captureBegin(context.capture)
            providerInbox.captureBegin(context.capture)
            resourceInbox.captureBegin(context.capture)
            recordCapture(
                context,
                detail: "scope=package service_generation=\(services.generation) available=\(captureVMStarted) incomplete=\(!captureVMStarted) boundary=begin joined=\(joined)"
            )
            let task = Task {
                if let http { await http.captureBegin(context.capture) }
                for slot in providerSlots.values {
                    await slot.captureStart?.value
                    await slot.supervisor.captureBegin(context.capture)
                }
            }
            captureBeginTask = task
            await task.value
            request.finish(true)
        case let .end(retired):
            let id = await finishTraceCapture(request.context.capture, retired: retired)
            request.finish(id == request.context.capture)
        }
    }

    @discardableResult
    func finishTraceCapture(_ id: UInt64? = nil, retired: Bool) async -> UInt64 {
        if let task = captureEndTask { return await task.value }
        guard let context = captureContext, id == nil || id == context.capture else { return 0 }
        let task = Task { () -> UInt64 in
            if let start = captureBeginTask { await start.value }
            var stats = omni_capture_stats()
            if captureVMStarted, let script, omni_vm_capture_end(script.vm, context.capture, &stats) {
                recordCapture(
                    context,
                    detail: Self.captureDetail(stats) + " service_generation=\(services.generation) boundary=\(retired ? "retire" : "end")"
                )
            } else {
                recordCapture(
                    context,
                    detail: "scope=native service_generation=\(services.generation) available=false incomplete=true boundary=\(retired ? "retire" : "end")"
                )
            }
            if let capture = services.captureEnd(context.capture) { recordCapture(
                context,
                detail: "scope=services boundary=\(retired ? "retire" : "end") " + capture.detail
            ) }
            if let capture = providerInbox.captureEnd(context.capture) { recordCapture(
                context,
                detail: "scope=provider_inbox boundary=\(retired ? "retire" : "end") " + capture.detail
            ) }
            if let capture = resourceInbox.captureEnd(context.capture) { recordCapture(
                context,
                detail: "scope=resource_inbox boundary=\(retired ? "retire" : "end") " + capture.detail
            ) }
            if let http, let capture = await http.captureEnd(context.capture) {
                recordCapture(context, detail: "scope=http boundary=\(retired ? "retire" : "end") " + capture.detail)
            }
            for (name, slot) in providerSlots {
                await slot.captureStart?.value
                if let capture = await slot.supervisor.captureEnd(context.capture) {
                    recordCapture(
                        context,
                        detail: "scope=provider boundary=\(retired ? "retire" : "end") " + capture.detail + " component=\(Self.captureName(name)) owner=\(slot.owner.owner)"
                    )
                }
            }
            captureContext = nil
            captureBeginTask = nil
            captureVMStarted = false
            captureEndTask = nil
            return context.capture
        }
        captureEndTask = task
        return await task.value
    }

    func retireProviderCapture(_ slot: ProviderSlot, name: String) async {
        guard let context = captureContext else { return }
        if let start = captureBeginTask { await start.value }
        await slot.captureStart?.value
        if let capture = await slot.supervisor.captureEnd(context.capture) {
            recordCapture(
                context,
                detail: "scope=provider boundary=retire " + capture.detail + " component=\(Self.captureName(name)) owner=\(slot.owner.owner) retired=true"
            )
        }
    }

    private func recordCapture(_ context: ShellFrameTraceContext, detail: String) {
        ShellFrameTrace.shared.record(.init(event: .counters, context: context, detail: detail))
    }

    private static func captureName(_ name: String) -> String {
        RuntimeTraceLimits.boundedString(name, maxBytes: 128)
    }

    private static func captureDetail(_ stats: omni_capture_stats) -> String {
        "scope=native available=true incomplete=false vm_bytes_begin=\(stats.vm_bytes_begin) vm_bytes=\(stats.vm_bytes)"
            + " tree_encodes=\(stats.tree_encodes) input_handlers=\(stats.input_handlers) trigger_handlers=\(stats.trigger_handlers)"
            + " service_handlers=\(stats.service_handlers) provider_handlers=\(stats.provider_handlers) drop_handlers=\(stats.drop_handlers) drag_handlers=\(stats.drag_handlers)"
            + " json_decodes=\(stats.json_decodes) json_decode_successes=\(stats.json_decode_successes)"
            + " provider_topic_inputs=\(stats.provider_topic_inputs) provider_topic_decodes=\(stats.provider_topic_decodes) provider_topic_decode_successes=\(stats.provider_topic_decode_successes)"
            + " provider_event_decodes=\(stats.provider_event_decodes) provider_event_decode_successes=\(stats.provider_event_decode_successes)"
            + " provider_result_decodes=\(stats.provider_result_decodes) provider_result_decode_successes=\(stats.provider_result_decode_successes)"
            + " reservations=\(stats.reservations) reservation_peak=\(stats.reservation_peak) owner_reservation_peak=\(stats.owner_reservation_peak)"
            + " http_reservations=\(stats.http_reservations) http_reservation_peak=\(stats.http_reservation_peak)"
            + " owner_rejections=\(stats.owner_rejections) package_rejections=\(stats.package_rejections) http_rejections=\(stats.http_rejections)"
            + " backlog_rejections=\(stats.backlog_rejections) id_rejections=\(stats.id_rejections)"
    }
}
