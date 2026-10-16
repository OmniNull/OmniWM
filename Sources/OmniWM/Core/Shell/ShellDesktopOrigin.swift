// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ShellDesktopOrigin: Equatable, Sendable {
    let widget: String
    let generation: Int
    let key: ShellTreeKey
    let sourceID: UInt64
}

extension ShellWidgetPackage {
    func desktopOrigin(_ request: omni_service_request, in script: ShellScript) -> ShellDesktopOrigin? {
        guard request.surface != 0, request.display != OMNI_NO_DISPLAY,
              let key = script.instances.first(where: { omni_instance_display_id($0.value) == request.display })?.key
        else { return nil }
        let view: ShellWidgetView
        switch request.view {
        case OMNI_VIEW_BAR: view = .bar
        case OMNI_VIEW_POPOUT: view = .popout
        default: return nil
        }
        return ShellDesktopOrigin(
            widget: name,
            generation: generation,
            key: ShellTreeKey(bar: key, view: view),
            sourceID: request.surface
        )
    }
}

extension ShellWidgetHost {
    func desktopSource(for origin: ShellDesktopOrigin) -> ShellDesktopSource? {
        guard let state = widgets[origin.widget],
              let surface = desktopSurface(for: origin, state: state) else { return nil }
        return desktopSource(for: surface) { [weak self, weak state, weak surface] in
            guard let self, let state, let surface else { return false }
            return desktopSurface(for: origin, state: state) === surface
        }
    }

    func desktopAnchor(
        for origin: ShellDesktopOrigin,
        resolution: ShellDesktopAnchorResolution
    ) -> ShellDesktopAnchor? {
        guard let state = widgets[origin.widget],
              let surface = desktopSurface(for: origin, state: state) else { return nil }
        return surface.desktopAnchor(resolution)
    }

    private func desktopSurface(for origin: ShellDesktopOrigin, state: WidgetState) -> ShellWidgetSurface? {
        guard origin.sourceID != 0, widgets[origin.widget] === state,
              state.renderedGeneration == origin.generation,
              state.package?.generation == origin.generation,
              let surface = interactionSurface(key: origin.key, for: state),
              surface.sourceID == origin.sourceID, surface.visible else { return nil }
        return surface
    }
}
