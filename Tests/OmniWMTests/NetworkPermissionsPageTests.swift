// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class NetworkPermissionsPageTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/shell/lake/widgets", isDirectory: true)

    private func schema(_ widget: String, network: [String], purpose: String? = nil) -> ShellRootSettings {
        ShellRootSettings(
            widget: widget, options: [:], network: network, purpose: purpose,
            folder: folder.appendingPathComponent(widget), source: "/shell/lake/widgets/" + widget
        )
    }

    private func descriptor(
        _ widget: String,
        network: [String] = [],
        provider: [String]? = nil,
        purpose: String? = nil
    ) -> ShellComponentDescriptor {
        ShellComponentDescriptor(
            widget: widget, title: widget.capitalized, icon: "circle", views: [], uses: [], options: [:],
            capabilities: ShellComponentCapabilities(network: network, provider: provider != nil, purpose: purpose),
            providerCommand: provider, folder: folder.appendingPathComponent(widget)
        )
    }

    private func catalog(_ descriptors: [ShellComponentDescriptor]) -> ShellConfigurationCatalog {
        ShellConfigurationCatalog(
            directories: [], root: "lake",
            entries: descriptors.map { .init(widget: $0.widget, sources: [$0.folder], descriptor: $0, error: nil) },
            settings: nil, bytes: [], schema: []
        )
    }

    private func page(
        config: ShellConfig = ShellConfig(),
        schemas: [ShellRootSettings] = [],
        descriptors: [ShellComponentDescriptor] = [],
        decisions: ShellPermissionDecisions = ShellPermissionDecisions(),
        managed: ShellManagedPolicy = ShellManagedPolicy(),
        pending: [ShellPermissionPrompts.Request] = []
    ) -> NetworkPermissionsPage {
        NetworkPermissionsPage(
            config: config,
            schemas: Dictionary(uniqueKeysWithValues: schemas.map { ($0.widget, $0) }),
            catalog: catalog(descriptors),
            permissions: ShellNetworkPermissions(decisions: decisions, managed: managed).snapshot,
            pending: pending
        )
    }

    func testWidgetsListEveryDeclaringPrincipalWithItsHostStates() {
        var config = ShellConfig()
        var island = ShellIslandConfig(root: "lake")
        var instance = ShellComponentInstance(id: "ci", widget: "ci-status")
        instance.capabilities = ShellComponentCapabilities(network: ["git.example.com"])
        island.components = [instance]
        config.island = island
        let ci = descriptor("ci-status", network: ["API.GitHub.com."], purpose: "Shows build status")
        let weather = schema("weather", network: ["blocked.example", "api.example", "org.example"], purpose: "Forecast")
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["api.example"], for: weather.principal(.bar))
        decisions.setNetwork(.denied, hosts: ["git.example.com"], for: ci.principal)
        var managed = ShellManagedPolicy()
        managed.allowedHosts = ["org.example"]
        managed.blockedHosts = ["blocked.example"]

        let page = self.page(
            config: config,
            schemas: [weather, schema("lake", network: ["root.example"]), schema("clock", network: [])],
            descriptors: [ci, descriptor("battery")],
            decisions: decisions,
            managed: managed
        )

        XCTAssertEqual(page.widgets.map(\.id), ["component:ci-status", "root:lake", "bar:weather"])
        XCTAssertEqual(page.widgets[0].purpose, "Shows build status")
        XCTAssertEqual(page.widgets[0].hosts, [
            .init(name: "api.github.com", declaredByShellConfig: false, state: .notAsked),
            .init(name: "git.example.com", declaredByShellConfig: true, state: .denied)
        ])
        XCTAssertEqual(page.widgets[1].principal, ShellWidgetPrincipal(
            role: .root, name: "lake", source: "/shell/lake/widgets/lake"
        ))
        XCTAssertEqual(page.widgets[2].purpose, "Forecast")
        XCTAssertEqual(page.widgets[2].hosts.map(\.state), [.allowed, .blockedByOrganization, .allowedByOrganization])
        XCTAssertEqual(page.widgets[2].hosts.map(\.decision), [.allowed, nil, nil])
    }

    func testAUserDenyWinsOverAnOrganizationPreapproval() {
        let weather = schema("weather", network: ["org.example"])
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.denied, hosts: ["org.example"], for: weather.principal(.bar))
        var managed = ShellManagedPolicy()
        managed.allowedHosts = ["org.example"]
        XCTAssertEqual(
            page(schemas: [weather], decisions: decisions, managed: managed).widgets[0].hosts.map(\.state),
            [.denied]
        )
    }

    func testProgramsReportTrustStateAndKeepUniqueAnchors() {
        let converter = descriptor("converter", provider: ["provider.pl"])
        let mixed = descriptor("mixed", network: ["api.example"], provider: ["run.sh"])
        let idle = descriptor("idle", provider: ["idle.sh"])
        let pending = ShellProviderApproval(principal: converter.principal, command: ["provider.pl"], sha256: "new")
        var decisions = ShellPermissionDecisions()
        decisions.setProgram(.allowed, for: pending.withDigest("old"))
        decisions.setProgram(.allowed, for: ShellProviderApproval(
            principal: mixed.principal, command: ["run.sh"], sha256: "aa"
        ))
        decisions.setProgram(.denied, for: ShellProviderApproval(
            principal: idle.principal, command: ["idle.sh"], sha256: "bb"
        ))
        let descriptors = [converter, mixed, idle, descriptor("plain")]

        let page = self.page(descriptors: descriptors, decisions: decisions, pending: [.program(pending)])
        XCTAssertEqual(page.programs.map(\.id), ["component:converter", "program.component:mixed", "component:idle"])
        XCTAssertEqual(page.programs.map(\.state), [
            .needsApproval(pending),
            .allowed(ShellProviderApproval(principal: mixed.principal, command: ["run.sh"], sha256: "aa")),
            .denied
        ])
        XCTAssertEqual(page.widgets.map(\.id), ["component:mixed"])

        var managed = ShellManagedPolicy()
        managed.providersAllowed = false
        XCTAssertEqual(
            self.page(descriptors: descriptors, decisions: decisions, managed: managed, pending: [.program(pending)])
                .programs.map(\.state),
            [.blockedByOrganization, .blockedByOrganization, .blockedByOrganization]
        )
        XCTAssertEqual(self.page(descriptors: [converter]).programs.map(\.state), [.notAsked])
    }

    func testAManagedOnlyRefreshInvalidatesThePageAndTheNextPageShowsTheManagedStates() {
        let converter = descriptor("converter", network: ["api.example"], provider: ["provider.pl"])
        let approved = ShellProviderApproval(principal: converter.principal, command: ["provider.pl"], sha256: "aa")
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["api.example"], for: converter.principal)
        decisions.setProgram(.allowed, for: approved)
        let permissions = ShellNetworkPermissions(decisions: decisions)
        let installed = catalog([converter])
        let page = {
            NetworkPermissionsPage(
                config: ShellConfig(), schemas: [:], catalog: installed, permissions: permissions.snapshot, pending: []
            )
        }
        let invalidations = Mutex(0)
        let before = withObservationTracking {
            page()
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        XCTAssertEqual(before.widgets.map { $0.hosts.map(\.state) }, [[.allowed]])
        XCTAssertEqual(before.programs.map(\.state), [.allowed(approved)])
        XCTAssertFalse(permissions.update(decisions: decisions))
        XCTAssertEqual(invalidations.withLock { $0 }, 0)

        var managed = ShellManagedPolicy()
        managed.blockedHosts = ["api.example"]
        managed.providersAllowed = false
        managed.blockedServices = [.weather]
        managed.invalidKeys = [.blockedServices]
        XCTAssertTrue(permissions.update(managed: managed))
        XCTAssertEqual(invalidations.withLock { $0 }, 1)
        let after = page()
        XCTAssertEqual(after.widgets.map { $0.hosts.map(\.state) }, [[.blockedByOrganization]])
        XCTAssertEqual(after.programs.map(\.state), [.blockedByOrganization])
        XCTAssertEqual(permissions.snapshot.access(.weather), .blocked)
        XCTAssertEqual(permissions.snapshot.managed.invalidKeys, [.blockedServices])
    }

    func testResetProgramRemovesOnlyThatProgramsDecision() {
        let settings = ShellPermissionSettings()
        let principal = descriptor("converter", provider: ["provider.pl"]).principal
        let first = ShellProviderApproval(principal: principal, command: ["provider.pl"], sha256: "aa")
        let second = ShellProviderApproval(principal: principal, command: ["other.pl"], sha256: "bb")
        settings.setProgram(.denied, for: first)
        settings.setProgram(.allowed, for: second)
        settings.resetProgram(first.key)
        XCTAssertEqual(settings.decisions.programs.map(\.command), [["other.pl"]])
    }
}

private extension ShellRootSettings {
    func principal(_ role: ShellWidgetPrincipal.Role) -> ShellWidgetPrincipal {
        ShellWidgetPrincipal(role: role, name: widget, source: source)
    }
}

private extension ShellProviderApproval {
    func withDigest(_ digest: String) -> ShellProviderApproval {
        ShellProviderApproval(principal: principal, command: command, sha256: digest)
    }
}
