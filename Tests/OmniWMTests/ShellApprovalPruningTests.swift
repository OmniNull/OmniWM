// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellApprovalPruningTests: XCTestCase {
    @MainActor
    private final class Presenter {
        var answers: [@MainActor (Bool) -> Void] = []
        var dismissed: [ShellPermissionPrompts.Request] = []

        func present(
            _ request: ShellPermissionPrompts.Request,
            answer: @escaping @MainActor (Bool) -> Void
        ) -> @MainActor () -> Void {
            answers.append(answer)
            return { [weak self] in self?.dismissed.append(request) }
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await ShellWidgetHost.flushRetiredWork()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testAnOverrideOrRemovalRetiresThePrincipalAndCancelsItsPrompt() throws {
        let shell = root.appendingPathComponent("shell")
        try write("profiles.default.trailing = [\"test\"]\n", to: shell.appendingPathComponent("shell.toml"))
        let profile = shell.appendingPathComponent("default/widgets/test")
        try writeWidget(in: profile)
        let host = makeHost()
        let presenter = Presenter()
        let prompts = ShellPermissionPrompts(settings: ShellPermissionSettings(), present: presenter.present)
        prompts.observe(host)
        host.start()
        defer { if host.started { host.stop() } }

        let original = ShellWidgetPrincipal(role: .bar, name: "test", folder: profile)
        let stale = ShellWidgetPrincipal(role: .bar, name: "gone", source: shell.appendingPathComponent("gone").path)
        let current = approval(original)
        host.recordNetworkApprovals([approval(stale), current])
        XCTAssertEqual(Array(host.networkApprovals.values), [current])
        host.rescan()
        XCTAssertEqual(Array(host.networkApprovals.values), [current])
        XCTAssertEqual(prompts.pending, [.network(current)])

        let override = shell.appendingPathComponent("widgets/test")
        try writeWidget(in: override)
        host.rescan()
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertEqual(presenter.dismissed.map(\.principal), [original])
        XCTAssertNil(prompts.active)

        let overridden = approval(ShellWidgetPrincipal(role: .bar, name: "test", folder: override))
        host.recordNetworkApprovals([overridden])
        XCTAssertEqual(prompts.active, .network(overridden))
        try FileManager.default.removeItem(at: override)
        host.rescan()
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertEqual(presenter.dismissed.last, .network(overridden))

        host.recordNetworkApprovals([approval(original)])
        XCTAssertEqual(prompts.active, .network(approval(original)))
        host.stop()
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertTrue(prompts.pending.isEmpty)
    }

    @MainActor
    func testRemovingADeclaredHostOnReloadRetiresItsPromptAndRejectsALateArrival() throws {
        let shell = root.appendingPathComponent("shell")
        try write("profiles.default.trailing = [\"test\"]\n", to: shell.appendingPathComponent("shell.toml"))
        let folder = shell.appendingPathComponent("default/widgets/test")
        try writeWidget(in: folder, hosts: ["api.example", "cdn.example"])
        let host = makeHost()
        let presenter = Presenter()
        let prompts = ShellPermissionPrompts(settings: ShellPermissionSettings(), present: presenter.present)
        prompts.observe(host)
        host.start()
        defer { if host.started { host.stop() } }

        let principal = ShellWidgetPrincipal(role: .bar, name: "test", folder: folder)
        let both = approval(principal, hosts: ["api.example", "cdn.example"])
        host.recordNetworkApprovals([both])
        XCTAssertEqual(prompts.active, .network(both))

        try writeWidget(in: folder, hosts: ["api.example"])
        host.rescan()
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertEqual(presenter.dismissed, [.network(both)])
        host.recordNetworkApprovals([both])
        XCTAssertNil(prompts.active)

        let remaining = approval(principal, hosts: ["api.example"])
        host.recordNetworkApprovals([remaining])
        XCTAssertEqual(prompts.active, .network(remaining))
    }

    @MainActor
    func testAClosedHiddenBarMenuKeepsItsPromptUntilItsSameFolderDeclarationDropsTheHost() throws {
        let folder = root.appendingPathComponent("shell/default/widgets/hidden-bar-menu")
        try writeSettings(in: folder, hosts: ["api.example"])
        try write("""
        function render(ctx) return ui.row{} end
        function popout(ctx) return ui.box{ w = 20, h = 20 } end
        """, to: folder.appendingPathComponent("init.luau"))
        let host = makeHost()
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = ShellPermissionPrompts(settings: settings, present: presenter.present)
        prompts.observe(host)
        host.start()
        defer { if host.started { host.stop() } }

        XCTAssertTrue(host.showHiddenBarMenu(
            HiddenBarMenuPage(title: nil, rows: [], backID: nil),
            anchor: ShellAnchor(frame: CGRect(x: 200, y: 500, width: 20, height: 20), level: .popUpMenu),
            on: .fallback,
            onSelect: { _ in },
            onClose: {}
        ))
        let stale = approval(ShellWidgetPrincipal(role: .bar, name: "hidden-bar-menu", folder: folder))
        host.recordNetworkApprovals([stale])
        XCTAssertEqual(prompts.active, .network(stale))

        host.closeHiddenBarMenu()
        XCTAssertNil(host.hiddenBarMenu)
        host.rescan()
        XCTAssertEqual(host.hiddenBarMenuHosts, ["api.example"])
        XCTAssertEqual(prompts.active, .network(stale))
        XCTAssertTrue(presenter.dismissed.isEmpty)

        try writeSettings(in: folder, hosts: ["cdn.example"])
        host.rescan()
        XCTAssertEqual(host.hiddenBarMenuHosts, ["cdn.example"])
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertTrue(prompts.pending.isEmpty)
        XCTAssertEqual(presenter.dismissed, [.network(stale)])
        host.recordNetworkApprovals([stale])
        XCTAssertTrue(host.networkApprovals.isEmpty)
        XCTAssertNil(prompts.active)
        presenter.answers[0](true)
        XCTAssertTrue(settings.decisions.widgets.isEmpty)
    }

    @MainActor
    func testChangedOrRemovedComponentDeclarationsRetireObsoletePromptsWithinTheSamePrincipal() throws {
        let shell = root.appendingPathComponent("shell")
        let folder = shell.appendingPathComponent("widgets/converter")
        try write(
            "return { views = { compact = function() return ui.box{ w = 1, h = 1 } end } }\n",
            to: folder.appendingPathComponent("component.luau")
        )
        try writeComponent(in: folder, command: "provider.pl", hosts: ["api.example", "cdn.example"])
        let rootSource = shell.appendingPathComponent("widgets/lake/init.luau")
        try write("function render(ctx) return ui.box{ w = 10, h = 10 } end\n", to: rootSource)
        let host = makeHost()
        host.config.directories = [shell]
        host.config.island = ShellIslandConfig(
            root: "lake", components: [ShellComponentInstance(id: "converter", widget: "converter")]
        )
        let state = ShellWidgetHost.WidgetState(name: "lake", sourceURL: rootSource)
        state.package = ShellWidgetPackage(
            name: "lake", generation: 1, outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: root.appendingPathComponent("state"))
        )
        host.widgets["lake"] = state
        let settings = ShellPermissionSettings()
        let presenter = Presenter()
        let prompts = ShellPermissionPrompts(settings: settings, present: presenter.present)
        prompts.observe(host)
        host.syncComponents()

        let principal = ShellWidgetPrincipal(role: .component, name: "converter", folder: folder)
        XCTAssertEqual(host.title(of: principal), "Converter")
        XCTAssertEqual(
            host.title(of: ShellWidgetPrincipal(role: .bar, name: "ci-status", source: folder.path)), "CI Status"
        )
        let first = ShellProviderApproval(principal: principal, command: ["provider.pl"], sha256: "aa")
        let both = approval(principal, hosts: ["api.example", "cdn.example"])
        host.recordProviderApprovals([first])
        host.recordNetworkApprovals([both])
        XCTAssertEqual(prompts.pending, [.program(first), .network(both)])

        try writeComponent(in: folder, command: "convert.pl", hosts: ["api.example", "cdn.example"])
        host.syncComponents()
        XCTAssertEqual(presenter.dismissed, [.program(first)])
        presenter.answers[0](true)
        XCTAssertTrue(settings.decisions.programs.isEmpty)
        host.recordProviderApprovals([first])
        let second = ShellProviderApproval(principal: principal, command: ["convert.pl"], sha256: "bb")
        host.recordProviderApprovals([second])
        XCTAssertEqual(prompts.pending, [.network(both), .program(second)])

        try writeComponent(in: folder, command: nil, hosts: ["api.example", "cdn.example"])
        host.syncComponents()
        XCTAssertEqual(prompts.pending, [.network(both)])
        host.recordProviderApprovals([second])
        XCTAssertTrue(host.providerApprovals.isEmpty)

        try writeComponent(in: folder, command: nil, hosts: ["api.example"])
        host.syncComponents()
        XCTAssertTrue(prompts.pending.isEmpty)
        XCTAssertEqual(presenter.dismissed, [.program(first), .network(both)])
        host.recordNetworkApprovals([both])
        XCTAssertTrue(host.networkApprovals.isEmpty)
        let remaining = approval(principal, hosts: ["api.example"])
        host.recordNetworkApprovals([remaining])
        XCTAssertEqual(prompts.active, .network(remaining))

        host.config.island?.components = []
        host.syncComponents()
        XCTAssertTrue(prompts.pending.isEmpty)
        XCTAssertEqual(presenter.dismissed.last, .network(remaining))
    }

    @MainActor
    private func approval(
        _ principal: ShellWidgetPrincipal,
        hosts: Set<String> = ["api.example"]
    ) -> ShellNetworkApproval {
        ShellNetworkApproval(key: ShellNetworkApproval.Key(principal: principal, hosts: hosts), purpose: nil)
    }

    private func writeWidget(in folder: URL, hosts: [String] = ["api.example"]) throws {
        try writeSettings(in: folder, hosts: hosts)
        try write(
            "function render(ctx) return ui.box{ w = 10, h = 10 } end\n",
            to: folder.appendingPathComponent("init.luau")
        )
    }

    private func writeSettings(in folder: URL, hosts: [String]) throws {
        try write(
            "[capabilities]\nnetwork = [\(hosts.map { "'\($0)'" }.joined(separator: ", "))]\n",
            to: folder.appendingPathComponent("settings.toml")
        )
    }

    private func writeComponent(in folder: URL, command: String?, hosts: [String]) throws {
        var manifest = """
        title = 'Converter'
        views = ['compact']
        [capabilities]
        network = [\(hosts.map { "'\($0)'" }.joined(separator: ", "))]
        provider = \(command != nil)
        """
        if let command { manifest += "\n[provider]\ncommand = ['\(command)']" }
        try write(manifest, to: folder.appendingPathComponent("component.toml"))
    }

    private func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    @MainActor
    private func makeHost() -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            resourceStore: ShellResourceStore(directory: root.appendingPathComponent("resources")),
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
    }
}
