// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@MainActor
@Observable
final class ShellDesktopEditor {
    let configuration: ShellConfigurationCoordinator
    let settings: SettingsStore
    let writes = ShellSettingsWriteQueue()
    @ObservationIgnored let controller: WMController
    @ObservationIgnored let dragToken = UUID().uuidString
    @ObservationIgnored private weak var navigation: SettingsNavigationModel?

    private(set) var selectedStyle: String
    private(set) var snapshot: ShellEditorSnapshot?
    private(set) var barSettings = WorkspaceBarSettings()
    private(set) var monitors: [Monitor] = Monitor.current()
    private(set) var selectedMonitor: Monitor.ID?
    private(set) var selectedWidget: String?
    private(set) var surface = Surface.bar
    private(set) var selectedComponent: String?
    private(set) var selectedDrawer: String?
    private(set) var group: String?
    private(set) var drafts: [ShellEditorDraft.Key: ShellEditorDraft] = [:]
    private(set) var pendingTransition: Transition?
    var problem: String?

    init(configuration: ShellConfigurationCoordinator, settings: SettingsStore, controller: WMController) {
        self.configuration = configuration
        self.settings = settings
        self.controller = controller
        selectedStyle = configuration.config.profile
    }

    var activeStyle: String {
        configuration.config.profile
    }

    var scope: Scope {
        selectedStyle == activeStyle ? .active : .previewing(active: activeStyle)
    }

    var cards: [StyleCard] {
        configuration.profiles.map {
            StyleCard(
                name: $0, title: configuration.styleTitle($0), summary: configuration.styleSummary($0),
                active: $0 == activeStyle
            )
        }
    }

    var strings: ShellStrings {
        snapshot?.style.strings ?? .empty
    }

    var monitor: Monitor? {
        monitors.first { $0.id == selectedMonitor }
    }

    var hasUnsavedChanges: Bool {
        drafts.values.contains(where: \.dirty) || !writes.failures.isEmpty
    }

    func reload() async {
        let style = selectedStyle
        do {
            try await configuration.ensureLoaded()
            let next = try await configuration.editorSnapshot(profile: style)
            guard style == selectedStyle else { return }
            snapshot = next
            barSettings = settings.workspaceBar.isolated(profileOverride: next.config.barOverride)
            if let widget = selectedWidget, next.layout.source(of: widget) == nil, next.layout.lane(of: widget) == nil {
                selectedWidget = nil
            }
            if let component = selectedComponent,
               next.config.island?.components.contains(where: { $0.id == component }) != true
            {
                selectedComponent = nil
            }
            selectedDrawer = drawerID(selectedDrawer)
            await refreshCleanDrafts()
        } catch is CancellationError {
        } catch {
            guard style == selectedStyle else { return }
            problem = error.localizedDescription
        }
    }

    func refreshMonitors() {
        monitors = Monitor.current()
        if !monitors.contains(where: { $0.id == selectedMonitor }) { selectedMonitor = nil }
    }

    func selectMonitor(_ id: Monitor.ID?) {
        selectedMonitor = monitors.contains { $0.id == id } ? id : nil
    }

    @discardableResult
    func selectStyle(_ name: String) async -> Bool {
        guard name != selectedStyle else { return true }
        return await request(.style(name))
    }

    @discardableResult
    func selectWidget(_ name: String?) async -> Bool {
        guard name != selectedWidget else { return true }
        return await request(.widget(name))
    }

    @discardableResult
    func selectSurface(_ next: Surface) async -> Bool {
        guard next != surface else { return true }
        return await request(.surface(next))
    }

    @discardableResult
    func selectComponent(_ id: String?) async -> Bool {
        guard id != selectedComponent else { return true }
        return await request(.component(id))
    }

    @discardableResult
    func selectDrawer(_ id: String?) async -> Bool {
        guard id != selectedDrawer else { return true }
        return await request(.drawer(id))
    }

    var destination: Destination {
        Destination(
            surface: surface, widget: selectedWidget, component: selectedComponent, group: group, drawer: selectedDrawer
        )
    }

    func open(_ route: SettingsRoute) async {
        guard route.section == .styles else { return }
        let next: Destination
        if route.tab == "island" {
            next = Destination(
                surface: .island, widget: selectedWidget, component: route.itemID, group: route.anchor,
                drawer: selectedDrawer
            )
        } else if route.tab == "drawers" {
            next = Destination(
                surface: .drawers, widget: selectedWidget, component: selectedComponent,
                drawer: route.itemID ?? selectedDrawer
            )
        } else if route.itemID != nil || route.tab != nil {
            next = Destination(
                surface: .bar, widget: route.itemID, component: selectedComponent, group: route.tab,
                drawer: selectedDrawer
            )
        } else { return }
        guard next != destination else { return }
        guard next.surface != surface || next.widget != selectedWidget || next.component != selectedComponent
            || next.drawer != selectedDrawer
        else {
            group = next.group
            return syncRoute()
        }
        _ = await request(.destination(next))
    }

    @discardableResult
    func useStyle() async -> Bool {
        await request(.useStyle)
    }

    func request(_ transition: Transition) async -> Bool {
        guard !hasUnsavedChanges else {
            pendingTransition = transition
            if !writes.failures.isEmpty {
                problem = String(localized: "A change could not be saved. Retry or discard it first.")
            }
            return false
        }
        return await complete(transition)
    }

    func resolve(_ resolution: Resolution) async {
        guard let transition = pendingTransition else { return }
        switch resolution {
        case .cancel:
            if case .leave = transition { navigation?.cancelNavigation() }
            pendingTransition = nil
            if transition.selection { syncRoute() }
        case .discard:
            drafts.removeAll()
            for target in writes.failures.keys {
                writes.discard(target)
            }
            pendingTransition = nil
            _ = await complete(transition)
        case .save:
            pendingTransition = nil
            for target in writes.failures.keys {
                writes.retry(target)
            }
            guard await saveDrafts(), await writes.drain() else {
                problem = String(localized: "A change could not be saved. Retry or discard it first.")
                if case .leave = transition { navigation?.cancelNavigation() }
                if transition.selection { syncRoute() }
                return
            }
            _ = await complete(transition)
        }
    }

    func setDraft(_ draft: ShellEditorDraft) {
        drafts[draft.key] = draft
    }

    func clearDraft(_ key: ShellEditorDraft.Key) {
        drafts[key] = nil
    }

    func focus(_ widget: String) {
        guard drafts.values.allSatisfy({ !$0.dirty || $0.key.widget == widget }) else { return }
        selectedWidget = widget
        syncRoute()
    }

    func focusComponent(_ id: String) {
        guard surface == .island, drafts.values.allSatisfy({ !$0.dirty || $0.key.component == id }) else { return }
        selectedComponent = id
        group = nil
        syncRoute()
    }

    func focusDrawer(_ id: String) {
        guard drafts.values.allSatisfy({ !$0.dirty }) else { return }
        selectedDrawer = drawerID(id)
        syncRoute()
    }

    func syncRoute() {
        guard navigation?.section == .styles else { return }
        let route = switch surface {
        case .bar: SettingsRoute(section: .styles, itemID: selectedWidget)
        case .island: SettingsRoute(
                section: .styles, tab: "island", anchor: selectedComponent == nil ? group : nil,
                itemID: selectedComponent
            )
        case .drawers: SettingsRoute(section: .styles, tab: "drawers", itemID: selectedDrawer)
        }
        navigation?.reflect(route)
    }

    func attach(_ navigation: SettingsNavigationModel) {
        self.navigation = navigation
        navigation.leaveGuard = { [weak self] route in
            guard let self else { return false }
            if hasUnsavedChanges {
                pendingTransition = .leave(route)
            } else {
                Task { _ = await complete(.leave(route)) }
            }
            return true
        }
    }

    func detach() {
        if navigation?.leaveGuard != nil { navigation?.leaveGuard = nil }
    }

    func openPermissions(_ role: ShellWidgetPrincipal.Role, _ name: String) {
        navigation?.request(SettingsRoute(section: .network, anchor: NetworkPermissionsPage.anchor(role, name)))
    }

    private func complete(_ transition: Transition) async -> Bool {
        guard await writes.drain() else {
            problem = String(localized: "A change could not be saved. Retry or discard it first.")
            if case .leave = transition { navigation?.cancelNavigation() }
            if transition.selection { syncRoute() }
            return false
        }
        switch transition {
        case let .style(name):
            drafts.removeAll()
            selectedWidget = nil
            selectedComponent = nil
            selectedDrawer = nil
            group = nil
            selectedStyle = name
            snapshot = nil
            await reload()
        case .useStyle:
            do { _ = try await configuration.selectProfile(selectedStyle) } catch {
                problem = error.localizedDescription
                return false
            }
        case let .leave(route):
            drafts.removeAll()
            navigation?.proceed(to: route)
        default:
            select(transition)
        }
        return true
    }

    private func select(_ transition: Transition) {
        drafts.removeAll()
        switch transition {
        case let .widget(name):
            selectedWidget = name
        case let .surface(next):
            surface = next
            group = nil
        case let .component(id):
            selectedComponent = id
            group = nil
        case let .drawer(id):
            selectedDrawer = drawerID(id)
        case let .destination(next):
            surface = next.surface
            selectedWidget = next.widget
            selectedComponent = next.component.flatMap { id in
                snapshot.map { $0.config.island?.components.contains { $0.id == id } == true ? id : nil } ?? id
            }
            selectedDrawer = drawerID(next.drawer)
            group = next.group
        case .style,
             .useStyle,
             .leave:
            return
        }
        syncRoute()
    }

    private func drawerID(_ id: String?) -> String? {
        guard let ids = snapshot?.config.drawers.map(\.id) else { return id }
        return id.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }
}

extension ShellDesktopEditor {
    struct StyleCard: Identifiable, Equatable {
        let name: String
        let title: String
        let summary: String
        let active: Bool

        var id: String {
            name
        }
    }

    enum Scope: Equatable {
        case active
        case previewing(active: String)
    }

    enum Surface: Equatable {
        case bar
        case island
        case drawers
    }

    struct Destination: Equatable {
        var surface: Surface
        var widget: String?
        var component: String?
        var group: String?
        var drawer: String?
    }

    enum Transition: Equatable {
        case style(String)
        case widget(String?)
        case surface(Surface)
        case component(String?)
        case drawer(String?)
        case destination(Destination)
        case useStyle
        case leave(SettingsRoute?)

        var selection: Bool {
            switch self {
            case .widget,
                 .surface,
                 .component,
                 .drawer,
                 .destination: true
            case .style,
                 .useStyle,
                 .leave: false
            }
        }
    }

    enum Resolution {
        case save
        case discard
        case cancel
    }
}
