// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func prepareDragOut(_ authority: ShellDragOutAuthority, key: ShellTreeKey) async throws -> ShellDragOutPreparation {
        guard !closing, nativeInput.isConnected, let script, let instance = script.instances[key.bar],
              let sequence = states[key.bar]?.sequences[key.view.rawValue], authority.sequence <= sequence
        else {
            throw ShellResourceFailure("drag_source_unavailable")
        }
        let reservation = try reserveDrag(authority, key: key, instance: instance)
        let id = reservation.id
        let operation = ShellResourceOperation()
        var pin: ShellResourceStore.Pin?
        do {
            let component = try dragComponent(id.owner, in: script)
            guard permitsFiles(id.owner, component: component) else { throw ShellResourceFailure("files_denied") }
            guard reservation.resourceCount > 0,
                  reservation.resourceCount <= reservation.values.count
            else { throw ShellResourceFailure("invalid_resources") }
            guard services.register(id, cancel: { operation.cancel() })
            else { throw ShellResourceFailure("service_overload") }
            let ids = reservation.values.prefix(reservation.resourceCount).map { ShellResourceID(UUID(uuid: $0.bytes)) }
            let prepared = try await resourceStore.retain(ids, owner: id.owner)
            pin = prepared
            guard !closing, self.script === script, operation.isActive else { throw ShellResourceFailure("cancelled") }
            return ShellDragOutPreparation(
                id: id,
                authority: authority,
                resources: ids,
                pin: prepared,
                operation: operation,
                begin: { await self.beginDragOut(id, operation: operation) },
                finish: { copied, deliver in await self.finishDragOut(
                    id,
                    pin: prepared,
                    operation: operation,
                    copied: copied,
                    deliver: deliver
                ) }
            )
        } catch {
            if let pin { await resourceStore.release(pin) }
            _ = await nativeInput.send(.finishDrag(id, operation, copied: false, deliver: false))
            services.cancel(id)
            throw error
        }
    }

    private struct DragReservation {
        let id: ShellServiceID
        let values: [omni_resource_id]
        let resourceCount: Int
    }

    private func reserveDrag(
        _ authority: ShellDragOutAuthority,
        key: ShellTreeKey,
        instance: OpaquePointer
    ) throws -> DragReservation {
        var owner = omni_owner_token()
        var request: UInt64 = 0
        var count = 0
        var values = [omni_resource_id](repeating: omni_resource_id(), count: ShellResourceStore.attachmentLimit)
        let status = values.withUnsafeMutableBufferPointer {
            omni_instance_reserve_drag(
                instance,
                key.view.wire,
                authority.declaration,
                authority.action,
                authority.sourceID,
                &owner,
                &request,
                $0.baseAddress,
                $0.count,
                &count,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard status == OMNI_OK else { throw ShellResourceFailure(lastError()) }
        return DragReservation(
            id: ShellServiceID(owner: ShellServiceOwner(owner), request: request),
            values: values,
            resourceCount: count
        )
    }

    private func dragComponent(_ owner: ShellServiceOwner, in script: ShellScript) throws -> String? {
        var component: String?
        if owner.owner != 0 {
            component = configuredComponents.keys.first { name in
                var candidate = omni_owner_token()
                return omni_vm_component_owner(script.vm, name, name.utf8.count, &candidate)
                    && ShellServiceOwner(candidate) == owner
            }
            guard component != nil else { throw ShellResourceFailure("drag_owner_unavailable") }
        }
        return component
    }

    private func beginDragOut(_ id: ShellServiceID, operation: ShellResourceOperation) async {
        guard operation.isActive, services.contains(id) else { return }
        _ = await nativeInput.send(.beginDrag(id, operation))
    }

    private func finishDragOut(
        _ id: ShellServiceID,
        pin: ShellResourceStore.Pin,
        operation: ShellResourceOperation,
        copied: Bool,
        deliver: Bool
    ) async {
        _ = await nativeInput.send(.finishDrag(id, operation, copied: copied, deliver: deliver))
        services.cancel(id)
        await resourceStore.release(pin)
    }
}
