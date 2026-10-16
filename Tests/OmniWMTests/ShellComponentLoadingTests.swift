// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellComponentLoadingTests: XCTestCase {
    func testComponentsMountAtRootLayerWithTransitiveUsesAndIndependentAssetFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try write("function render(ctx) return ui.box{} end", at: shell, path: "look/widgets/lake/init.luau")
        try write("return {}", at: shell, path: "lib/lake/init.luau")
        try write("return {}", at: shell, path: "widgets/custom/component.luau")
        try write("views = ['compact']\nuses = ['base']", at: shell, path: "widgets/custom/component.toml")
        try write("return {}", at: shell, path: "default/widgets/base/component.luau")
        try write("views = ['compact']", at: shell, path: "default/widgets/base/component.toml")
        let host = host(root)
        host.config.directories = [shell, shell.appendingPathComponent("look"), shell.appendingPathComponent("default")]
        host.config.island = ShellIslandConfig(components: [ShellComponentInstance(id: "customized", widget: "custom")])
        let state = ShellWidgetHost.WidgetState(
            name: "lake",
            sourceURL: shell.appendingPathComponent("look/widgets/lake/init.luau")
        )
        let source = try host.widgetSource(of: state)
        XCTAssertEqual(source.moduleLimit, 512)
        XCTAssertEqual(
            Set(source.modules.map(\.path)),
            ["look/lib/lake/init.luau", "look/widgets/custom/component.luau", "look/widgets/base/component.luau"]
        )
        XCTAssertEqual(source.components.map(\.id), ["customized"])
        XCTAssertEqual(source.componentDescriptors.map(\.widget), ["base", "custom"])
        XCTAssertEqual(
            source.assetPackages["custom"],
            shell.appendingPathComponent("widgets/custom", isDirectory: true)
        )
        XCTAssertEqual(
            source.assetPackages["base"],
            shell.appendingPathComponent("default/widgets/base", isDirectory: true)
        )
        XCTAssertEqual(source.assetPackages["lake"], state.sourceURL.deletingLastPathComponent())
        let before = host.fingerprint(of: state.sourceURL)
        try write("views = ['compact', 'expanded']", at: shell, path: "widgets/custom/component.toml")
        XCTAssertNotEqual(before, host.fingerprint(of: state.sourceURL))
    }

    func testModuleLimitsRejectRatherThanTruncateAndRootGetsExpandedLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try write("function render(ctx) return ui.box{} end", at: shell, path: "widgets/lake/init.luau")
        for index in 0 ..< 64 {
            try write("return 1", at: shell, path: "lib/\(index).luau")
        }
        let host = host(root)
        host.config.directories = [shell]
        let state = ShellWidgetHost.WidgetState(
            name: "lake",
            sourceURL: shell.appendingPathComponent("widgets/lake/init.luau")
        )
        XCTAssertEqual(host.packageFiles(of: state.sourceURL).count, 65)
        XCTAssertThrowsError(try host.widgetSource(of: state)) { error in
            XCTAssertTrue((error as? ShellScriptFailure)?.message.contains("limit is 64") == true)
        }
        host.config.island = ShellIslandConfig()
        XCTAssertEqual(try host.widgetSource(of: state).modules.count, 64)
        for index in 64 ..< 512 {
            try write("return 1", at: shell, path: "lib/\(index).luau")
        }
        XCTAssertThrowsError(try host.widgetSource(of: state)) { error in
            XCTAssertTrue((error as? ShellScriptFailure)?.message.contains("limit is 512") == true)
        }
    }

    func testManagedEjectCopiesComponentAndLibraryToUserLayer() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        try write("{}", at: shell, path: "look/.manifest.json")
        try write("return {}", at: shell, path: "look/widgets/component/component.luau")
        try write("views = ['compact']", at: shell, path: "look/widgets/component/component.toml")
        try write("return {}", at: shell, path: "look/lib/lake/policy.luau")
        var config = ShellConfig()
        config.profile = "look"
        config.directories = [shell, shell.appendingPathComponent("look")]
        XCTAssertEqual(
            try ShellProfiles.eject("component", config: config, shellDirectory: shell),
            shell.appendingPathComponent("widgets/component", isDirectory: true)
        )
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: shell.appendingPathComponent("widgets/component/component.toml").path))
        XCTAssertEqual(
            try ShellProfiles.eject("lib/lake/policy.luau", config: config, shellDirectory: shell),
            shell.appendingPathComponent("lib/lake/policy.luau")
        )
        XCTAssertNil(try ShellProfiles.eject("component", config: config, shellDirectory: shell))
        XCTAssertThrowsError(try ShellProfiles.eject("lib/../../escape", config: config, shellDirectory: shell))
    }

    func testFinishingAnInflightLoadAppliesLatestComponentOptionsBeforeFirstTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try write("""
        function render(ctx)
            local children = {}
            for _, component in ctx.data.components do
                if component.enabled then
                    children[#children + 1] = ui.component{ id = component.id, view = "compact" }
                end
            end
            return ui.row(children)
        end
        """, at: shell, path: "widgets/lake/init.luau")
        try write("""
        return { views = { compact = function(ctx)
            return ui.box{ w = ctx.instance.options.width, h = 10 }
        end } }
        """, at: shell, path: "widgets/box/component.luau")
        try write("""
        views = ["compact"]
        [options.width]
        type = "number"
        default = 12
        """, at: shell, path: "widgets/box/component.toml")
        let host = host(root)
        host.config.directories = [shell]
        host.config.leading = ["lake"]
        host.config.island = ShellIslandConfig(components: [
            ShellComponentInstance(id: "first", widget: "box", options: ["width": .number(12)]),
            ShellComponentInstance(id: "second", widget: "box", options: ["width": .number(99)])
        ])
        let key = ShellBarKey(monitor: Monitor.ID(displayId: 93401))
        host.bars = [key: ShellBarData()]
        let state = ShellWidgetHost.WidgetState(
            name: "lake",
            sourceURL: shell.appendingPathComponent("widgets/lake/init.luau")
        )
        state.loadingGeneration = 7
        host.widgets["lake"] = state
        let original = try host.widgetSource(of: state)
        let firstTree = expectation(description: "first tree uses latest component configuration")
        let outbox = ShellWidgetOutbox { batch in
            guard let delivery = batch["lake"] else { return }
            XCTAssertNil(delivery.failure)
            guard let tree = delivery.trees[ShellTreeKey(bar: key, view: .bar)] else { return }
            XCTAssertEqual(tree.sequence, 1)
            let widths = tree.nodes.withUnsafeBytes { bytes in
                let header = bytes.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map { index in
                    bytes.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride
                            + index * MemoryLayout<omni_wire_node>.stride,
                        as: omni_wire_node.self
                    ).width
                }
            }
            XCTAssertTrue(widths.contains(47), "\(widths)")
            XCTAssertFalse(widths.contains(12), "\(widths)")
            XCTAssertFalse(widths.contains(99), "\(widths)")
            firstTree.fulfill()
        }
        let package = ShellWidgetPackage(name: "lake", generation: 7, outbox: outbox)
        let failure = await package.load(original)
        XCTAssertNil(failure)
        let declaration = await package.declaration
        host.config.island?.components[0].options["width"] = .number(47)
        host.config.island?.components[1].enabled = false
        host.finishLoad(state: state, package: package, source: original, failure: failure, declaration: declaration)
        await fulfillment(of: [firstTree], timeout: 10)
        XCTAssertTrue(state.package === package)
        XCTAssertEqual(state.generation, 7)
        host.stop()
        await package.close()
    }

    func testReloadKeepsCommandsAlreadyAcceptedInTheSameDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var commands: [ShellRequest] = []
        let host = host(root, onCommand: { request, _ in commands.append(request) })
        let state = ShellWidgetHost.WidgetState(
            name: "lake", sourceURL: root.appendingPathComponent("shell/widgets/lake/init.luau")
        )
        state.generation = 7
        host.widgets["lake"] = state
        let delivered = expectation(description: "coalesced command and reload")
        let outbox = ShellWidgetOutbox { batch in
            XCTAssertEqual(batch["lake"]?.reload, true)
            XCTAssertEqual(batch["lake"]?.requests.count, 1)
            host.receive(batch)
            delivered.fulfill()
        }
        outbox.request(name: "lake", generation: 7, requests: [ShellWidgetScriptRequest(
            bar: ShellBarKey(monitor: Monitor.ID(displayId: 93401)), text: "switch-workspace 2"
        )])
        outbox.reload(name: "lake", generation: 7)
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(commands, [.command(.workspace(.switchTo(workspaceNumber: 2)))])
    }

    private func host(
        _ root: URL,
        onCommand: @escaping @MainActor (ShellRequest, ShellCommandOrigin) -> Void = { _, _ in }
    ) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: root,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: onCommand, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
    }

    private func write(_ text: String, at root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
