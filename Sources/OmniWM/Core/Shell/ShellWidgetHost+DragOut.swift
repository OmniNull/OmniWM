// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    func connectResourceDrag(_ surface: ShellWidgetSurface, key: ShellTreeKey, widget: String) {
        surface.resourceDragBridge = ShellDragOutBridge(prepare: { [weak self, weak surface] authority in
            guard let self, let surface else { throw ShellResourceFailure("drag_source_unavailable") }
            return try await self.prepareResourceDrag(authority, surface: surface, key: key, widget: widget)
        })
    }

    private func prepareResourceDrag(
        _ authority: ShellDragOutAuthority,
        surface: ShellWidgetSurface,
        key: ShellTreeKey,
        widget: String
    ) async throws -> ShellDragOutPreparation {
        guard authority.sourceID == surface.sourceID, let state = widgets[widget], let package = state.package,
              surface.visible, interactionSurface(key: key, for: state) === surface,
              state.renderedGeneration == package.generation
        else { throw ShellResourceFailure("drag_source_unavailable") }
        let prepared = try await package.prepareDragOut(authority, key: key)
        guard widgets[widget] === state, state.package === package, state.renderedGeneration == package.generation,
              surface.visible, interactionSurface(key: key, for: state) === surface
        else {
            await prepared.finish(false, false)
            throw ShellResourceFailure("drag_source_unavailable")
        }
        return prepared
    }
}
