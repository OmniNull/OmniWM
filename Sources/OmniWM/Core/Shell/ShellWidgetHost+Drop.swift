// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    func connectResourceDrop(_ surface: ShellWidgetSurface, key: ShellTreeKey, widget: String) {
        let ingress = dropIngress
        let sourceID = surface.sourceID
        surface.resourceDropBridge = ShellDropBridge(reserve: { [weak self, weak surface] authority in
            guard let self, let surface else { return .failure(ShellResourceFailure("drop surface is unavailable")) }
            return await self.reserveResourceDrop(authority, surface: surface, key: key, widget: widget)
        }, finish: { reservation in
            reservation.operation.cancel()
            Task { @MainActor in ingress.cancel(reservation) }
        })
        surface.onResourceDrop = { reservation, snapshot, point, _ in
            ingress.accept(reservation, snapshot: snapshot, point: point)
        }
        surface.onResourceDropInvalidated = { ingress.cancel(sourceID: sourceID) }
        surface.onResourceDropDeclined = { Log.shell.error("Drop declined: \($0)") }
    }

    private func reserveResourceDrop(
        _ authority: ShellDropAuthority,
        surface: ShellWidgetSurface,
        key: ShellTreeKey,
        widget: String
    ) async -> Result<ShellDropReservation, ShellResourceFailure> {
        guard authority.sourceID == surface.sourceID,
              let state = widgets[widget], let package = state.package,
              currentDropSource(surface, key: key, widget: widget, generation: package.generation)
        else { return .failure(ShellResourceFailure("drop surface is unavailable")) }
        let result = await package.reserveDrop(authority, key: key)
        guard case let .success(reservation) = result else { return result }
        guard currentDropSource(surface, key: key, widget: widget, generation: package.generation) else {
            await package.finishDrop(reservation)
            return .failure(ShellResourceFailure("drop surface is unavailable"))
        }
        let bridge = ShellDropResourceBridge(admit: { reservation, values in
            try await package.admitDrop(reservation, values: values)
        }, deliver: { [weak self, weak surface] reservation, resources, point in
            guard let self, let surface,
                  await self.currentDropSource(surface, key: key, widget: widget, generation: package.generation)
            else { return false }
            return await package.deliverDrop(reservation, resources: resources, point: point)
        }, retire: { owner, resources in
            await package.retireResourceIDs(resources, owner: owner)
        }, finish: { reservation in
            await package.finishDrop(reservation)
        })
        guard dropIngress.prepare(reservation, ledger: package.services, bridge: bridge) else {
            await package.finishDrop(reservation)
            return .failure(ShellResourceFailure("drop_ingress_overloaded"))
        }
        return .success(reservation)
    }

    private func currentDropSource(
        _ surface: ShellWidgetSurface,
        key: ShellTreeKey,
        widget: String,
        generation: Int
    ) -> Bool {
        guard let state = widgets[widget], state.renderedGeneration == generation,
              state.package?.generation == generation, surface.visible else { return false }
        return interactionSurface(key: key, for: state) === surface
    }
}
