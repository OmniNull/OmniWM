// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

private extension ShellWidgetPackage {
    func configurationHostNumbers(_ names: [String]) -> [String: Double] {
        guard let script else { return [:] }
        var values: [String: Double] = [:]
        for name in names {
            var value = 0.0
            if omni_vm_global_number(script.vm, name, &value) == OMNI_OK { values[name] = value }
        }
        return values
    }

    func configurationHostMetadataIsEmpty() -> Bool {
        configurationCatalog.isEmpty && configurationSchema.isEmpty
    }
}

@MainActor
final class ShellConfigurationHostTests: XCTestCase {
    @MainActor
    private final class Sink {
        var latestWidth: Float?
        var waits: [Float: XCTestExpectation] = [:]
        var requests = 0
        var onRequests: (([ShellConfigurationRequest]) -> Void)?
        var beforeDelivery: (([String: ShellWidgetDelivery]) -> Void)?
        var onBatch: (([String: ShellWidgetDelivery]) -> Void)?

        func consume(_ batch: [String: ShellWidgetDelivery]) {
            onBatch?(batch)
            guard let delivery = batch["lake"] else { return }
            XCTAssertNil(delivery.failure)
            if !delivery.configurationRequests.isEmpty {
                requests += delivery.configurationRequests.count
                onRequests?(delivery.configurationRequests)
            }
            for tree in delivery.trees.values {
                let width = tree.nodes.withUnsafeBytes { bytes -> Float? in
                    guard bytes.count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>.stride
                    else { return nil }
                    return bytes.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride,
                        as: omni_wire_node.self
                    ).width
                }
                guard let width else { continue }
                latestWidth = width
                waits.removeValue(forKey: width)?.fulfill()
            }
        }

        func watch(_ width: Float, expectation: XCTestExpectation) {
            if latestWidth == width { expectation.fulfill() }
            else { waits[width] = expectation }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let shell: URL
        let host: ShellWidgetHost
        let state: ShellWidgetHost.WidgetState
        let package: ShellWidgetPackage
        let sink: Sink
        let key: ShellBarKey
        var source: ShellWidgetSource?

        init(_ script: String, components: [ShellComponentInstance] = [], rootEnabled: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let key = ShellBarKey(monitor: .init(displayId: 95601))
            self.key = key
            let barData = [key: ShellBarData()]
            shell = directory.appendingPathComponent("shell")
            let host = ShellWidgetHost(
                configDirectory: directory,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                world: { ShellWorldData() }, vars: { [:] }, bars: { barData }, onLayoutChange: {},
                onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
                onPopoutChange: {}, onTitleDemandChange: { _ in }
            )
            self.host = host
            let sink = Sink()
            self.sink = sink
            let outbox = ShellWidgetOutbox { [weak host] batch in
                sink.beforeDelivery?(batch)
                host?.receive(batch)
                sink.consume(batch)
            }
            package = ShellWidgetPackage(
                name: "lake",
                generation: 7,
                outbox: outbox,
                store: ShellStore(directoryURL: directory.appendingPathComponent("state"))
            )
            try FileManager.default.createDirectory(
                at: shell.appendingPathComponent("widgets/lake"),
                withIntermediateDirectories: true
            )
            let folder = try XCTUnwrap(ShellConfig.widgetFolders(in: shell).first { $0.lastPathComponent == "lake" })
            state = ShellWidgetHost.WidgetState(name: "lake", sourceURL: folder.appendingPathComponent("init.luau"))
            state.loadingGeneration = 7
            host.nextGeneration = 7
            host.config.profile = "look"
            host.config.directories = [shell]
            host.config.leading = ["lake"]
            host.config.island = rootEnabled ? ShellIslandConfig(components: components) : nil
            host.widgets["lake"] = state
            host.bars = barData
            host.outbox = outbox
            host.started = true
            try write(script, path: "widgets/lake/init.luau")
            try write("", path: "look/shell.toml")
            try write("", path: "default/shell.toml")
            try write("""
            [options.amount]
            type = "number"
            default = 1
            min = 0
            max = 1000
            """, path: "widgets/lake/settings.toml")
            var initial = "profile = 'look'\n[profiles.look]\nleading = ['lake']\n[profiles.look.island]\nroot = 'lake'\n"
            if rootEnabled {
                initial = try ShellIslandLayout.persisted(
                    .components(components),
                    profile: "look",
                    root: "lake",
                    in: initial
                )
            }
            try write(initial, path: "shell.toml")
        }

        func component(_ widget: String, uses: [String] = []) throws {
            try write("""
            return { views = { compact = function(ctx)
                return ui.box{w=ctx.instance.options.width,h=10}
            end } }
            """, path: "widgets/\(widget)/component.luau")
            let dependencies = uses.map { "'\($0)'" }.joined(separator: ",")
            try write("""
            views = ['compact']
            uses = [\(dependencies)]
            [options.width]
            type = 'number'
            default = 12
            min = 1
            max = 100
            """, path: "widgets/\(widget)/component.toml")
        }

        func write(_ text: String, path: String) throws {
            let file = shell.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: file)
        }

        func load(catalog: Bool = true, connect: Bool = true) async throws {
            if catalog, host.config.island != nil {
                host.configurationCatalog = try await host.configurationCatalogLoader.load(
                    directories: host.config.directories,
                    root: "lake"
                )
            }
            let source = try host.widgetSource(of: state)
            self.source = source
            let failure = await package.load(source)
            XCTAssertNil(failure)
            if connect { await self.connect() }
        }

        func connect() async {
            guard let source else { return XCTFail("Missing prepared source") }
            let declaration = await package.declaration
            host.finishLoad(state: state, package: package, source: source, failure: nil, declaration: declaration)
        }

        func trigger(_ name: String = "request") {
            state.mailbox?.yield(.trigger(name: name, value: nil))
        }

        func persisted() throws -> ShellConfig {
            var problems: [String] = []
            let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
            XCTAssertTrue(problems.isEmpty, "\(problems)")
            return config
        }

        func close() async {
            let writer = host.configurationWriter
            let packages = host.widgets.values.compactMap(\.package) + [package]
            host.stop()
            sink.onRequests = nil
            sink.beforeDelivery = nil
            sink.onBatch = nil
            for package in packages { await package.close() }
            await writer?.flush()
            let ids = packages.map(ObjectIdentifier.init) + (writer.map { [ObjectIdentifier($0)] } ?? [])
            for id in ids {
                if let task = ShellWidgetHost.retiringTasks[id] { await task.value }
            }
        }
    }

    func testInitRequestWaitsForConnectionAndCatalogThenCompletesOnce() async throws {
        let fixture = try Fixture("""
        done = 1
        callbacks = 0
        assert(omniwm.components.add('box', {width=21}, function(result)
            assert(result.ok and type(result.id) == 'string')
            callbacks += 1
            done = 2
        end))
        function render(ctx) return ui.box{w=done,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        try await fixture.load(catalog: false, connect: false)
        XCTAssertEqual(fixture.sink.requests, 0)
        let pending = await fixture.package.pendingConfigurations.count
        XCTAssertEqual(pending, 1)
        let handedOff = expectation(description: "startup request reaches connected host")
        fixture.sink.onRequests = { requests in
            XCTAssertEqual(requests.count, 1)
            fixture.sink.onRequests = nil
            handedOff.fulfill()
        }
        await fixture.connect()
        await fulfillment(of: [handedOff], timeout: 10)
        XCTAssertEqual(fixture.host.pendingConfigurationEdits.count, 1)
        XCTAssertEqual(fixture.host.configurationWorkCount, 1)
        XCTAssertFalse(fixture.host.configurationProcessing)
        XCTAssertTrue(fixture.host.config.island?.components.isEmpty == true)
        let completed = expectation(description: "catalog resumes admitted request")
        fixture.sink.watch(2, expectation: completed)
        fixture.host.refreshConfigurationCatalog()
        await fulfillment(of: [completed], timeout: 10)
        let numbers = await fixture.package.configurationHostNumbers(["callbacks"])
        XCTAssertEqual(numbers["callbacks"], 1)
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        XCTAssertEqual(fixture.state.generation, 7)
        XCTAssertEqual(try fixture.persisted().island?.components.first?.options["width"], .number(21))
        await fixture.close()
    }

    func testPendingStartupRequestIsRetiredWhenIslandRootRoleIsRemoved() async throws {
        let fixture = try Fixture("""
        local handle, reason = omniwm.components.add('box')
        if not handle then assert(reason == 'configuration_denied') end
        function render(ctx) return ui.box{w=handle and 12 or 22,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        fixture.host.nextGeneration = 7
        let queued = expectation(description: "startup request waits for unavailable catalog")
        fixture.sink.onRequests = { _ in
            fixture.sink.onRequests = nil
            queued.fulfill()
        }
        try await fixture.load(catalog: false)
        await fulfillment(of: [queued], timeout: 10)
        XCTAssertEqual(fixture.host.pendingConfigurationEdits.count, 1)
        XCTAssertEqual(fixture.host.configurationWorkCount, 1)
        let reloaded = expectation(description: "former root loads as a standalone widget")
        fixture.sink.watch(22, expectation: reloaded)
        try fixture.write("profile = 'look'\n[profiles.look]\nleading = ['lake']\n", path: "shell.toml")
        fixture.host.reloadConfig()
        await fulfillment(of: [reloaded], timeout: 10)
        XCTAssertNil(fixture.host.config.island)
        XCTAssertTrue(fixture.host.pendingConfigurationEdits.isEmpty)
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        XCTAssertFalse(fixture.state.package === fixture.package)
        XCTAssertGreaterThan(fixture.state.generation, 7)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        XCTAssertEqual(fixture.sink.requests, 1)
        await fixture.close()
    }

    func testStandaloneRootIsDeniedBeforeDispatchAndChangedRoleIsRecheckedAtHost() async throws {
        let standalone = try Fixture("""
        local handle, reason = omniwm.components.add('box')
        assert(handle == nil and reason == 'configuration_denied')
        function render(ctx) return ui.box{w=9,h=10} end
        """, rootEnabled: false)
        defer { standalone.host.stop()
            try? FileManager.default.removeItem(at: standalone.directory)
        }
        try await standalone.load()
        XCTAssertEqual(standalone.sink.requests, 0)
        XCTAssertEqual(standalone.package.services.activeCount, 0)
        await standalone.close()

        let fixture = try Fixture("""
        done = 1
        function trigger(ctx,event)
            if event.name ~= 'request' then return end
            assert(omniwm.components.add('box', nil, function(result)
                assert(not result.ok)
                done = 2
            end))
        end
        function render(ctx) return ui.box{w=done,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        try await fixture.load()
        let before = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml"))
        fixture.sink.beforeDelivery = { batch in
            guard batch["lake"]?.configurationRequests.isEmpty == false else { return }
            fixture.host.config.island?.root = "replacement"
            fixture.host.publishConfigurationCatalog(to: fixture.state)
            fixture.sink.beforeDelivery = nil
        }
        let rejected = expectation(description: "old root request rejected after role change")
        fixture.sink.watch(2, expectation: rejected)
        fixture.trigger()
        await fulfillment(of: [rejected], timeout: 10)
        XCTAssertTrue(fixture.host.config.island?.components.isEmpty == true)
        XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml")), before)
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        await fixture.close()
    }

    func testLoadedAndNewComponentsCanBeAddedReorderedConfiguredRemovedAndRestoredWithoutRootReload() async throws {
        let initial = ShellComponentInstance(
            id: "existing",
            widget: "box",
            provider: true,
            options: ["width": .number(12)]
        )
        let fixture = try Fixture("""
        done = 1
        local added
        local function checked(result) assert(result.ok, result.error) end
        function trigger(ctx,event)
            if event.name ~= 'request' then return end
            assert(omniwm.components.add('box', {width=23}, function(first)
                checked(first); added = first.id
                assert(omniwm.components.add('extra', {width=27}, function(second)
                    checked(second)
                    assert(omniwm.components.move(second.id, 1, function(moved)
                        checked(moved)
                        assert(omniwm.components.enable('existing', false, function(disabled)
                            checked(disabled)
                            assert(omniwm.components.set(second.id, 'width', 31, function(changed)
                                checked(changed)
                                assert(omniwm.components.remove(added, function(removed)
                                    checked(removed); done = 9
                                end))
                            end))
                        end))
                    end))
                end))
            end))
        end
        function render(ctx)
            local children = {}
            for _, item in ctx.data.components do
                if item.enabled then children[#children+1] = ui.component{id=item.id,view='compact'} end
            end
            return ui.box{w=done,h=10,ui.row(children)}
        end
        """, components: [initial])
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        try fixture.component("extra")
        try await fixture.load()
        let completed = expectation(description: "all component edits complete")
        fixture.sink.watch(9, expectation: completed)
        fixture.trigger()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(fixture.state.package === fixture.package)
        XCTAssertEqual(fixture.state.generation, 7)
        let components = try XCTUnwrap(fixture.host.config.island?.components)
        XCTAssertEqual(components.map(\.widget), ["extra", "box"])
        XCTAssertEqual(components[0].options["width"], .number(31))
        XCTAssertFalse(components[0].provider)
        XCTAssertNil(components[0].capabilities)
        XCTAssertEqual(components[1].id, "existing")
        XCTAssertFalse(components[1].enabled)
        XCTAssertTrue(components[1].provider)
        XCTAssertEqual(fixture.sink.requests, 6)
        XCTAssertEqual(try fixture.persisted().island?.components, components)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
        let restored = try fixture.persisted()
        fixture.host.config = restored
        let restartSource = try fixture.host.widgetSource(of: fixture.state)
        let restarted = ShellWidgetPackage(
            name: "lake",
            generation: 8,
            outbox: ShellWidgetOutbox { _ in },
            store: ShellStore(directoryURL: fixture.directory
                .appendingPathComponent("state"))
        )
        let failure = await restarted.load(restartSource)
        XCTAssertNil(failure)
        XCTAssertEqual(restartSource.components, components)
        await restarted.close()
    }

    func testRootHandoffReloadsBothRolesAndPromotedBarAcceptsExpandedModuleLimit() async throws {
        let script = """
        function render(ctx)
            return ui.box{w=#(ctx.data.components or {}) > 0 and 88 or 11,h=10}
        end
        """
        let component = ShellComponentInstance(id: "large", widget: "large")
        let fixture = try Fixture(script, components: [component])
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("large")
        for index in 0 ..< 64 {
            try fixture.write("return {}", path: "widgets/large/helpers/\(index).luau")
        }
        try fixture.write(script, path: "widgets/replacement/init.luau")
        fixture.host.config.directories = [
            fixture.shell,
            fixture.shell.appendingPathComponent("look"),
            fixture.shell.appendingPathComponent("default")
        ]
        fixture.host.config.leading = ["lake", "replacement"]
        fixture.state.fingerprint = fixture.host.fingerprint(of: fixture.state.sourceURL)
        let folder = try XCTUnwrap(ShellConfig.widgetFolders(in: fixture.shell)
            .first { $0.lastPathComponent == "replacement" })
        let replacement = ShellWidgetHost.WidgetState(
            name: "replacement",
            sourceURL: folder.appendingPathComponent("init.luau")
        )
        replacement.loadingGeneration = 8
        replacement.fingerprint = fixture.host.fingerprint(of: replacement.sourceURL)
        fixture.host.widgets["replacement"] = replacement
        fixture.host.nextGeneration = 8
        let outbox = try XCTUnwrap(fixture.host.outbox)
        let previousBar = ShellWidgetPackage(
            name: "replacement",
            generation: 8,
            outbox: outbox,
            store: ShellStore(directoryURL: fixture.directory
                .appendingPathComponent("state"))
        )
        let initial = expectation(description: "both original role trees publish")
        initial.expectedFulfillmentCount = 2
        var initiallySeen: Set<String> = []
        fixture.sink.onBatch = { batch in
            for name in ["lake", "replacement"]
                where batch[name]?.trees.isEmpty == false && initiallySeen.insert(name).inserted
            {
                initial.fulfill()
            }
        }
        try await fixture.load()
        let barSource = try fixture.host.widgetSource(of: replacement)
        XCTAssertFalse(barSource.isIslandRoot)
        XCTAssertEqual(barSource.moduleLimit, 64)
        let failure = await previousBar.load(barSource)
        XCTAssertNil(failure)
        let declaration = await previousBar.declaration
        fixture.host.finishLoad(
            state: replacement,
            package: previousBar,
            source: barSource,
            failure: nil,
            declaration: declaration
        )
        await fulfillment(of: [initial], timeout: 10)
        let switched = expectation(description: "both role replacements publish without module limit failure")
        var rolesPublished: Set<String> = []
        fixture.sink.onBatch = { batch in
            for (name, expected) in [("lake", Float(11)), ("replacement", Float(88))] {
                guard let state = fixture.host.widgets[name], state.generation > 8,
                      let delivery = batch[name] else { continue }
                XCTAssertNil(delivery.failure)
                for tree in delivery.trees.values {
                    let width = tree.nodes.withUnsafeBytes { bytes -> Float? in
                        guard bytes.count >= MemoryLayout<omni_wire_header>.stride + MemoryLayout<omni_wire_node>
                            .stride else { return nil }
                        return bytes.loadUnaligned(
                            fromByteOffset: MemoryLayout<omni_wire_header>.stride,
                            as: omni_wire_node.self
                        ).width
                    }
                    if width == expected { rolesPublished.insert(name) }
                }
            }
            if rolesPublished.count == 2 {
                fixture.sink.onBatch = nil
                switched.fulfill()
            }
        }
        let top = "profile = 'look'\n[profiles.look]\nleading = ['lake','replacement']\n[profiles.look.island]\nroot = 'replacement'\n"
        try fixture.write(
            ShellIslandLayout.persisted(.components([component]), profile: "look", root: "replacement", in: top),
            path: "shell.toml"
        )
        fixture.host.reloadConfig()
        await fulfillment(of: [switched], timeout: 10)
        XCTAssertFalse(fixture.state.package === fixture.package)
        XCTAssertFalse(replacement.package === previousBar)
        let root = try XCTUnwrap(replacement.package)
        let count = await root.loadedModules.count
        XCTAssertEqual(count, 65)
        XCTAssertEqual(fixture.host.config.island?.root, "replacement")
        await fixture.close()
        await previousBar.close()
        await root.close()
    }

    func testChangedDependencyFailsBeforeConfigurationOrFileMutation() async throws {
        let fixture = try Fixture("""
        done = 1
        function trigger(ctx,event)
            if event.name ~= 'request' then return end
            assert(omniwm.components.add('box', nil, function(result)
                assert(not result.ok and string.find(result.error,'missing',1,true))
                done = 2
            end))
        end
        function render(ctx) return ui.box{w=done,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        try await fixture.load()
        let before = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml"))
        try fixture.component("box", uses: ["missing"])
        let writes = Mutex(0)
        fixture.host.configurationWriter = ShellIslandConfigWriter(
            shellDirectory: fixture.shell,
            writeFile: { data, url in
                writes.withLock { $0 += 1 }
                try SettingsFileAccess.writeAtomically(data, at: url)
            },
            reloadReady: {}
        )
        let rejected = expectation(description: "source resolution fails before mutation")
        fixture.sink.watch(2, expectation: rejected)
        fixture.trigger()
        await fulfillment(of: [rejected], timeout: 10)
        XCTAssertTrue(fixture.host.config.island?.components.isEmpty == true)
        XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml")), before)
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(fixture.state.generation, 7)
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        await fixture.close()
    }

    func testWriterFailureReportsOnceAndLaterFIFOEditPersists() async throws {
        let fixture = try Fixture("""
        results = 0
        function trigger(ctx,event)
            if event.name ~= 'request' then return end
            assert(omniwm.config.set('amount',11,function(result)
                assert(not result.ok); results = results*10+1
            end))
            assert(omniwm.config.set('amount',22,function(result)
                assert(result.ok); results = results*10+2
            end))
        end
        function render(ctx) return ui.box{w=results+1,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let writes = Mutex(0)
        fixture.host.configurationWriter = ShellIslandConfigWriter(
            shellDirectory: fixture.shell,
            writeFile: { bytes, url in
                let number = writes.withLock { value in value += 1
                    return value
                }
                if number == 1 { throw CocoaError(.fileWriteNoPermission) }
                try bytes.write(to: url)
            },
            reloadReady: {}
        )
        try await fixture.load()
        let completed = expectation(description: "failure then success callbacks preserve order")
        fixture.sink.watch(13, expectation: completed)
        fixture.trigger()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(writes.withLock { $0 }, 2)
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        let bytes = try XCTUnwrap(fixture.persisted().widgetSettings["lake"])
        XCTAssertEqual(try ShellServiceValue.decode(bytes).fields?["amount"]?.number, 22)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
    }

    func testNativeAndAuthenticatedComponentEditsShareOneOrderedLayout() async throws {
        let fixture = try Fixture("""
        done = 1
        function trigger(ctx,event)
            if event.name ~= 'request' then return end
            assert(omniwm.components.add('extra',{width=27},function(result)
                assert(result.ok); done = 9
            end))
        end
        function render(ctx) return ui.box{w=done,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        try fixture.component("extra")
        let entered = expectation(description: "native persistence started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let attempts = Mutex(0)
        fixture.host.configurationWriter = ShellIslandConfigWriter(
            shellDirectory: fixture.shell,
            writeFile: { data, url in
                let first = attempts.withLock { value in value += 1
                    return value == 1
                }
                if first { entered.fulfill()
                    release.wait()
                }
                try SettingsFileAccess.writeAtomically(data, at: url)
            },
            reloadReady: {}
        )
        try await fixture.load()
        let native = Task {
            try await fixture.host.configurationCoordinator.island(.add(widget: "box", options: ["width": .number(21)]))
        }
        await fulfillment(of: [entered], timeout: 10)
        let received = expectation(description: "Luau request reaches native owner")
        fixture.sink.onRequests = { _ in fixture.sink.onRequests = nil
            received.fulfill()
        }
        let completed = expectation(description: "Luau edit completes")
        fixture.sink.watch(9, expectation: completed)
        fixture.trigger()
        await fulfillment(of: [received], timeout: 10)
        release.signal()
        _ = try await native.value
        await fulfillment(of: [completed], timeout: 10)
        let components = try XCTUnwrap(fixture.persisted().island).components
        XCTAssertEqual(components.map(\.widget), ["box", "extra"])
        XCTAssertEqual(components.map { $0.options["width"] }, [.number(21), .number(27)])
        XCTAssertEqual(Set(components.map(\.id)).count, 2)
        XCTAssertTrue(fixture.state.package === fixture.package)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.close()
    }

    func testCancelledCallbackKeepsAcceptedWriteCountedAndStopFlushesIt() async throws {
        let fixture = try Fixture("""
        cancelled = 0
        callbacks = 0
        local handle
        function trigger(ctx,event)
            if event.name == 'request' then
                handle = assert(omniwm.config.set('amount',77,function(result) callbacks += 1 end))
            elseif event.name == 'cancel' then
                handle:cancel()
                cancelled = 1
            end
        end
        function render(ctx) return ui.box{w=cancelled == 1 and 3 or 1,h=10} end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let entered = expectation(description: "accepted write reaches utility queue")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, writeFile: { bytes, url in
            entered.fulfill()
            release.wait()
            try bytes.write(to: url)
        }, reloadReady: {})
        fixture.host.configurationWriter = writer
        try await fixture.load()
        fixture.trigger()
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(fixture.host.configurationWorkCount, 1)
        let cancelled = expectation(description: "native callback cancellation completes")
        fixture.sink.watch(3, expectation: cancelled)
        fixture.trigger("cancel")
        await fulfillment(of: [cancelled], timeout: 10)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        XCTAssertEqual(fixture.host.configurationWorkCount, 1)
        let beforeStop = await fixture.package.configurationHostNumbers(["callbacks"])
        XCTAssertEqual(beforeStop["callbacks"], 0)
        fixture.host.stop()
        let retirement = try XCTUnwrap(ShellWidgetHost.retiringTasks[ObjectIdentifier(writer)])
        XCTAssertEqual(fixture.host.configurationWorkCount, 0)
        XCTAssertNil(fixture.host.configurationWriter)
        release.signal()
        await retirement.value
        let bytes = try XCTUnwrap(fixture.persisted().widgetSettings["lake"])
        XCTAssertEqual(try ShellServiceValue.decode(bytes).fields?["amount"]?.number, 77)
        await fixture.close()
    }

    func testCatalogFailureClearsPreviouslyPublishedCatalogAndSchema() async throws {
        let fixture = try Fixture("""
        function render(ctx)
            local valid = ctx.data.catalog ~= nil and ctx.data.settingsSchema ~= nil
            return ui.box{w=valid and 12 or 2,h=10}
        end
        """)
        defer { fixture.host.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try fixture.component("box")
        let ready = expectation(description: "catalog metadata reaches root")
        fixture.sink.watch(12, expectation: ready)
        try await fixture.load()
        await fulfillment(of: [ready], timeout: 10)
        try fixture.write("[options.amount]\ntype = 'unsupported'", path: "widgets/lake/settings.toml")
        let cleared = expectation(description: "failed refresh clears old metadata")
        fixture.sink.watch(2, expectation: cleared)
        fixture.host.refreshConfigurationCatalog()
        await fulfillment(of: [cleared], timeout: 10)
        XCTAssertNil(fixture.host.configurationCatalog)
        XCTAssertNotNil(fixture.host.configurationCatalogError)
        let empty = await fixture.package.configurationHostMetadataIsEmpty()
        XCTAssertTrue(empty)
        await fixture.close()
    }
}
