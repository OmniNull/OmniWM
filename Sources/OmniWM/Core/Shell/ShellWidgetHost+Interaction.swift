// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    func perform(
        _ click: ShellClick,
        view: ShellWidgetView,
        key: ShellBarKey,
        for state: WidgetState,
        from surface: ShellWidgetSurface? = nil
    ) {
        let action = click.action
        if click.event.kind == .click, view == .bar, click.target != 0, click.event.button == .left, click.event.shift,
           click.event.phase == nil
        {
            onCommand(
                .moveFocusedWindow(target: state.text.string(click.target)),
                ShellCommandOrigin(monitor: key.monitor, anchor: click.anchor, event: click.event)
            )
            return
        }
        let plainClick = click.event
            .kind == .click && (click.event.button == .left || click.event.button == .right) && click.event.phase == nil
        guard plainClick || action & OMNI_ACTION_HANDLER != 0 else {
            return
        }
        if action == OMNI_ACTION_POPOUT {
            if view == .popout, drawer?.section(widget: state.name, key: key) != nil {
                closeDrawer()
                return
            }
            togglePopout(for: state, key: key, click: click, from: view)
            return
        }
        if action & OMNI_ACTION_HANDLER != 0 {
            invokeHandler(click, view: view, key: key, for: state, from: surface)
            return
        }
        runCommand(click, view: view, key: key, for: state)
    }

    private func invokeHandler(
        _ click: ShellClick, view: ShellWidgetView, key: ShellBarKey, for state: WidgetState,
        from source: ShellWidgetSurface?
    ) {
        var event = click.event
        let id = ShellInvocation.next()
        event.invocationID = id
        event.sourceID = source?.sourceID ?? 0
        if let token = event.trackingToken { source?.bindGestureInvocation(trackToken: token, invocationID: id) }
        var enqueued = false
        defer { if !enqueued { source?.acknowledgeGesture(through: id) } }
        guard widgets[state.name] === state,
              let package = state.package, package.generation == state.renderedGeneration,
              let mailbox = state.mailbox,
              let published = state.instances[key]?.sequences[view.rawValue],
              source == nil || interactionSurface(key: ShellTreeKey(bar: key, view: view), for: state) === source
        else { return }
        let sequence = click.sequence ?? published
        ShellFrameTrace.shared.record(.enqueue, context: event.trace)
        if event.isGesture {
            let gesture = ShellGestureBox.Gesture(
                bar: key,
                view: view,
                action: click.action,
                sequence: sequence,
                event: event
            )
            if let pending = package.gestures.post(gesture) {
                if case .enqueued = mailbox.yield(.gesture(pending)) { enqueued = true }
            } else { enqueued = true }
            return
        }
        package.gestures.seal()
        if case .enqueued = mailbox.yield(.invoke(key, view, action: click.action, sequence: sequence, event: event)) {
            enqueued = true
        }
        if click.opensPopout, view == .bar, !event.hasModifiers {
            togglePopout(for: state, key: key, click: click, from: view)
        }
    }

    private func runCommand(_ click: ShellClick, view: ShellWidgetView, key: ShellBarKey, for state: WidgetState) {
        let command = state.text.string(click.action)
        guard let parsed = ShellAction(command) else {
            report(
                state,
                ShellScriptFailure(
                    kind: .runtime,
                    message: "onClick \"\(command)\" is not an omniwmctl, shell or volume command"
                )
            )
            return
        }
        if view == .popout, case let .wm(request) = parsed, !request.isHiddenBarActivation {
            closePopout()
        }
        run(
            parsed,
            origin: ShellCommandOrigin(
                monitor: key.monitor,
                anchor: click.anchor,
                event: click.event,
                widget: state.name,
                command: command
            ),
            for: state
        )
    }

    func run(_ action: ShellAction, origin: ShellCommandOrigin, for state: WidgetState) {
        switch action {
        case let .wm(request): onCommand(request, origin)
        case let .volume(command): ShellAudio.perform(command, appVolumes: resources.appVolumes)
        case let .media(command): resources.media?.perform(command)
        case let .calendar(command): resources.calendar?.perform(command)
        case let .reminders(command): resources.calendar?.perform(command)
        case let .inputSource(command): resources.devices.inputSource.perform(command)
        case let .wifi(command): resources.devices.wifi.perform(command)
        case let .bluetooth(command): resources.devices.bluetooth.perform(command)
        case let .session(command): ShellSession.perform(command)
        case let .settings(pane):
            if let url = pane.url {
                NSWorkspace.shared.open(url)
            }
        case let .toggle(widget):
            if !toggle(widget, on: origin.monitor) {
                report(
                    state,
                    ShellScriptFailure(
                        kind: .runtime,
                        message: "shell toggle: no widget or drawer named \"\(widget)\""
                    )
                )
            }
        }
    }

    var hiddenBarWidget: String? {
        config.hiddenBarWidget
    }

    var systemStatsWidget: String? {
        config.systemStatsWidget
    }

    func shows(_ name: String, on monitor: Monitor.ID) -> Bool {
        widgets[name]?.instances.contains { key, instance in
            key.monitor == monitor && key.placement == .bar && instance.surface
                .map { $0.size.width > 0 && $0.screenAnchor != nil } == true
        } == true
    }

    func updateHiddenBar(_ data: ShellHiddenBarData) {
        feed?.setHiddenBar(data)
    }

    func showHiddenBarMenu(
        _ page: HiddenBarMenuPage,
        anchor: ShellAnchor,
        onSelect: @escaping @MainActor (String) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) -> Bool {
        closeHiddenBarMenu()
        guard let popout,
              let url = config.widget("hidden-bar-menu") ?? ShellConfig.bundledWidget("hidden-bar-menu")
        else { return false }
        let state = WidgetState(name: "hidden-bar-menu", sourceURL: url)
        do {
            let source = try widgetSource(of: state)
            onHiddenBarMenuClose = onClose
            hiddenBarMenu = ShellHiddenBarMenu(
                page: page,
                anchor: anchor,
                parent: popout,
                resources: resources,
                resourceStore: resourceStore,
                source: source,
                directories: folders(of: state),
                onSelect: onSelect,
                onFailure: { [weak self] in self?.closeHiddenBarMenu() }
            )
            if let menu = hiddenBarMenu {
                connectSurfaceFocus(menu.popout.surface) { [weak self, weak menu] in self?.hiddenBarMenu === menu }
            }
            return true
        } catch {
            Log.shell.error("Could not load Hidden Bar menu: \(error.localizedDescription)")
            return false
        }
    }

    func closeHiddenBarMenu() {
        let menu = hiddenBarMenu
        if let menu { releaseShellFocus(from: menu.popout.surface, restore: true) }
        hiddenBarMenu = nil
        menu?.close()
        let onClose = onHiddenBarMenuClose
        onHiddenBarMenuClose = nil
        onClose?()
    }

    func togglePopout(
        of name: String,
        on monitor: Monitor.ID,
        anchor explicit: ShellAnchor? = nil,
        drawer: ShellPopoutDrawer? = nil
    ) -> Bool {
        guard let state = widgets[name] else { return false }
        if popout?.widget == name {
            closePopout()
            return true
        }
        let keys = WorkspaceBarIslandSlice.allCases.map { ShellBarKey(monitor: monitor, island: $0) }
            .filter { state.instances[$0] != nil }
        let anchored = keys.lazy.compactMap { key in
            state.instances[key]?.surface?.screenAnchor.map { (key, $0) }
        }.first
        guard let anchor = explicit ?? anchored?.1 ?? Self.edgeAnchor(on: monitor) else { return false }
        guard let key = anchored?.0 ?? keys.first else {
            closePopout()
            let key = ShellBarKey(monitor: monitor)
            headless = (state.name, key)
            place(state)
            openPopout(for: state, key: key, anchor: anchor, drawer: drawer)
            if popout == nil {
                headless = nil
                place(state)
            }
            return popout != nil
        }
        let source = explicit == nil
            ? anchored.map { ShellAnchorSource(surface: state.instances[$0.0]?.surface, element: .none) } : nil
        openPopout(for: state, key: key, anchor: anchor, source: source, drawer: drawer)
        return popout?.widget == name
    }

    private static func edgeAnchor(on monitor: Monitor.ID) -> ShellAnchor? {
        guard let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) else { return nil }
        let visible = screen.visibleFrame
        return ShellAnchor(
            frame: CGRect(x: visible.maxX - 1, y: visible.maxY - 1, width: 1, height: 1),
            level: .statusBar
        )
    }

    func connectMenu(_ surface: ShellWidgetSurface, key: ShellBarKey, state: WidgetState) {
        let monitor = key.monitor
        surface.onMenu = { [weak self, weak state, weak surface] event in
            guard let self, let state, let surface else { return }
            onMenu(ShellMenuRequest(
                monitor: monitor,
                target: state.text.string(event.target),
                anchor: event.anchor,
                label: event.label,
                view: surface.view
            ))
        }
        surface.onDrag = { [weak self, weak state] event in
            guard let self, let state else { return }
            switch event {
            case let .began(target, point):
                onDrag(.began(monitor: monitor, target: state.text.string(target), at: point))
            case let .moved(point):
                onDrag(.moved(point))
            case let .ended(point):
                onDrag(.ended(point))
            }
        }
        surface.onTooltip = { [weak self, weak state] event in
            guard let self else { return }
            guard let event, let state else {
                tooltip.hide()
                return
            }
            tooltip.show(state.text.string(event.text), at: event.location)
        }
        surface.onPreview = { [weak self, weak state] event in
            guard let self, let state else { return }
            onPreview(ShellPreviewRequest(
                monitor: monitor,
                target: event.target == 0 ? nil : state.text.string(event.target),
                anchor: event.anchor?.frame
            ))
        }
    }

    private func togglePopout(
        for state: WidgetState,
        key: ShellBarKey,
        click: ShellClick,
        from view: ShellWidgetView
    ) {
        if view == .popout || (popout?.widget == state.name && popout?.key == key)
            || state.package?.generation != state.renderedGeneration
        {
            closePopout()
        } else {
            let source = ShellAnchorSource(surface: state.instances[key]?.surface, element: click.source)
            openPopout(for: state, key: key, anchor: click.anchor, source: source)
        }
    }

    private func openPopout(
        for state: WidgetState,
        key: ShellBarKey,
        anchor: ShellAnchor,
        source: ShellAnchorSource? = nil,
        drawer: ShellPopoutDrawer? = nil
    ) {
        closePopout()
        closeDrawer()
        let center = CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)
        guard state.package != nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return
        }
        let popout = ShellPopout(
            widget: state.name,
            key: key,
            anchor: anchor,
            source: source,
            edge: bars[key].flatMap { WorkspaceBarPosition(rawValue: $0.style.position)?.popupEdge },
            screen: screen,
            resources: resources,
            directories: folders(of: state),
            drawer: drawer
        ) { [weak self] in
            self?.closePopout()
        }
        popout.surface.assetFolders = state.assetPackages
        connectResourceDrop(popout.surface, key: ShellTreeKey(bar: key, view: .popout), widget: state.name)
        connectResourceDrag(popout.surface, key: ShellTreeKey(bar: key, view: .popout), widget: state.name)
        popout.surface.onAction = { [weak self, weak state, weak surface = popout.surface] click in
            guard let self, let state else { return }
            perform(click, view: .popout, key: key, for: state, from: surface)
        }
        connectMenu(popout.surface, key: key, state: state)
        self.popout = popout
        connectSurfaceFocus(popout.surface) { [weak self, weak popout] in self?.popout === popout }
        popout.onKeyboardFocus = { [weak self, weak popout] active in
            guard let self, let popout, self.popout === popout else { return }
            if active { focusShellSurface(popout.surface, keyboardNavigation: true) }
            else { releaseShellFocus(from: popout.surface, restore: true) }
        }
        let trace = ShellFrameTrace.current
        ShellFrameTrace.shared.record(.enqueue, context: trace)
        state.mailbox?.yield(.popout(key, true, trace: trace))
        onPopoutChange()
    }

    func finishClosing() {
        closingPopout?.finishClose()
        closingPopout = nil
        finishClosingDrawer()
    }

    func finishClosingDrawer() {
        closingDrawer?.finishClose()
        closingDrawer = nil
    }
}
