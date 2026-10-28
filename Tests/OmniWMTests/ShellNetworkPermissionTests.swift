// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreFoundation
import Foundation
@testable import OmniWM
import TOML
import XCTest

final class ShellNetworkPermissionTests: XCTestCase {
    private struct ManagedPreferences: ShellManagedPreferenceReader {
        let values: [String: Any]

        func forcedValue(_ key: String) -> CFPropertyList? {
            values[key].map { $0 as AnyObject }
        }
    }

    private var root: URL!
    private let principal = ShellWidgetPrincipal(role: .component, name: "ci", source: "/shell/widgets/ci")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDecisionPrecedenceAcrossFloorManagedAndUserSources() throws {
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["user.example", "blocked.example", "both.example"], for: principal)
        decisions.setNetwork(.denied, hosts: ["denied.example", "managed-denied.example"], for: principal)
        var managed = ShellManagedPolicy()
        managed.allowedHosts = ["managed.example", "managed-denied.example", "both.example", "undeclared.example"]
        managed.blockedHosts = ["blocked.example"]
        let permissions = ShellNetworkPermissions(decisions: decisions, managed: managed)
        let declared: Set<String> = [
            "user.example", "blocked.example", "both.example", "denied.example", "managed-denied.example",
            "managed.example", "pending.example", "localhost"
        ]
        let policy = ShellHTTPPolicy.widget(principal, hosts: declared, permissions: permissions)
        let cases: [String: ShellNetworkDecision] = [
            "https://undeclared.example/": .denied,
            "http://user.example/": .denied,
            "https://name:secret@user.example/": .denied,
            "https://blocked.example/": .blocked,
            "https://denied.example/": .denied,
            "https://managed-denied.example/": .denied,
            "https://managed.example/": .allowed,
            "https://both.example/": .allowed,
            "https://USER.example./path": .allowed,
            "https://pending.example/": .notApproved,
            "http://localhost:8080/": .notApproved
        ]
        for (url, expected) in cases {
            XCTAssertEqual(policy.decide(try XCTUnwrap(URL(string: url))), expected, url)
        }
        let moved = ShellWidgetPrincipal(role: .component, name: "ci", source: "/elsewhere/widgets/ci")
        XCTAssertEqual(
            ShellHTTPPolicy.widget(moved, hosts: declared, permissions: permissions)
                .decide(try XCTUnwrap(URL(string: "https://user.example/"))),
            .notApproved
        )
        XCTAssertEqual(ShellHTTPPolicy.denied.decide(try XCTUnwrap(URL(string: "https://user.example/"))), .denied)

        managed.onlyAllowedHosts = true
        XCTAssertTrue(permissions.update(managed: managed))
        let allowlisted: [String: ShellNetworkDecision] = [
            "https://user.example/": .blocked,
            "https://denied.example/": .blocked,
            "https://pending.example/": .blocked,
            "https://managed-denied.example/": .denied,
            "https://managed.example/": .allowed,
            "https://undeclared.example/": .denied
        ]
        for (url, expected) in allowlisted {
            XCTAssertEqual(policy.decide(try XCTUnwrap(URL(string: url))), expected, url)
        }
        XCTAssertNil(ShellNetworkDecision.allowed.failure)
        XCTAssertEqual(ShellNetworkDecision.denied.failure, ShellHTTPFailure("network_denied"))
        XCTAssertEqual(ShellNetworkDecision.blocked.failure, ShellHTTPFailure("network_blocked"))
        XCTAssertEqual(ShellNetworkDecision.notApproved.failure, ShellHTTPFailure("network_not_approved"))
    }

    func testPrincipalFollowsResolvedSourceAcrossOverrideRetargetAndUpdate() throws {
        let user = root.appendingPathComponent("shell")
        let style = user.appendingPathComponent("default")
        let directories = [user, style]
        try component("ci", manifest: "views = ['compact']", in: style)
        let bundled = try ShellComponentCatalog.load("ci", directories: directories).principal
        XCTAssertEqual(bundled, ShellWidgetPrincipal(
            role: .component, name: "ci", folder: style.appendingPathComponent("widgets/ci")
        ))
        try component("ci", manifest: "views = ['compact']\ncapabilities = { network = ['new.example'] }", in: style)
        XCTAssertEqual(try ShellComponentCatalog.load("ci", directories: directories).principal, bundled)

        try component("ci", manifest: "views = ['compact']", in: user)
        let overridden = try ShellComponentCatalog.load("ci", directories: directories).principal
        XCTAssertNotEqual(overridden, bundled)
        XCTAssertEqual(overridden.name, "ci")

        let link = user.appendingPathComponent("widgets/ci")
        try FileManager.default.removeItem(at: link)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try component("ci", manifest: "views = ['compact']", in: first)
        try component("ci", manifest: "views = ['compact']", in: second)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: first.appendingPathComponent("widgets/ci")
        )
        let linked = try ShellComponentCatalog.load("ci", directories: directories).principal
        XCTAssertEqual(linked, ShellWidgetPrincipal(
            role: .component, name: "ci", folder: first.appendingPathComponent("widgets/ci")
        ))
        XCTAssertNotEqual(linked.source, link.standardizedFileURL.path)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: second.appendingPathComponent("widgets/ci")
        )
        let retargeted = try ShellComponentCatalog.load("ci", directories: directories).principal
        XCTAssertNotEqual(retargeted, linked)
        XCTAssertEqual(retargeted, ShellWidgetPrincipal(
            role: .component, name: "ci", folder: second.appendingPathComponent("widgets/ci")
        ))

        let source = user.appendingPathComponent("lake/widgets/lake/init.luau")
        let input = { (components: [ShellComponentInstance]?) in
            ShellWidgetSourceLoader.Input(
                name: "lake", shellDirectory: user, sourceURL: source, directories: directories, profile: "lake",
                components: components
            ).principal
        }
        let folder = source.deletingLastPathComponent()
        XCTAssertEqual(input([]), ShellWidgetPrincipal(role: .root, name: "lake", folder: folder))
        XCTAssertEqual(input(nil), ShellWidgetPrincipal(role: .bar, name: "lake", folder: folder))
    }

    func testDeclaredPoliciesKeepInstanceExtensionsScopedAndFollowTheCurrentConfiguration() throws {
        let descriptor = ShellComponentDescriptor(
            widget: "ci", title: "CI", icon: "", views: [], uses: [], options: [:],
            capabilities: .init(network: ["api.example"]), providerCommand: nil,
            folder: URL(fileURLWithPath: "/shell/widgets/ci")
        )
        var source = ShellWidgetSource(chunk: "", main: "", modules: [])
        source.componentDescriptors = [descriptor]
        let jobs = ShellComponentInstance(id: "jobs", widget: "ci", capabilities: .init(network: ["jobs.example"]))
        let runs = ShellComponentInstance(id: "runs", widget: "ci", capabilities: .init(network: ["runs.example"]))
        let permissions = ShellNetworkPermissions(
            allowing: ["api.example", "jobs.example", "runs.example"],
            for: descriptor.principal
        )
        let declarations = ShellHTTPDeclarations()
        declarations.update(source, components: [jobs, runs], permissions: permissions)
        let jobsPolicy = ShellHTTPPolicy.declared(declarations, owner: "jobs")
        let runsPolicy = ShellHTTPPolicy.declared(declarations, owner: "runs")
        let decide = { (policy: ShellHTTPPolicy, host: String) in
            policy.decide(try XCTUnwrap(URL(string: "https://\(host)/path")))
        }
        XCTAssertEqual(try decide(jobsPolicy, "api.example"), .allowed)
        XCTAssertEqual(try decide(jobsPolicy, "jobs.example"), .allowed)
        XCTAssertEqual(try decide(jobsPolicy, "runs.example"), .denied)
        XCTAssertEqual(try decide(runsPolicy, "runs.example"), .allowed)
        XCTAssertEqual(try decide(runsPolicy, "jobs.example"), .denied)
        XCTAssertEqual(try decide(.declared(declarations, owner: nil), "api.example"), .denied)
        XCTAssertEqual(try decide(.declared(declarations, owner: ""), "api.example"), .denied)

        source.network = ["api.example"]
        source.principal = ShellWidgetPrincipal(role: .root, name: "island", source: "/shell/widgets/island")
        declarations.update(source, components: [runs], permissions: permissions)
        XCTAssertEqual(try decide(jobsPolicy, "jobs.example"), .denied)
        XCTAssertEqual(try decide(runsPolicy, "runs.example"), .allowed)
        XCTAssertEqual(try decide(.declared(declarations, owner: nil), "api.example"), .notApproved)
    }

    func testUpdateDeclaringNewHostKeepsEarlierDecisionsAndLeavesOnlyNewHostUndecided() {
        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["a.example"], for: principal)
        decisions.setNetwork(.denied, hosts: ["b.example"], for: principal)
        let permissions = ShellNetworkPermissions(decisions: decisions)
        XCTAssertEqual(permissions.undecided(["a.example", "b.example"], for: principal).hosts, [])
        XCTAssertEqual(
            permissions.undecided(["a.example", "b.example", "c.example"], for: principal).hosts,
            ["c.example"]
        )
        XCTAssertEqual(permissions.decide("a.example", for: principal), .allowed)
        XCTAssertEqual(permissions.decide("b.example", for: principal), .denied)
        XCTAssertEqual(permissions.decide("c.example", for: principal), .notApproved)
        XCTAssertFalse(permissions.update(decisions: decisions))
        XCTAssertEqual(permissions.snapshot.revision, 0)

        var updated = decisions
        updated.setNetwork(.allowed, hosts: ["C.example."], for: principal)
        XCTAssertEqual(updated.widgets, [.init(
            role: .component, name: "ci", source: "/shell/widgets/ci",
            allowed: ["a.example", "c.example"], denied: ["b.example"]
        )])
        XCTAssertTrue(permissions.update(decisions: updated))
        XCTAssertEqual(permissions.snapshot.revision, 1)
        XCTAssertEqual(permissions.undecided(["a.example", "b.example", "c.example"], for: principal).hosts, [])
        updated.setNetwork(.denied, hosts: ["a.example"], for: principal)
        XCTAssertEqual(updated.widgets.first?.allowed, ["c.example"])
        XCTAssertEqual(updated.widgets.first?.denied, ["a.example", "b.example"])
        updated.setNetwork(nil, hosts: ["a.example", "b.example", "c.example"], for: principal)
        XCTAssertTrue(updated.widgets.isEmpty)
    }

    func testShellPermissionsRoundTripThroughSettingsTOMLWithDefaults() throws {
        var export = SettingsExport.defaults()
        XCTAssertEqual(export.shellPermissions, ShellPermissionDecisions())
        XCTAssertTrue(export.shellPermissions.services.weather)
        XCTAssertTrue(export.shellPermissions.services.lyrics)
        export.shellPermissions = ShellPermissionDecisions(
            widgets: [.init(
                role: .component, name: "ci-status", source: "/shell/lake/widgets/ci-status",
                allowed: ["api.github.com"], denied: ["other.example"]
            )],
            programs: [
                .init(
                    name: "converter", source: "/shell/lake/widgets/converter", command: ["provider.pl", "--fast"],
                    sha256: String(repeating: "a", count: 64)
                ),
                .init(name: "other", source: "/shell/widgets/other", command: ["run"], denied: true)
            ],
            services: .init(weather: true, lyrics: false)
        )
        let data = try SettingsTOMLCodec.encode(export)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        XCTAssertTrue(SettingsTOMLCodec.unknownKeyPaths(in: data).isEmpty)

        var tree = try TOMLDecoder().decode([String: TOMLNode].self, from: SettingsTOMLCodec.encode(.defaults()))
        tree.removeValue(forKey: "shellPermissions")
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)).shellPermissions,
            ShellPermissionDecisions()
        )
        tree["shellPermissions"] = .table([
            "widgets": .array([.table([
                "role": .string("bar"), "name": .string("clock"), "source": .string("/shell/widgets/clock")
            ])]),
            "programs": .array([.table([
                "name": .string("tool"), "source": .string("/shell/widgets/tool"),
                "command": .array([.string("tool.sh")])
            ])]),
            "services": .table(["weather": .boolean(false)])
        ])
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)).shellPermissions,
            ShellPermissionDecisions(
                widgets: [.init(role: .bar, name: "clock", source: "/shell/widgets/clock")],
                programs: [.init(name: "tool", source: "/shell/widgets/tool", command: ["tool.sh"])],
                services: .init(weather: false, lyrics: true)
            )
        )
        tree["shellPermissions"] = .table(["widgets": .array([.table([
            "role": .string("island"), "name": .string("clock"), "source": .string("/shell/widgets/clock")
        ])])])
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)))
    }

    @MainActor
    func testSettingsStoreRecordsAndResetsHostDecisionsAndPersistsThem() throws {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: root, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: root, deferSaves: false)
        )
        var changes = 0
        settings.shellPermissions.onDecisionsChange = { changes += 1 }
        settings.shellPermissions.setNetwork(.allowed, hosts: ["API.example."], for: principal)
        settings.shellPermissions.setNetwork(.allowed, hosts: ["api.example"], for: principal)
        XCTAssertEqual(changes, 1)
        let allowed = ShellPermissionDecisions.Widget(
            role: .component, name: "ci", source: "/shell/widgets/ci", allowed: ["api.example"]
        )
        XCTAssertEqual(
            try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL)).shellPermissions.widgets,
            [allowed]
        )
        settings.shellPermissions.setNetwork(nil, hosts: ["api.example"], for: principal)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(
            try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL)).shellPermissions.widgets.isEmpty
        )
        var export = settings.toExport()
        export.shellPermissions.widgets = [allowed]
        settings.applyExport(export)
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(settings.shellPermissions.decisions.widgets, [allowed])
    }

    func testManagedPolicyReadsOnlyForcedValuesAndFailsClosedOnInvalidOnes() {
        XCTAssertEqual(ShellManagedPolicy(reading: ManagedPreferences(values: [:])), ShellManagedPolicy())
        XCTAssertNil(ShellAppManagedPreferences(domain: "com.barut.OmniWM.tests.\(UUID().uuidString)")
            .forcedValue(ShellManagedPolicy.Key.allowedHosts.rawValue))
        let valid = ShellManagedPolicy(reading: ManagedPreferences(values: [
            "ShellNetworkAllowedHosts": ["API.Example.", "lrclib.net"],
            "ShellNetworkBlockedHosts": ["bad.example", "127.0.0.1", "2001:DB8::1"],
            "ShellNetworkOnlyAllowedHosts": true,
            "ShellProvidersAllowed": false,
            "ShellBlockedServices": ["lyrics"],
            "Unrelated": 1
        ]))
        XCTAssertEqual(valid.allowedHosts, ["api.example", "lrclib.net"])
        XCTAssertEqual(valid.blockedHosts, ["bad.example", "127.0.0.1", "2001:db8::1"])
        XCTAssertFalse(valid.blocksAllHosts)
        XCTAssertTrue(valid.onlyAllowedHosts)
        XCTAssertFalse(valid.providersAllowed)
        XCTAssertEqual(valid.blockedServices, [.lyrics])
        XCTAssertTrue(valid.invalidKeys.isEmpty)
        XCTAssertTrue(valid.blocks("other.example"))
        XCTAssertFalse(valid.blocks("api.example"))

        var invalid: [(ShellManagedPolicy.Key, Any, (ShellManagedPolicy) -> Bool)] = [
            (.allowedHosts, "api.example", { $0.allowedHosts.isEmpty && !$0.blocks("api.example") }),
            (.allowedHosts, ["api.example", 3] as [Any], { $0.allowedHosts.isEmpty }),
            (.blockedHosts, [""], { $0.blocksAllHosts && $0.blocks("any.example") }),
            (.blockedHosts, false, { $0.blocksAllHosts && $0.blockedHosts.isEmpty }),
            (.onlyAllowedHosts, 1, { $0.onlyAllowedHosts && $0.blocks("any.example") }),
            (.onlyAllowedHosts, "true", { $0.onlyAllowedHosts }),
            (.providersAllowed, 1, { !$0.providersAllowed }),
            (.providersAllowed, ["true"], { !$0.providersAllowed }),
            (.blockedServices, ["weather", "radio"], { $0.blockedServices == Set(ShellBuiltInService.allCases) }),
            (.blockedServices, "lyrics", { $0.blockedServices == Set(ShellBuiltInService.allCases) })
        ]
        for host in ["https://bad.example", " bad.example", "*.corp.example", "bad.example:443", "127.0.0.1:8080"] {
            invalid.append((.allowedHosts, ["api.example", host], { $0.allowedHosts.isEmpty }))
            invalid.append((.blockedHosts, ["ok.example", host], { $0.blocksAllHosts && $0.blocks("any.example") }))
        }
        for (key, value, failedClosed) in invalid {
            let policy = ShellManagedPolicy(reading: ManagedPreferences(values: [key.rawValue: value]))
            XCTAssertEqual(policy.invalidKeys, [key], "\(key) \(value)")
            XCTAssertTrue(failedClosed(policy), "\(key) \(value)")
        }

        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.denied, hosts: ["lrclib.net"], for: principal)
        let permissions = ShellNetworkPermissions(decisions: decisions, managed: valid)
        XCTAssertEqual(permissions.decide("api.example", for: principal), .allowed)
        XCTAssertEqual(permissions.decide("lrclib.net", for: principal), .denied)
        XCTAssertEqual(permissions.decide("bad.example", for: principal), .blocked)
    }

    func testPurposeIsAnOptionalCappedCapabilityOfComponentsAndRootSettingsOnly() throws {
        let shell = root.appendingPathComponent("shell")
        let purpose = String(repeating: "é", count: ShellComponentCatalog.purposeLimit)
        try component("ci", manifest: "views = ['compact']\ncapabilities = { network = ['api.example'] }", in: shell)
        XCTAssertNil(try ShellComponentCatalog.load("ci", directories: [shell]).capabilities.purpose)
        try component("ci", manifest: """
        views = ['compact']
        capabilities = { network = ['api.example'], purpose = '\(purpose)' }
        """, in: shell)
        let descriptor = try ShellComponentCatalog.load("ci", directories: [shell])
        XCTAssertEqual(descriptor.capabilities.purpose, purpose)
        XCTAssertEqual(descriptor.capabilities.network, ["api.example"])
        for manifest in [
            "views = ['compact']\ncapabilities = { purpose = '\(purpose)x' }",
            "views = ['compact']\ncapabilities = { purpose = 3 }",
            "views = ['compact']\npurpose = 'Top-level purpose'"
        ] {
            try component("ci", manifest: manifest, in: shell)
            XCTAssertThrowsError(try ShellComponentCatalog.load("ci", directories: [shell]), manifest)
        }
        XCTAssertThrowsError(try ShellComponentCatalog.instances(from: .array([.table([
            "id": .string("jobs"), "widget": .string("ci"),
            "capabilities": .table(["purpose": .string("Instance purpose")])
        ])])))

        let folder = shell.appendingPathComponent("lake/widgets/lake")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = folder.appendingPathComponent("settings.toml")
        try Data("[capabilities]\nnetwork = ['api.example']\npurpose = 'Shows the weather'\n".utf8).write(to: settings)
        let rootSettings = try ShellRootSettings.load("lake", folder: folder)
        XCTAssertEqual(rootSettings.network, ["api.example"])
        XCTAssertEqual(rootSettings.purpose, "Shows the weather")
        try Data("init".utf8).write(to: folder.appendingPathComponent("init.luau"))
        let source = try ShellWidgetSourceLoader.build(ShellWidgetSourceLoader.Input(
            name: "lake", shellDirectory: shell, sourceURL: folder.appendingPathComponent("init.luau"),
            directories: [shell.appendingPathComponent("lake"), shell], profile: "lake"
        ))
        XCTAssertEqual(source.purpose, "Shows the weather")
        XCTAssertEqual(source.network, ["api.example"])
        XCTAssertEqual(source.principal, ShellWidgetPrincipal(role: .bar, name: "lake", folder: folder))
        try Data("[capabilities]\npurpose = '\(purpose)x'\n".utf8).write(to: settings)
        XCTAssertThrowsError(try ShellRootSettings.load("lake", folder: folder))
    }

    @MainActor
    func testHostRegistryKeysApprovalsByPrincipalAndUndecidedHostsAndDropsDecidedOnes() {
        let permissions = ShellNetworkPermissions()
        let host = ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            permissions: permissions,
            world: { ShellWorldData() },
            vars: { [:] },
            bars: { [:] },
            onLayoutChange: {},
            onCommand: { _, _ in },
            onMenu: { _ in },
            onPreview: { _ in },
            onDrag: { _ in },
            onPopoutChange: {},
            onTitleDemandChange: { _ in }
        )
        let other = ShellWidgetPrincipal(role: .bar, name: "clock", source: "/shell/widgets/clock")
        let island = ShellWidgetHost.WidgetState(
            name: "lake", sourceURL: URL(fileURLWithPath: "/shell/widgets/lake/init.luau")
        )
        let clockWidget = ShellWidgetHost.WidgetState(
            name: other.name, sourceURL: URL(fileURLWithPath: other.source).appendingPathComponent("init.luau")
        )
        var islandSource = ShellWidgetSource(chunk: "", main: "", modules: [])
        islandSource.componentDescriptors = [ShellComponentDescriptor(
            widget: principal.name, title: "CI", icon: "circle", views: [], uses: [], options: [:],
            capabilities: ShellComponentCapabilities(network: ["a.example", "b.example"]),
            providerCommand: nil, folder: URL(fileURLWithPath: principal.source)
        )]
        var clockSource = ShellWidgetSource(chunk: "", main: "", modules: [])
        clockSource.network = ["a.example"]
        host.config.island = ShellIslandConfig(components: [ShellComponentInstance(id: "ci", widget: principal.name)])
        host.widgets = ["lake": island, other.name: clockWidget]
        host.setDeclarations(islandSource, of: island)
        host.setDeclarations(clockSource, of: clockWidget)
        let both = ShellNetworkApproval.Key(principal: principal, hosts: ["a.example", "b.example"])
        let clock = ShellNetworkApproval.Key(principal: other, hosts: ["a.example"])
        host.recordNetworkApprovals([
            ShellNetworkApproval(key: both, purpose: "Earlier"),
            ShellNetworkApproval(key: clock, purpose: nil),
            ShellNetworkApproval(
                key: ShellNetworkApproval.Key(principal: principal, hosts: ["b.example", "a.example"]),
                purpose: "Later"
            )
        ])
        XCTAssertEqual(Set(host.networkApprovals.keys), [both, clock])
        XCTAssertEqual(host.networkApprovals[both]?.purpose, "Later")

        var decisions = ShellPermissionDecisions()
        decisions.setNetwork(.allowed, hosts: ["a.example"], for: principal)
        XCTAssertTrue(permissions.update(decisions: decisions))
        host.permissionsChanged()
        XCTAssertEqual(Set(host.networkApprovals.keys), [clock])
        host.recordNetworkApprovals([ShellNetworkApproval(key: both, purpose: nil)])
        XCTAssertEqual(Set(host.networkApprovals.keys), [clock])
        let remaining = ShellNetworkApproval.Key(principal: principal, hosts: ["b.example"])
        host.recordNetworkApprovals([ShellNetworkApproval(key: remaining, purpose: nil)])
        XCTAssertEqual(Set(host.networkApprovals.keys), [clock, remaining])
    }

    private func component(_ name: String, manifest: String, in layer: URL) throws {
        let folder = layer.appendingPathComponent("widgets/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("component.toml"))
        try Data("return { views = {} }".utf8).write(to: folder.appendingPathComponent("component.luau"))
    }
}
