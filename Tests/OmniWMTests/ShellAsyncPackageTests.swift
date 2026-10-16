// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellAsyncPackageTests: XCTestCase {
    func testTimerCallbackWithoutDisplayContextRendersAndDeliversItsCommandOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = expectation(description: "timer changes the rendered tree")
        let command = expectation(description: "timer issues one command")
        var commands = 0
        var widths: [Float] = []
        let package = ShellWidgetPackage(name: "test", generation: 0, outbox: ShellWidgetOutbox { batch in
            guard let delivery = batch["test"] else { return }
            XCTAssertNil(delivery.failure)
            for request in delivery.requests {
                XCTAssertEqual(request.text, "switch-workspace 2")
                XCTAssertNil(request.bar)
                XCTAssertEqual(request.owner?.owner, 0)
                commands += 1
                command.fulfill()
            }
            for tree in delivery.trees.values {
                let width = Self.width(tree)
                widths.append(width)
                if width == 20 { changed.fulfill() }
            }
        }, store: ShellStore(directoryURL: directory))
        XCTAssertGreaterThan(package.services.generation, 0)
        let source = ShellWidgetSource(chunk: "=test", main: """
        local ready = false
        assert(omniwm.after(0.01, function()
            ready = true
            omniwm.log("timer delivered")
            omniwm.run("switch-workspace 2")
        end))
        function render(ctx) return ui.box{w=ready and 20 or 10,h=10} end
        """, modules: [])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        package.services.attachWake { Task { await package.receive(.services) } }
        await package.receive(.bars([Self.bar: ShellBarData()]))
        await fulfillment(of: [changed, command], timeout: 10)
        XCTAssertEqual(commands, 1)
        XCTAssertEqual(widths.last, 20)
        XCTAssertEqual(package.services.activeCount, 0)
        await package.close()
    }

    func testComponentDeinitStoreFlushIsVisibleBeforeReplacementInitAndRootIsSeparate() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellStore(directoryURL: directory, now: { 0 })
        let first = ShellWidgetPackage(name: "lake", generation: 1, outbox: ShellWidgetOutbox { _ in }, store: store)
        var source = componentSource(root: "assert(omniwm.store.set('count',99))", initial: 5)
        let firstFailure = await first.load(source)
        XCTAssertNil(firstFailure)
        await first.close()

        let rendered = expectation(description: "replacement reads final component state")
        let second = ShellWidgetPackage(name: "lake", generation: 2, outbox: ShellWidgetOutbox { batch in
            guard let delivery = batch["lake"] else { return }
            XCTAssertNil(delivery.failure)
            for tree in delivery.trees.values {
                XCTAssertEqual(Self.width(tree), 6)
                rendered.fulfill()
            }
        }, store: store)
        source = componentSource(root: "assert(omniwm.store.get('count')==99)", initial: 6)
        let secondFailure = await second.load(source)
        XCTAssertNil(secondFailure)
        await second.receive(.bars([Self.bar: ShellBarData()]))
        await fulfillment(of: [rendered], timeout: 10)
        await second.close()

        source = ShellWidgetSource(chunk: "=other", main: """
        assert(omniwm.store.get('count')==nil)
        function render(ctx) return ui.box{} end
        """, modules: [], profile: "other")
        let other = ShellWidgetPackage(name: "lake", generation: 3, outbox: ShellWidgetOutbox { _ in }, store: store)
        let otherFailure = await other.load(source)
        XCTAssertNil(otherFailure)
        await other.close()
    }

    func testRemovingComponentFlushesItsDeinitStoreBeforePackageCloses() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellStore(directoryURL: directory, now: { 0 })
        let package = ShellWidgetPackage(name: "lake", generation: 1, outbox: ShellWidgetOutbox { _ in }, store: store)
        var source = componentSource(root: "", initial: 5)
        let failure = await package.load(source)
        XCTAssertNil(failure)
        source.components = []
        await package.receive(.components(source))
        let namespace = ShellStoreNamespace(profile: source.profile, package: "lake", instance: "counter")
        _ = await store.load(namespace)
        let persisted = await ShellStore(directoryURL: directory).load(namespace)
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("count")
        writer.number(6)
        XCTAssertEqual(persisted.bytes, writer.bytes)
        XCTAssertNil(persisted.error)
        await package.close()
    }

    func testFailedOlderStoreCommitKeepsNewestAcceptedValueAcrossCloseAndReload() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellStore(directoryURL: directory, now: { 0 }, writeFile: { _, _ in throw StoreError() })
        let failed = expectation(description: "store failure delivered")
        let first = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { batch in
            guard let delivery = batch["test"] else { return }
            XCTAssertNil(delivery.failure)
            for tree in delivery.trees.values where Self.width(tree) == 30 { failed.fulfill() }
        }, store: store)
        let source = ShellWidgetSource(chunk: "=test", main: """
        assert(omniwm.store.set('count',1))
        function trigger(ctx,event) assert(omniwm.store.set('count',2)) end
        function render(ctx)
            return ui.box{w=omniwm.store.status.state=='failed' and 30 or 10,h=10}
        end
        """, modules: [])
        let firstFailure = await first.load(source)
        XCTAssertNil(firstFailure)
        first.services.attachWake { Task { await first.receive(.services) } }
        await first.receive(.bars([Self.bar: ShellBarData()]))
        await first.receive(.trigger(name: "update", value: nil))
        let failures = await store.flush()
        XCTAssertEqual(failures.count, 1)
        await fulfillment(of: [failed], timeout: 10)
        await first.close()

        let second = ShellWidgetPackage(name: "test", generation: 2, outbox: ShellWidgetOutbox { _ in }, store: store)
        let secondFailure = await second.load(ShellWidgetSource(chunk: "=test", main: """
        assert(omniwm.store.get('count')==2)
        assert(omniwm.store.status.state=='failed')
        function render(ctx) return ui.box{} end
        """, modules: []))
        XCTAssertNil(secondFailure)
        await second.close()
    }

    func testReloadValidationDoesNotDispatchServicesOrCommitItsStoreWrites() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellStore(directoryURL: directory, now: { 0 })
        let package = ShellWidgetPackage(name: "test", generation: 1, outbox: ShellWidgetOutbox { _ in
            XCTFail("validation must not publish")
        }, store: store)
        let source = ShellWidgetSource(chunk: "=test", main: """
        assert(omniwm.store.set('validated',true))
        assert(omniwm.after(0.01,function() omniwm.run('switch-workspace 2') end))
        function render(ctx) return ui.box{} end
        """, modules: [])
        let failure = await package.validateReload(source)
        XCTAssertNil(failure)
        XCTAssertEqual(package.services.activeCount, 0)
        let namespace = ShellStoreNamespace(profile: source.profile, package: "test", instance: nil)
        let snapshot = await store.load(namespace)
        XCTAssertNil(snapshot.bytes)
        await package.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: namespace).path))
    }

    private static let bar = ShellBarKey(monitor: Monitor.ID(displayId: 93401))

    private struct StoreError: Error {}

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private static func width(_ tree: ShellWidgetDelivery.Tree) -> Float {
        tree.nodes.withUnsafeBytes { bytes in
            let count = Int(bytes.loadUnaligned(as: omni_wire_header.self).node_count)
            return (0 ..< count).map {
                bytes.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride
                        + $0 * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                ).width
            }.max() ?? 0
        }
    }

    private func componentSource(root: String, initial: Int) -> ShellWidgetSource {
        ShellWidgetSource(chunk: "@look/widgets/lake/init.luau", main: """
        \(root)
        function render(ctx) return ui.component{id='counter',view='compact'} end
        """, modules: [.init(path: "look/widgets/counter/component.luau", source: """
        return {
            init=function(instance)
                local count=omniwm.store.get('count') or \(initial)
                assert(count==\(initial))
                assert(omniwm.store.set('count',count))
            end,
            deinit=function(instance)
                assert(omniwm.store.set('count',omniwm.store.get('count')+1))
            end,
            views={compact=function(ctx) return ui.box{w=omniwm.store.get('count'),h=10} end}
        }
        """)], moduleLimit: 512, components: [ShellComponentInstance(id: "counter", widget: "counter")])
    }
}
