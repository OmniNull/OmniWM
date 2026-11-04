// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct NetworkPermissionsPage: Equatable {
    static let widgetsAnchor = "Widgets"
    static let programsAnchor = "Programs"
    static let servicesAnchor = "Built-in Services"

    enum HostState: Equatable {
        case notAsked
        case allowed
        case denied
        case allowedByOrganization
        case blockedByOrganization
    }

    enum ProgramState: Equatable {
        case notAsked
        case needsApproval(ShellProviderApproval)
        case allowed(ShellProviderApproval)
        case denied
        case blockedByOrganization
    }

    struct Host: Equatable, Identifiable {
        let name: String
        let declaredByShellConfig: Bool
        let state: HostState

        var id: String {
            name
        }

        var decision: ShellPermissionDecisions.HostDecision? {
            switch state {
            case .allowed: .allowed
            case .denied: .denied
            case .notAsked,
                 .allowedByOrganization,
                 .blockedByOrganization: nil
            }
        }
    }

    struct Widget: Equatable, Identifiable {
        let principal: ShellWidgetPrincipal
        let title: String
        let purpose: String?
        let hosts: [Host]

        var anchor: String {
            NetworkPermissionsPage.anchor(principal.role, principal.name)
        }

        var id: String {
            anchor + ":" + principal.source
        }
    }

    struct Program: Equatable, Identifiable {
        let anchor: String
        let key: ShellProviderApproval.Key
        let title: String
        let state: ProgramState

        var id: String {
            ([anchor, key.principal.source] + key.command).joined(separator: "\n")
        }
    }

    let widgets: [Widget]
    let programs: [Program]

    static func anchor(_ role: ShellWidgetPrincipal.Role, _ name: String) -> String {
        "\(role.rawValue):\(name)"
    }

    init(
        config: ShellConfig,
        schemas: [String: ShellRootSettings],
        catalog: ShellConfigurationCatalog?,
        apps: [ShellComponentDescriptor],
        permissions: ShellNetworkPermissions.Snapshot,
        pending: [ShellPermissionPrompts.Request]
    ) {
        let installed = catalog?.entries.compactMap(\.descriptor) ?? []
        let installedPrincipals = Set(installed.map(\.principal))
        let descriptors = installed + apps
        let instances = config.island?.components ?? []
        var widgets = schemas.values.filter { !$0.network.isEmpty }.map { schema in
            let principal = ShellWidgetPrincipal(
                role: schema.widget == config.island?.root ? .root : .bar, name: schema.widget, source: schema.source
            )
            return Widget(
                principal: principal, title: ShellBarLayout.title(of: schema.widget), purpose: schema.purpose,
                hosts: Self.hosts(declared: schema.network, extended: [], for: principal, permissions)
            )
        }
        for (principal, versions) in Dictionary(grouping: descriptors, by: \.principal) {
            let descriptor = versions[0]
            let extended = !installedPrincipals.contains(principal) ? [] : instances
                .filter { $0.widget == descriptor.widget }
                .flatMap { $0.capabilities?.network ?? [] }
            let declared = versions.flatMap(\.capabilities.network)
            guard !declared.isEmpty || !extended.isEmpty else { continue }
            widgets.append(Widget(
                principal: principal, title: descriptor.title, purpose: descriptor.capabilities.purpose,
                hosts: Self.hosts(declared: declared, extended: extended, for: principal, permissions)
            ))
        }
        self.widgets = widgets.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        let widgetAnchors = Set(self.widgets.map(\.anchor))
        var listedPrograms: Set<ShellProviderApproval.Key> = []
        programs = descriptors.compactMap { descriptor in
            guard descriptor.capabilities.provider, let command = descriptor.providerCommand else { return nil }
            let key = ShellProviderApproval.Key(principal: descriptor.principal, command: command)
            guard listedPrograms.insert(key).inserted else { return nil }
            let anchor = Self.anchor(.component, descriptor.widget)
            return Program(
                anchor: widgetAnchors.contains(anchor) ? "program." + anchor : anchor, key: key,
                title: descriptor.title,
                state: Self.state(of: key, permissions, pending: pending)
            )
        }
    }

    private static func hosts(
        declared: [String],
        extended: [String],
        for principal: ShellWidgetPrincipal,
        _ permissions: ShellNetworkPermissions.Snapshot
    ) -> [Host] {
        let declared = Set(declared.map(ShellHTTPPolicy.canonicalHost))
        return declared.union(extended.map(ShellHTTPPolicy.canonicalHost)).sorted().map { host in
            let state: HostState = switch permissions.decide(host, for: principal) {
            case .blocked: .blockedByOrganization
            case .denied: .denied
            case .notApproved: .notAsked
            case .allowed: permissions.widgets[principal]?.allowed.contains(host) == true
                ? .allowed : .allowedByOrganization
            }
            return Host(name: host, declaredByShellConfig: !declared.contains(host), state: state)
        }
    }

    private static func state(
        of key: ShellProviderApproval.Key,
        _ permissions: ShellNetworkPermissions.Snapshot,
        pending: [ShellPermissionPrompts.Request]
    ) -> ProgramState {
        guard permissions.managed.providersAllowed else { return .blockedByOrganization }
        for case let .program(approval) in pending where approval.key == key {
            return .needsApproval(approval)
        }
        guard let stored = permissions.programs[key] else { return .notAsked }
        if stored.denied { return .denied }
        guard let digest = stored.sha256 else { return .notAsked }
        return .allowed(ShellProviderApproval(principal: key.principal, command: key.command, sha256: digest))
    }
}
