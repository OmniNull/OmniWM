// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

@MainActor
final class ShellResourcePackageTests: XCTestCase {
    private static let bar = ShellBarKey(monitor: Monitor.ID(displayId: 94417))

    func testSharedCatalogDeliversEachPackagePersistenceOnlyToItsOwnLedger() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
        let store = ShellStore(directoryURL: directory.appendingPathComponent("store"), now: { 0 })
        let firstToken = try await seed(resources, package: "first")
        let secondToken = try await seed(resources, package: "second")
        let first = package("first", store: store, resources: resources)
        let second = package("second", store: store, resources: resources)
        let firstFailure = await first.load(rootSource(firstToken))
        let secondFailure = await second.load(rootSource(secondToken))
        XCTAssertNil(firstFailure)
        XCTAssertNil(secondFailure)
        await ready(first)
        await ready(second)
        await first.receive(.trigger(name: "persist", value: nil))
        await second.receive(.trigger(name: "persist", value: nil))
        await first.resourceBarrier()
        await second.resourceBarrier()
        XCTAssertEqual(first.services.pendingCount, 1)
        XCTAssertEqual(second.services.pendingCount, 1)
        await first.receive(.services)
        let firstDone = await first.resourceTestNumber("done")
        let secondBefore = await second.resourceTestNumber("done")
        XCTAssertEqual(firstDone, 1)
        XCTAssertEqual(secondBefore, 0)
        await second.receive(.services)
        let secondDone = await second.resourceTestNumber("done")
        XCTAssertEqual(secondDone, 1)
        XCTAssertEqual(first.services.activeCount, 0)
        XCTAssertEqual(second.services.activeCount, 0)
        await first.close()
        await second.close()
    }

    func testValidationReadsActiveDurableDescriptorsWithoutRebindingOrDispatching() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
        let store = ShellStore(directoryURL: directory.appendingPathComponent("store"), now: { 0 })
        let token = try await seed(resources, package: "root")
        let active = package("root", store: store, resources: resources)
        let failure = await active.load(rootSource(token))
        XCTAssertNil(failure)
        await ready(active)
        let activeOwner = await active.resourceTestOwner()
        let owner = try XCTUnwrap(activeOwner)
        let snapshot = try XCTUnwrap(resources.catalog.preparedTokens(namespace("root")))
        let candidate = package("root", store: store, resources: resources)
        let validated = await candidate.validateReload(rootSource(token))
        XCTAssertNil(validated)
        XCTAssertEqual(candidate.services.activeCount, 0)
        XCTAssertEqual(resources.catalog.metadata(owner: owner).count, 1)
        XCTAssertEqual(resources.catalog.preparedTokens(namespace("root"))?.tokens, snapshot.tokens)
        await candidate.close()
        XCTAssertTrue(resources.catalog.isActive(owner))
        await active.close()
        let replacement = package("root", store: store, resources: resources)
        let replacementFailure = await replacement.load(rootSource(token))
        XCTAssertNil(replacementFailure)
        await ready(replacement)
        let ready = await replacement.resourceTestNumber("ready")
        XCTAssertEqual(ready, 1)
        await replacement.close()
    }

    func testSameInstanceWidgetReplacementFlushesUndrainedDeinitPinBeforeStoreAndNewInit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = Mutex<[String]>([])
        let resources = ShellResourceStore(
            directory: directory.appendingPathComponent("resources"),
            writeFile: { data, url in
                writes.withLock { $0.append("resource") }
                try SettingsFileAccess.writeAtomically(data, at: url)
            }
        )
        let store = ShellStore(
            directoryURL: directory.appendingPathComponent("store"),
            now: { 0 },
            writeFile: { data, url in
                writes.withLock { $0.append("store") }
                try SettingsFileAccess.writeAtomically(data, at: url)
            }
        )
        let token = try await seed(resources, package: "root", component: "shelf")
        writes.withLock { $0.removeAll() }
        let package = package("root", store: store, resources: resources)
        var source = componentSource(token)
        let failure = await package.load(source)
        XCTAssertNil(failure)
        await ready(package)
        let previousOwner = await package.resourceTestOwner(component: "shelf")
        let oldOwner = try XCTUnwrap(previousOwner)
        source.components = [ShellComponentInstance(id: "shelf", widget: "second")]
        await package.receive(.components(source))
        await package.resourceBarrier()
        await package.receive(.services)
        await package.receive(.resources)
        let replacementOwner = await package.resourceTestOwner(component: "shelf")
        let newOwner = try XCTUnwrap(replacementOwner)
        XCTAssertNotEqual(oldOwner, newOwner)
        XCTAssertFalse(resources.catalog.isActive(oldOwner))
        XCTAssertTrue(resources.catalog.isActive(newOwner))
        let values = resources.catalog.metadata(owner: newOwner)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.state, .ready)
        XCTAssertEqual(values.first?.descriptor.name, "Saved text")
        XCTAssertEqual(Array(writes.withLock { $0 }.prefix(2)), ["resource", "store"])
        await package.close()
        let snapshot = await ShellStore(directoryURL: directory.appendingPathComponent("store")).load(namespace(
            "root",
            component: "shelf"
        ))
        let fields = try ShellServiceValue.decode(try XCTUnwrap(snapshot.bytes)).fields
        XCTAssertEqual(fields?["replacement"]?.boolean, true)
        let persisted = await ShellResourceStore(directory: resources.directory).prepare(namespace(
            "root",
            component: "shelf"
        ))
        XCTAssertNil(persisted.error)
        XCTAssertEqual(persisted.tokens.count, 2)
    }

    func testPersistenceFailureIsDeliveredAndRemainsVisibleWithoutDurableToken() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seedStore = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
        let token = try await seed(seedStore, package: "root")
        let resources = ShellResourceStore(
            directory: seedStore.directory,
            writeFile: { _, _ in throw ShellResourceFailure("disk_failure") }
        )
        let store = ShellStore(directoryURL: directory.appendingPathComponent("store"), now: { 0 })
        let package = package("root", store: store, resources: resources)
        let failure = await package.load(rootSource(token, expectFailure: true))
        XCTAssertNil(failure)
        await ready(package)
        await package.receive(.trigger(name: "persist", value: nil))
        await package.resourceBarrier()
        await package.receive(.services)
        let done = await package.resourceTestNumber("done")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(package.services.activeCount, 0)
        let snapshot = try XCTUnwrap(resources.catalog.preparedTokens(namespace("root")))
        XCTAssertEqual(snapshot.tokens.count, 1)
        await package.close()
    }

    func testPreparedLoadErrorSurvivesBindingAndValidationWhileEphemeralResourcesRemainUsable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
        let space = namespace("root")
        let folder = resources.namespaceDirectory(space)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("invalid manifest".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let store = ShellStore(directoryURL: directory.appendingPathComponent("store"), now: { 0 })
        let package = package("root", store: store, resources: resources)
        let source = ShellWidgetSource(chunk: "=resource-error", main: """
        local item,message=omniwm.resources.restore('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
        assert(item==nil and message~='unknown_resource_token' and #message>0)
        function render(ctx) return ui.box{w=1,h=1} end
        """, modules: [])
        let failure = await package.load(source)
        XCTAssertNil(failure)
        let owner = ShellServiceOwner(generation: package.services.generation, owner: 0, epoch: 1)
        let ids = try await package.admitResources(
            [ShellPickedResource(name: "text", kind: "text", uti: "public.plain-text")],
            owner: owner,
            component: nil
        )
        try await resources.materialize([.text("ephemeral")], ids: ids, owner: owner)
        XCTAssertEqual(resources.catalog.metadata(ids[0], owner: owner)?.state, .ready)
        XCTAssertNotNil(resources.catalog.preparedTokens(space)?.error)
        let candidate = self.package("root", store: store, resources: resources)
        let validation = await candidate.validateReload(source)
        XCTAssertNil(validation)
        await candidate.close()
        await package.close()
    }

    func testMetadataInboxCoalescesAndRejectsRetiredOwnerAcrossPackages() {
        let inbox = ShellResourceInbox()
        let first = ShellServiceOwner(generation: 1, owner: 0, epoch: 1)
        let second = ShellServiceOwner(generation: 2, owner: 0, epoch: 1)
        let wakes = Mutex(0)
        inbox.attach(first)
        inbox.changed(first)
        inbox.changed(first)
        inbox.changed(second)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(inbox.take(), [first])
        inbox.changed(first)
        inbox.detach(first)
        inbox.changed(first)
        XCTAssertTrue(inbox.take().isEmpty)
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        inbox.close()
        inbox.attach(second)
        inbox.changed(second)
        XCTAssertTrue(inbox.take().isEmpty)
    }

    private func package(_ name: String, store: ShellStore, resources: ShellResourceStore) -> ShellWidgetPackage {
        ShellWidgetPackage(name: name, generation: 1, outbox: ShellWidgetOutbox { batch in
            for delivery in batch.values { XCTAssertNil(delivery.failure) }
        }, store: store, resourceStore: resources)
    }

    private func ready(_ package: ShellWidgetPackage) async {
        await package.resourceBarrier()
        await package.receive(.services)
        await package.receive(.bars([Self.bar: ShellBarData()]))
        await package.receive(.resources)
    }

    private func rootSource(_ token: ShellResourceToken, expectFailure: Bool = false) -> ShellWidgetSource {
        ShellWidgetSource(chunk: "=resource-root", main: """
        local item=assert(omniwm.resources.restore('\(token.string)'))
        done=0
        ready=0
        function trigger(ctx,event)
            if event.source=='host' then return end
            assert(event.name=='persist')
            assert(omniwm.resources.persist(item,function(result)
                assert(result.ok==\(expectFailure ? "false" : "true"))
                assert(item.persistence.state=='\(expectFailure ? "failed" : "durable")')
                done+=1
            end))
        end
        function render(ctx)
            ready=item.state=='ready' and 1 or 0
            return ui.box{w=ready==1 and 20 or 10,h=10}
        end
        """, modules: [])
    }

    private func componentSource(_ token: ShellResourceToken) -> ShellWidgetSource {
        ShellWidgetSource(
            chunk: "@look/widgets/root/init.luau",
            main: "function render(ctx) return ui.component{id='shelf',view='compact'} end",
            modules: [
                .init(path: "look/widgets/first/component.luau", source: """
                return {
                    init=function(instance) instance.state.item=assert(omniwm.resources.restore('\(token.string)')) end,
                    deinit=function(instance)
                        assert(instance.state.item.state=='ready')
                        local token=assert(omniwm.resources.persist(instance.state.item))
                        assert(omniwm.store.set('next',token))
                    end,
                    views={compact=function(ctx) return ui.box{w=ctx.instance.state.item.state=='ready' and 20 or 10,h=10} end}
                }
                """),
                .init(path: "look/widgets/second/component.luau", source: """
                return {
                    init=function(instance)
                        instance.state.item=assert(omniwm.resources.restore(assert(omniwm.store.get('next'))))
                        assert(omniwm.store.set('replacement',true))
                    end,
                    views={compact=function(ctx) return ui.box{w=ctx.instance.state.item.state=='ready' and 30 or 10,h=10} end}
                }
                """)
            ],
            moduleLimit: 512,
            components: [ShellComponentInstance(id: "shelf", widget: "first")]
        )
    }

    private func seed(
        _ resources: ShellResourceStore,
        package: String,
        component: String? = nil
    ) async throws -> ShellResourceToken {
        let owner = ShellServiceOwner(generation: 900, owner: 0, epoch: 1)
        try await resources.activate(owner, namespace: namespace(package, component: component))
        let item = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "Saved text",
            kind: "text",
            uti: "public.plain-text"
        )
        try resources.catalog.admit([item], owner: owner)
        try await resources.materialize([.text("saved")], ids: [item.id], owner: owner)
        let token = ShellResourceToken()
        try resources.catalog.admitPersistence(item.id, id: ShellServiceID(owner: owner, request: 1), token: token)
        let result = await resources.persist(token)
        XCTAssertNil(result?.error)
        _ = await resources.retire(owner)
        return token
    }

    private func namespace(_ package: String, component: String? = nil) -> ShellStoreNamespace {
        ShellStoreNamespace(profile: ShellDefaults.profile, package: package, instance: component)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private extension ShellWidgetPackage {
    func resourceTestNumber(_ name: String) -> Double? {
        guard let script else { return nil }
        var value = 0.0
        return omni_vm_global_number(script.vm, name, &value) == OMNI_OK ? value : nil
    }

    func resourceTestOwner(component: String? = nil) -> ShellServiceOwner? {
        resourceOwners.first { resourceStore.catalog.namespace($0)?.instance == component }
    }
}
