// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct NetworkPermissionsSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Environment(SettingsNavigationModel.self) private var navigation
    @State private var problem: String?
    @State private var loaded = false

    private var configuration: ShellConfigurationCoordinator {
        controller.workspaceBarManager.shellConfiguration
    }

    var body: some View {
        let decisions = settings.shellPermissions.decisions
        let permissions = controller.workspaceBarManager.shellPermissions.snapshot
        let page = NetworkPermissionsPage(
            config: configuration.config, schemas: configuration.widgetSchemas, catalog: configuration.catalog,
            apps: controller.shellAppWindowManager.permissionDescriptors,
            permissions: permissions, pending: controller.workspaceBarManager.shellPermissionPrompts?.pending ?? []
        )
        ScrollViewReader { proxy in
            Form {
                if let error = configuration.metadataError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !permissions.managed.invalidKeys.isEmpty {
                    policyErrorSection(permissions.managed.invalidKeys)
                }
                widgetsSection(page.widgets)
                ForEach(page.widgets) { widget in
                    NetworkPermissionsWidgetSection(widget: widget, permissions: settings.shellPermissions)
                        .id(widget.anchor)
                }
                programsSection(page.programs, managed: permissions.managed)
                servicesSection(decisions.services, permissions: permissions)
            }
            .formStyle(.grouped)
            .onChange(of: page.widgets.map(\.anchor) + page.programs.map(\.anchor), initial: true) { _, anchors in
                guard let anchor = navigation.route.anchor, anchors.contains(anchor) else { return }
                proxy.scrollTo(anchor, anchor: .top)
                navigation.reflect(SettingsRoute(section: .network))
            }
        }
        .task {
            do { try await configuration.ensureLoaded() }
            catch { problem = error.localizedDescription }
            loaded = true
        }
        .shellSettingsError($problem, title: "Unable to Refresh Shell Settings")
    }

    private func policyErrorSection(_ keys: [ShellManagedPolicy.Key]) -> some View {
        let names = keys.map(\.rawValue).formatted(.list(type: .and))
        return Section {
            Label(
                String(
                    localized: "Your organization’s policy for OmniWM has invalid values for \(names). OmniWM applies the most restrictive setting until the policy is fixed."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
        }
    }

    private func widgetsSection(_ widgets: [NetworkPermissionsPage.Widget]) -> some View {
        Section {
            if widgets.isEmpty, !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if widgets.isEmpty, configuration.metadataError == nil {
                SettingsCaption(localized: "No installed widget declares a network server.")
            } else {
                SettingsCaption(
                    localized: "Widgets can reach only the servers they declare. OmniWM asks the first time a widget connects to a server you haven’t decided on. Changes take effect on the widget’s next request."
                )
            }
        } header: {
            Text("Widgets")
        }
        .id(NetworkPermissionsPage.widgetsAnchor)
    }

    private func programsSection(
        _ programs: [NetworkPermissionsPage.Program],
        managed: ShellManagedPolicy
    ) -> some View {
        Section("Programs") {
            ForEach(programs) { program in
                NetworkPermissionsProgramRow(program: program, permissions: settings.shellPermissions)
                    .id(program.anchor)
            }
            if programs.isEmpty, loaded, configuration.metadataError == nil {
                SettingsCaption(localized: "No installed widget includes a native program.")
            }
            if !managed.providersAllowed {
                ManagedSettingLabel()
            }
            SettingsCaption(
                localized: "A program runs as you, with full access to your files and network. OmniWM asks before it first runs and again whenever it changes."
            )
        }
        .id(NetworkPermissionsPage.programsAnchor)
    }

    private func servicesSection(
        _ services: ShellPermissionDecisions.Services,
        permissions: ShellNetworkPermissions.Snapshot
    ) -> some View {
        Section("Built-in Services") {
            serviceToggle(.weather, enabled: services.weather, permissions: permissions) {
                Text("Weather")
                Text(
                    "Sends the city or coordinates you set for weather to \(ShellBuiltInService.weather.hosts.sorted().formatted(.list(type: .and)))."
                )
            }
            serviceToggle(.lyrics, enabled: services.lyrics, permissions: permissions) {
                Text("Lyrics")
                Text(
                    "Sends the playing track’s title, artist, album, and length to \(ShellBuiltInService.lyrics.hosts.sorted().formatted(.list(type: .and))) to find synced lyrics."
                )
            }
            if ShellBuiltInService.allCases.contains(where: { permissions.access($0) == .blocked }) {
                ManagedSettingLabel()
            }
        }
        .id(NetworkPermissionsPage.servicesAnchor)
    }

    private func serviceToggle(
        _ service: ShellBuiltInService,
        enabled: Bool,
        permissions: ShellNetworkPermissions.Snapshot,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let blocked = permissions.access(service) == .blocked
        return Toggle(isOn: Binding(
            get: { enabled && !blocked },
            set: { settings.shellPermissions.setServiceEnabled($0, service: service) }
        ), label: label)
            .disabled(blocked)
    }
}

private struct NetworkPermissionsWidgetSection: View {
    let widget: NetworkPermissionsPage.Widget
    let permissions: ShellPermissionSettings

    var body: some View {
        Section {
            Text(verbatim: widget.principal.source)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let purpose = widget.purpose {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The widget’s own description").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: purpose)
                }
            }
            ForEach(widget.hosts) { host in
                LabeledContent {
                    if host.state == .blockedByOrganization {
                        Label("Blocked", systemImage: "lock.fill").foregroundStyle(.secondary)
                    } else {
                        Picker("Access", selection: Binding(
                            get: { host.decision },
                            set: { permissions.setNetwork($0, hosts: [host.name], for: widget.principal) }
                        )) {
                            undecided(host).tag(ShellPermissionDecisions.HostDecision?.none)
                            Text("Allowed").tag(ShellPermissionDecisions.HostDecision?.some(.allowed))
                            Text("Denied").tag(ShellPermissionDecisions.HostDecision?.some(.denied))
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } label: {
                    Text(verbatim: host.name).font(.body.monospaced())
                    if host.declaredByShellConfig {
                        Text("Declared by your shell.toml")
                    }
                }
            }
            if widget.hosts.contains(where: { $0.state == .blockedByOrganization }) {
                ManagedSettingLabel()
            }
            if widget.hosts.contains(where: { $0.decision != nil }) {
                Button("Reset") {
                    permissions.setNetwork(nil, hosts: widget.hosts.map(\.name), for: widget.principal)
                }
            }
        } header: {
            Text(verbatim: widget.title)
        }
    }

    private func undecided(_ host: NetworkPermissionsPage.Host) -> Text {
        host.state == .allowedByOrganization ? Text("Allowed by your organization") : Text("Not asked")
    }
}

private struct NetworkPermissionsProgramRow: View {
    let program: NetworkPermissionsPage.Program
    let permissions: ShellPermissionSettings

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch program.state {
                case .notAsked:
                    Text("Not asked").foregroundStyle(.secondary)
                case let .needsApproval(approval):
                    Text("Needs approval").foregroundStyle(.secondary)
                    Button("Deny") { permissions.setProgram(.denied, for: approval) }
                    Button("Allow") { permissions.setProgram(.allowed, for: approval) }
                case let .allowed(approval):
                    Text("Allowed").foregroundStyle(.secondary)
                    Button("Revoke") { permissions.setProgram(.denied, for: approval) }
                case .denied:
                    Text("Denied").foregroundStyle(.secondary)
                    Button("Reset") { permissions.resetProgram(program.key) }
                case .blockedByOrganization:
                    Label("Blocked", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(verbatim: program.title)
            Text(verbatim: program.key.command.joined(separator: " ")).font(.caption.monospaced())
            Text(verbatim: program.key.principal.source).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

private struct ManagedSettingLabel: View {
    var body: some View {
        Label("This setting is managed by your organization.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
