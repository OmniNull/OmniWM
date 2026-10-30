// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellDisabledComponentApprovalTests: XCTestCase {
    @MainActor
    private final class Presenter {
        var answers: [@MainActor (Bool) -> Void] = []
        var dismissed: [ShellPermissionPrompts.Request] = []
        var onPresent: (() -> Void)?

        func present(
            _ request: ShellPermissionPrompts.Request,
            answer: @escaping @MainActor (Bool) -> Void
        ) -> @MainActor () -> Void {
            answers.append(answer)
            onPresent?()
            return { [weak self] in self?.dismissed.append(request) }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let host: ShellWidgetHost
        let state: ShellWidgetHost.WidgetState
        let package: ShellWidgetPackage
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts: ShellPermissionPrompts

        init(instances: [ShellComponentInstance], requestHost: String? = nil, provider: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let shell = directory.appendingPathComponent("shell")
            let root = shell.appendingPathComponent("widgets/lake")
            let component = shell.appendingPathComponent("widgets/requester")
            for folder in [root, component] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("""
            function render(ctx)
                local children = {}
                for _, item in ctx.data.components do
                    if item.enabled then children[#children+1] = ui.component{id=item.id,view='compact'} end
                end
                return ui.row(children)
            end
            """.utf8).write(to: root.appendingPathComponent("init.luau"))
            var manifest = """
            views = ['compact']
            [capabilities]
            network = ['api.example']
            provider = \(provider)
            """
            if provider {
                manifest += "\n[provider]\ncommand = ['provider.sh']\n"
                let executable = component.appendingPathComponent("provider.sh")
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
            try Data(manifest.utf8).write(to: component.appendingPathComponent("component.toml"))
            let request = requestHost.map {
                "assert(omniwm.http({url='https://\($0)/data'},function(result) end))"
            } ?? ""
            try Data("""
            return {
                init = function() \(request) end,
                views = { compact = function() return ui.box{w=10,h=10} end }
            }
            """.utf8).write(to: component.appendingPathComponent("component.luau"))

            host = ShellWidgetHost(
                configDirectory: directory,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                resourceStore: ShellResourceStore(directory: directory.appendingPathComponent("resources")),
                world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
                onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
                onPopoutChange: {}, onTitleDemandChange: { _ in }
            )
            host.config.directories = [shell]
            host.config.island = ShellIslandConfig(components: instances)
            state = ShellWidgetHost.WidgetState(name: "lake", sourceURL: root.appendingPathComponent("init.luau"))
            package = ShellWidgetPackage(
                name: "lake", generation: 1, outbox: ShellWidgetOutbox { [weak host] in host?.receive($0) },
                store: ShellStore(directoryURL: directory.appendingPathComponent("state")),
                permissions: host.permissions
            )
            state.package = package
            state.generation = 1
            host.widgets["lake"] = state
            host.setDeclarations(try host.widgetSource(of: state), of: state)
            prompts = ShellPermissionPrompts(settings: settings, present: presenter.present)
            prompts.observe(host)
        }

        func update(_ instances: [ShellComponentInstance]) async throws {
            host.config.island?.components = instances
            host.syncComponents()
            let source = try host.widgetSource(of: state)
            await package.receive(.components(source))
        }

        func close() async {
            host.stop()
            await ShellWidgetHost.flushRetiredWork()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func load(_ fixture: Fixture) async throws {
        let presented = expectation(description: "component requests permission during real package load")
        fixture.presenter.onPresent = { presented.fulfill() }
        let source = try fixture.host.widgetSource(of: fixture.state)
        let failure = await fixture.package.load(source)
        XCTAssertNil(failure)
        await fulfillment(of: [presented], timeout: 3)
        fixture.presenter.onPresent = nil
    }

    func testDisablingTheOnlyHTTPComponentDismissesItsPromptAndReenablingCanRequestAgain() async throws {
        var instance = ShellComponentInstance(id: "only", widget: "requester")
        let fixture = try Fixture(instances: [instance], requestHost: "api.example")
        defer { fixture.host.stop() }
        try await load(fixture)
        let approval = try XCTUnwrap(fixture.host.networkApprovals.values.first)
        XCTAssertEqual(fixture.prompts.active, .network(approval))

        instance.enabled = false
        try await fixture.update([instance])
        let configured = await fixture.package.configuredComponentInstances
        XCTAssertEqual(configured.count, 1)
        XCTAssertTrue(configured.filter(\.enabled).isEmpty)
        XCTAssertEqual(fixture.state.componentDescriptors.count, 1)
        XCTAssertTrue(fixture.host.networkApprovals.isEmpty)
        XCTAssertTrue(fixture.prompts.pending.isEmpty)
        XCTAssertEqual(fixture.presenter.dismissed, [.network(approval)])
        fixture.host.recordNetworkApprovals([approval])
        XCTAssertNil(fixture.prompts.active)
        fixture.presenter.answers[0](true)
        XCTAssertTrue(fixture.settings.decisions.widgets.isEmpty)

        let presented = expectation(description: "reenabled component requests permission again")
        fixture.presenter.onPresent = { presented.fulfill() }
        instance.enabled = true
        try await fixture.update([instance])
        await fulfillment(of: [presented], timeout: 3)
        fixture.presenter.onPresent = nil
        XCTAssertEqual(fixture.prompts.active, .network(approval))
        XCTAssertEqual(fixture.presenter.answers.count, 2)
        await fixture.close()
    }

    func testDisablingTheOnlyProviderDismissesItsProgramPromptAndRejectsLateApproval() async throws {
        var instance = ShellComponentInstance(id: "only", widget: "requester")
        let fixture = try Fixture(instances: [instance], provider: true)
        defer { fixture.host.stop() }
        try await load(fixture)
        let approval = try XCTUnwrap(fixture.host.providerApprovals.values.first)
        XCTAssertEqual(fixture.prompts.active, .program(approval))

        instance.enabled = false
        try await fixture.update([instance])
        let configured = await fixture.package.configuredComponentInstances
        XCTAssertTrue(configured.filter(\.enabled).isEmpty)
        XCTAssertTrue(fixture.host.providerApprovals.isEmpty)
        XCTAssertTrue(fixture.prompts.pending.isEmpty)
        XCTAssertEqual(fixture.presenter.dismissed, [.program(approval)])
        fixture.host.recordProviderApprovals([approval])
        XCTAssertNil(fixture.prompts.active)
        fixture.presenter.answers[0](true)
        XCTAssertTrue(fixture.settings.decisions.programs.isEmpty)
        await fixture.close()
    }

    func testSharedComponentKeepsItsPromptUntilTheLastEnabledInstanceIsDisabled() async throws {
        var first = ShellComponentInstance(id: "first", widget: "requester")
        var second = ShellComponentInstance(id: "second", widget: "requester")
        let fixture = try Fixture(instances: [first, second], requestHost: "api.example")
        defer { fixture.host.stop() }
        try await load(fixture)
        let approval = try XCTUnwrap(fixture.host.networkApprovals.values.first)

        first.enabled = false
        try await fixture.update([first, second])
        XCTAssertEqual(fixture.prompts.active, .network(approval))
        XCTAssertTrue(fixture.presenter.dismissed.isEmpty)
        second.enabled = false
        try await fixture.update([first, second])
        XCTAssertTrue(fixture.prompts.pending.isEmpty)
        XCTAssertTrue(fixture.host.networkApprovals.isEmpty)
        XCTAssertEqual(fixture.presenter.dismissed, [.network(approval)])
        await fixture.close()
    }

    func testDisabledInstanceCannotKeepItsExtraHostsDeclaredForAnEnabledSibling() async throws {
        let sibling = ShellComponentInstance(id: "sibling", widget: "requester")
        var extended = ShellComponentInstance(
            id: "extended", widget: "requester", capabilities: ShellComponentCapabilities(network: ["extra.example"])
        )
        let fixture = try Fixture(instances: [sibling, extended], requestHost: "extra.example")
        defer { fixture.host.stop() }
        try await load(fixture)
        let extra = try XCTUnwrap(fixture.host.networkApprovals.values.first)
        XCTAssertEqual(extra.key.hosts, ["api.example", "extra.example"])

        extended.enabled = false
        try await fixture.update([sibling, extended])
        XCTAssertTrue(fixture.prompts.pending.isEmpty)
        XCTAssertEqual(fixture.presenter.dismissed, [.network(extra)])
        fixture.host.recordNetworkApprovals([extra])
        XCTAssertTrue(fixture.host.networkApprovals.isEmpty)
        let shared = ShellNetworkApproval(
            key: ShellNetworkApproval.Key(principal: extra.key.principal, hosts: ["api.example"]), purpose: nil
        )
        fixture.host.recordNetworkApprovals([shared])
        XCTAssertEqual(fixture.prompts.active, .network(shared))
        await fixture.close()
    }
}
