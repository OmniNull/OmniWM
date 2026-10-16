// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func reserveDrop(
        _ authority: ShellDropAuthority,
        key: ShellTreeKey
    ) async -> Result<ShellDropReservation, ShellResourceFailure> {
        guard !closing, nativeInput.isConnected, let script, let instance = script.instances[key.bar],
              let sequence = states[key.bar]?.sequences[key.view.rawValue], authority.sequence <= sequence
        else { return .failure(ShellResourceFailure("drop target is unavailable")) }
        var token = omni_owner_token()
        var request: UInt64 = 0
        let status = omni_instance_reserve_drop(
            instance,
            key.view.wire,
            authority.action,
            authority.sourceID,
            &token,
            &request,
            &errorBuffer,
            errorBuffer.count
        )
        guard status == OMNI_OK else { return .failure(ShellResourceFailure(lastError())) }
        let owner = ShellServiceOwner(token)
        let id = ShellServiceID(owner: owner, request: request)
        do {
            var component: String?
            if owner.owner != 0 {
                component = configuredComponents.keys.first { name in
                    var candidate = omni_owner_token()
                    return omni_vm_component_owner(script.vm, name, name.utf8.count, &candidate)
                        && ShellServiceOwner(candidate) == owner
                }
                guard component != nil else { throw ShellResourceFailure("drop owner is unavailable") }
            }
            guard permitsFiles(owner, component: component) else { throw ShellResourceFailure("files_denied") }
            try bindResources(owner, component: component)
            let reservation = ShellDropReservation(id: id, authority: authority, component: component)
            guard services.register(id, cancel: { reservation.operation.cancel() }) else {
                throw ShellResourceFailure("service_overload")
            }
            return .success(reservation)
        } catch {
            _ = await nativeInput.send(.finishDrop(ShellDropReservation(id: id, authority: authority)))
            return .failure(ShellResourceFailure(String(describing: error)))
        }
    }

    func admitDrop(_ reservation: ShellDropReservation, values: [ShellPickedResource]) throws -> [ShellResourceID] {
        guard reservation.operation.isActive,
              permitsFiles(reservation.id.owner, component: reservation.component)
        else {
            throw ShellResourceFailure("drop owner is unavailable")
        }
        return try admitResources(values, owner: reservation.id.owner, component: reservation.component)
    }

    func deliverDrop(_ reservation: ShellDropReservation, resources: [ShellResourceID], point: CGPoint) async -> Bool {
        guard reservation.operation.isActive, services.contains(reservation.id) else { return false }
        return await nativeInput.send(.drop(reservation, resources, point))
    }

    func deliverDropNow(
        _ reservation: ShellDropReservation,
        resources: [ShellResourceID],
        point: CGPoint
    ) async -> Bool {
        guard !closing, reservation.operation.isActive, let script,
              permitsFiles(reservation.id.owner, component: reservation.component) else { return false }
        for (key, instance) in script.instances { hydrate(key, instance) }
        let ids = resources.map { omni_resource_id(bytes: $0.value.uuid) }
        var transferred = false
        let status = ids.withUnsafeBufferPointer {
            omni_vm_deliver_drop(
                script.vm,
                reservation.id.owner.wire,
                reservation.id.request,
                $0.baseAddress,
                $0.count,
                point.x,
                point.y,
                Self.handlerBudget,
                &transferred,
                &errorBuffer,
                errorBuffer.count
            )
        }
        if status == OMNI_ERR_COMPONENT || status == OMNI_ERR_STALE_ACTION {
            log(1) { _ in lastError() }
        } else if status != OMNI_OK { fail(status) }
        drainServices(in: script)
        if transferred {
            for (key, instance) in script.instances {
                guard !closing, self.script === script else { break }
                await renderVisible(key, instance)
            }
        }
        return transferred
    }

    func finishDrop(_ reservation: ShellDropReservation) async {
        reservation.operation.cancel()
        _ = await nativeInput.send(.finishDrop(reservation))
        services.cancel(reservation.id)
    }
}
