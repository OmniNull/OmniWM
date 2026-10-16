// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func deliverNativeInput(_ input: ShellNativeInput, in script: ShellScript) async {
        let transferred: Bool
        switch input.event {
        case let .drop(reservation, resources, point):
            transferred = await deliverDropNow(reservation, resources: resources, point: point)
        case let .finishDrop(reservation):
            _ = omni_vm_finish_drop(script.vm, reservation.id.owner.wire, reservation.id.request)
            transferred = false
        case let .beginDrag(id, operation):
            if operation.isActive {
                for (key, instance) in script.instances { hydrate(key, instance) }
                var handled = false
                let status = omni_vm_begin_drag(
                    script.vm,
                    id.owner.wire,
                    id.request,
                    Self.handlerBudget,
                    &handled,
                    &errorBuffer,
                    errorBuffer.count
                )
                await finishDragCallback(status, handled: handled, in: script)
            }
            transferred = false
        case let .finishDrag(id, operation, copied, deliver):
            for (key, instance) in script.instances { hydrate(key, instance) }
            var handled = false
            let status = omni_vm_finish_drag(
                script.vm,
                id.owner.wire,
                id.request,
                copied,
                deliver && operation.isActive,
                Self.handlerBudget,
                &handled,
                &errorBuffer,
                errorBuffer.count
            )
            await finishDragCallback(status, handled: handled, in: script)
            transferred = false
        }
        input.completion.resume(returning: transferred)
    }

    private func finishDragCallback(_ status: omni_status, handled: Bool, in script: ShellScript) async {
        if status == OMNI_ERR_COMPONENT || status == OMNI_ERR_STALE_ACTION { log(1) { _ in lastError() } }
        else if status != OMNI_OK { fail(status) }
        drainServices(in: script)
        if handled {
            for (key, instance) in script.instances {
                guard !closing, self.script === script else { break }
                await renderVisible(key, instance)
            }
        }
    }
}
