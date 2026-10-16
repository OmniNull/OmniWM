// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    var drawers: [ShellDrawerConfig] {
        config.drawers
    }

    var toggleNames: [String] {
        Set(config.drawers.map(\.id) + widgets.values.filter(\.declaration.hasPopout).map(\.name)).sorted()
    }

    var widgetReport: IPCShellWidgetsQueryResult {
        IPCShellWidgetsQueryResult(
            profile: config.profile,
            widgets: widgets.values.sorted { $0.name < $1.name }.map { state in
                let failure = state.lastFailure ?? state.fallback
                return IPCShellWidget(
                    name: state.name,
                    source: state.sourceURL.path,
                    state: state.lastFailure != nil ? "failed" : state.package == nil ? "loading"
                        : state.fallback != nil ? "fallback" : "loaded",
                    error: failure?.message,
                    placements: placements(of: state)
                )
            },
            problems: configProblems
        )
    }

    private func placements(of state: WidgetState) -> [String] {
        [
            config.barLane(of: state.name)?.rawValue,
            config.hiddenBarWidget == state.name ? "hidden bar" : nil,
            config.systemStatsWidget == state.name ? "system stats" : nil,
            config.island?.root == state.name ? "island" : nil
        ].compactMap(\.self) + config.drawers.filter { $0.widgets.contains(state.name) }.map { "drawer \($0.id)" }
    }

    func publishToggleNames(forceWidgetReport: Bool = false) {
        let names = toggleNames
        if names != publishedToggleNames {
            publishedToggleNames = names
            onToggleNamesChange?()
        }
        let report = widgetReport
        if report != publishedReport || forceWidgetReport {
            publishedReport = report
            onWidgetsChange?()
        }
    }

    func trigger(_ widget: String, name: String, value: String?) -> Bool {
        guard let state = widgets[widget], state.package != nil, state.declaration.hasTrigger else { return false }
        state.mailbox?.yield(.trigger(name: name, value: value))
        return true
    }

    var openDrawer: ShellEdgeHover.Open? {
        guard let drawer, let spec = config.drawers.first(where: { $0.id == drawer.id }) else { return nil }
        return ShellEdgeHover.Open(drawer: spec, region: drawer.holdRegion)
    }

    func toggle(_ name: String, on monitor: Monitor.ID) -> Bool {
        toggleDrawer(name, on: monitor) || togglePopout(of: name, on: monitor)
    }

    func toggleDrawer(_ id: String, on monitor: Monitor.ID) -> Bool {
        guard let spec = config.drawers.first(where: { $0.id == id }) else { return false }
        if drawer?.id == id {
            closeDrawer()
            return true
        }
        closePopout()
        closeDrawer()
        let members = spec.widgets.compactMap { name -> (state: WidgetState, key: ShellBarKey)? in
            guard let state = widgets[name], state.package != nil else { return nil }
            let key = state.instances.keys.first { $0.monitor == monitor && bars[$0] != nil } ?? ShellBarKey(
                monitor: monitor
            )
            return (state, key)
        }
        guard !members.isEmpty, let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) else {
            return false
        }
        let bar = widgets.values.lazy.flatMap(\.instances)
            .first { $0.key.monitor == monitor && $0.key.placement == .bar }?.value.surface?.view
            .window
        let drawer = ShellEdgeDrawer(
            id: id,
            edge: spec.edge,
            chrome: spec.chrome,
            screen: screen,
            area: ShellEdgeDrawer.area(screen.visibleFrame, beside: bar.map(\.frame)),
            resources: resources,
            members: members.map {
                ShellEdgeDrawer.Member(widget: $0.state.name, key: $0.key, directories: folders(of: $0.state))
            }
        ) { [weak self] in
            self?.closeDrawer()
        }
        connectDrawer(drawer, members: members)
        self.drawer = drawer
        for (state, key) in members {
            if bars[key] == nil {
                drawerKeys[state.name] = key
                place(state)
            }
            state.mailbox?.yield(.popout(key, true))
        }
        onPopoutChange()
        return true
    }

    private func connectDrawer(_ drawer: ShellEdgeDrawer, members: [(state: WidgetState, key: ShellBarKey)]) {
        for (section, member) in zip(drawer.sections, members) {
            section.surface.assetFolders = member.state.assetPackages
            connectResourceDrop(
                section.surface,
                key: ShellTreeKey(bar: member.key, view: .popout),
                widget: member.state.name
            )
            connectResourceDrag(
                section.surface,
                key: ShellTreeKey(bar: member.key, view: .popout),
                widget: member.state.name
            )
            let key = member.key
            section.surface.onAction = { [weak self, weak state = member.state, weak surface = section.surface] click in
                guard let self, let state else { return }
                perform(click, view: .popout, key: key, for: state, from: surface)
            }
            connectMenu(section.surface, key: key, state: member.state)
            connectSurfaceFocus(section.surface) { [weak self, weak drawer] in self?.drawer === drawer }
        }
    }

    func closeDrawer(animated: Bool = true) {
        guard let drawer else { return }
        for section in drawer.sections { releaseShellFocus(from: section.surface, restore: true) }
        self.drawer = nil
        finishClosingDrawer()
        let finished = drawer.close(animated: animated) { [weak self, weak drawer] in
            guard let self, closingDrawer === drawer else { return }
            closingDrawer = nil
        }
        if !finished {
            closingDrawer = drawer
        }
        for section in drawer.sections {
            let state = widgets[section.widget]
            state?.instances[section.key]?.popoutDeps = 0
            state?.mailbox?.yield(.popout(section.key, false))
        }
        let placed = Array(drawerKeys.keys)
        drawerKeys = [:]
        for name in placed {
            if let state = widgets[name] {
                place(state)
            }
        }
        publishDemand()
        onPopoutChange()
    }

    func logCommandFailure(_ message: String, widget: String) {
        widgets[widget]?.mailbox?.yield(.log(message))
    }

    func closePopout(animated: Bool = true) {
        closeHiddenBarMenu()
        guard let popout else { return }
        releaseShellFocus(from: popout.surface, restore: true)
        self.popout = nil
        finishClosing()
        let finished = popout.close(animated: animated) { [weak self, weak popout] in
            guard let self, closingPopout === popout else { return }
            closingPopout = nil
        }
        if !finished {
            closingPopout = popout
        }
        let state = widgets[popout.widget]
        state?.instances[popout.key]?.popoutDeps = 0
        state?.mailbox?.yield(.popout(popout.key, false))
        if headless != nil {
            headless = nil
            if let state {
                place(state)
            }
        }
        publishDemand()
        onPopoutChange()
    }
}
