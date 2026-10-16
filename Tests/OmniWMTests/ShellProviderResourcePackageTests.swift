// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

@MainActor
final class ShellProviderResourcePackageTests: XCTestCase {
    func testImportStaysBeforeEventAndCallbackSeesReadyImmutableResourcesAndLatestState() async throws {
        let fixture = try await Fixture(callback: """
        assert(result.ok and result.value==7 and #result.files==1)
        assert(result.files[1].state=='ready' and result.files[1].name=='output.bin')
        assert(not pcall(function() result.files[1]=nil end))
        assert(instance.provider.state.latest==9)
        instance.state.completed=true
        """, receive: """
        assert(instance.state.completed and event.name=='after')
        assert(omniwm.store.set('after',true))
        """)
        defer { fixture.removeDirectory() }
        try Data([1, 2, 3]).write(to: fixture.outputDirectory.appendingPathComponent("output.bin"))
        let metadata = Data("{\"files\":[{\"name\":\"output.bin\",\"path\":\"output.bin\"}]}".utf8)
        fixture.postResult(value: "7", metadata: metadata)
        fixture.package.providerInbox.post(.event(name: "after", value: Data("null".utf8)), from: fixture.identity)
        await fixture.package.receive(.providers)
        await fixture.package.resourceBarrier()
        XCTAssertEqual(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).count, 0)
        let before = await fixture.snapshot()
        XCTAssertNil(before["after"])
        await fixture.package.receive(.providers)
        await fixture.package.resourceBarrier()
        XCTAssertEqual(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).first?.state, .ready)
        fixture.package.providerInbox.post(.state(topic: "latest", value: Data("9".utf8)), from: fixture.identity)
        await fixture.package.receive(.providers)
        let after = await fixture.snapshot()
        XCTAssertEqual(after["after"]?.boolean, true)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        await fixture.package.resourceProviderFinishForTest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputDirectory.path))
        XCTAssertEqual(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).count, 1)
        await fixture.package.close()
    }

    func testCancelledDecodeHeadNeverAdmitsOutputsAndUnblocksLaterEvent() async throws {
        let fixture = try await Fixture(
            callback: "error('cancelled callback must not run')",
            receive: "assert(omniwm.store.set('after',true))"
        )
        defer { fixture.removeDirectory() }
        fixture.postResult(value: "null", metadata: Data("{\"files\":[{\"name\":\"a\",\"path\":\"a\"}]}".utf8))
        fixture.package.providerInbox.post(.event(name: "after", value: Data("null".utf8)), from: fixture.identity)
        await fixture.package.resourceProviderDecodeAndCancelForTest(fixture.key)
        await fixture.package.resourceBarrier()
        await fixture.package.receive(.providers)
        await fixture.package.resourceProviderFinishForTest()
        let after = await fixture.snapshot()
        XCTAssertEqual(after["after"]?.boolean, true)
        XCTAssertTrue(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).isEmpty)
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        XCTAssertEqual(fixture.package.providerInbox.pendingActions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputDirectory.path))
        await fixture.package.close()
    }

    func testFailedProviderResultRetainsFailureWithoutResourceAdmission() async throws {
        let fixture =
            try await Fixture(
                callback: "assert(not result.ok and result.error=='conversion_failed' and result.files==nil); assert(omniwm.store.set('failed',true))"
            )
        defer { fixture.removeDirectory() }
        fixture.postResult(
            ok: false,
            value: "\"conversion_failed\"",
            metadata: Data("{\"files\":[{\"name\":\"a\",\"path\":\"a\"}]}".utf8)
        )
        await fixture.package.receive(.providers)
        await fixture.package.resourceProviderFinishForTest()
        let snapshot = await fixture.snapshot()
        XCTAssertEqual(snapshot["failed"]?.boolean, true)
        XCTAssertTrue(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).isEmpty)
        XCTAssertEqual(fixture.package.providerInbox.pendingActions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputDirectory.path))
        await fixture.package.close()
    }

    func testMissingCallbackReleasesImportedResourcesAndCloseWaitsForPhysicalCleanup() async throws {
        let fixture = try await Fixture(callback: nil)
        defer { fixture.removeDirectory() }
        try Data([3]).write(to: fixture.outputDirectory.appendingPathComponent("output.bin"))
        fixture.postResult(
            value: "null",
            metadata: Data("{\"files\":[{\"name\":\"output.bin\",\"path\":\"output.bin\"}]}".utf8)
        )
        await fixture.package.receive(.providers)
        await fixture.package.resourceBarrier()
        await fixture.package.receive(.providers)
        await fixture.package.resourceBarrier()
        XCTAssertEqual(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).count, 1)
        await fixture.package.receive(.providers)
        await fixture.package.resourceBarrier()
        XCTAssertTrue(fixture.resources.catalog.metadata(owner: fixture.key.id.owner).isEmpty)
        await fixture.package.close()
        XCTAssertEqual(fixture.package.services.activeCount, 0)
        XCTAssertEqual(fixture.package.providerInbox.pendingActions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputDirectory.path))
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let resources: ShellResourceStore
        let package: ShellWidgetPackage
        let key: ShellResourceLeaseKey
        let outputDirectory: URL
        var identity: ShellProviderIdentity {
            ShellProviderIdentity(owner: key.id.owner, incarnation: key.incarnation)
        }

        init(callback: String?, receive: String = "") async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.directory = directory
            let resources = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
            self.resources = resources
            let package = ShellWidgetPackage(
                name: "root",
                generation: 1,
                outbox: ShellWidgetOutbox { _ in },
                store: ShellStore(directoryURL: directory.appendingPathComponent("store")),
                resourceStore: resources
            )
            self.package = package
            let installed = try await package.resourceProviderInstallForTest(callback: callback, receive: receive)
            key = installed.0
            outputDirectory = installed.1
        }

        func postResult(ok: Bool = true, value: String, metadata: Data?) {
            XCTAssertEqual(
                package.providerInbox.post(.result(
                    id: "r\(key.id.request)",
                    ok: ok,
                    value: Data(value.utf8),
                    attachments: metadata
                ), from: identity),
                .accepted
            )
        }

        func snapshot() async -> [String: ShellServiceValue] {
            await package.resourceProviderSnapshotForTest()
        }

        func removeDirectory() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private extension ShellWidgetPackage {
    func resourceProviderInstallForTest(
        callback: String?,
        receive: String
    ) async throws -> (ShellResourceLeaseKey, URL) {
        let vm = try XCTUnwrap(ShellVM.make(memoryLimit: Self.memoryLimit))
        let script = ShellScript(vm: vm)
        self.script = script
        storeProfile = "lake"
        XCTAssertEqual(omni_vm_set_service_generation(vm, services.generation), OMNI_OK)
        let source = """
        return {init=function(instance)
            assert(omniwm.provider.send('convert',{}, {files={}}\(callback.map { ",function(result) \($0) end" } ?? "")))
        end, receive=function(instance,event) \(receive) end, views={}}
        """
        let path = "lake/widgets/child/component.luau"
        XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
        let root = "function render(ctx) return ui.box{w=1,h=1} end"
        XCTAssertEqual(
            omni_vm_load(
                vm,
                "@lake/widgets/root/init.luau",
                root,
                root.utf8.count,
                Self.loadBudget,
                &errorBuffer,
                errorBuffer.count
            ),
            OMNI_OK,
            lastError()
        )
        await seedResources("child", in: script)
        var writer = ShellValueWriter()
        writer.array(1)
        writer.map(5)
        writer.key("id")
        writer.string("child")
        writer.key("widget")
        writer.string("child")
        writer.key("enabled")
        writer.bool(true)
        writer.key("provider")
        writer.bool(true)
        writer.key("options")
        writer.map(0)
        XCTAssertEqual(
            writer.bytes.withUnsafeBufferPointer { omni_vm_configure_components(
                vm,
                $0.baseAddress,
                $0.count,
                Self.loadBudget,
                &errorBuffer,
                errorBuffer.count
            ) },
            OMNI_OK,
            lastError()
        )
        var request = omni_service_request()
        XCTAssertTrue(omni_vm_next_service(vm, &request))
        XCTAssertEqual(request.kind, OMNI_SERVICE_PROVIDER)
        let id = ShellServiceID(owner: ShellServiceOwner(request.owner), request: request.id)
        let key = ShellResourceLeaseKey(id: id, incarnation: 1)
        let identity = ShellProviderIdentity(owner: id.owner, incarnation: 1)
        let operation = ShellResourceOperation()
        try bindResources(id.owner, component: "child")
        XCTAssertTrue(services.register(id, cancel: { [providerInbox] in providerInbox.cancel(id) }))
        XCTAssertTrue(providerInbox.activate(identity))
        for delivery in providerInbox.takeBatch(now: 0) { _ = deliverProvider(delivery, in: script) }
        _ = providerInbox.finishBatch(now: 0)
        XCTAssertTrue(providerInbox.register(id, identity: identity, operation: operation))
        let supervisor = ShellProvider(owner: id.owner, inbox: providerInbox)
        providerActions[id] = ProviderActionRoute(
            supervisor: supervisor,
            identity: identity,
            component: "child",
            operation: operation
        )
        let result = Mutex<Result<ShellResourceStore.ActionFiles, ShellResourceFailure>?>(nil)
        await resourceStore
            .beginAction(key, inputs: [], operation: operation) { value in result.withLock { $0 = value } }
        let files = try XCTUnwrap(result.withLock { $0 }).get()
        XCTAssertTrue(providerInbox.actionPrepared(key, result: .success(Data("frame\n".utf8))))
        XCTAssertTrue(providerInbox.markSubmitted(key))
        return (key, files.outputDirectory)
    }

    func resourceProviderSnapshotForTest() async -> [String: ShellServiceValue] {
        _ = await store.flush()
        if let script { await deliverServices(in: script) }
        let snapshot = await store.load(namespace("child"))
        guard let bytes = snapshot.bytes else { return [:] }
        return (try? ShellServiceValue.decode(bytes).fields) ?? [:]
    }

    func resourceProviderFinishForTest() async {
        await finishProviderCleanup()
    }

    func resourceProviderDecodeAndCancelForTest(_ key: ShellResourceLeaseKey) {
        for delivery in providerInbox.takeBatch(now: DispatchTime.now().uptimeNanoseconds) {
            if let work = delivery.work { consumeProviderWork(work) }
        }
        if let script { XCTAssertTrue(omni_vm_cancel_service(script.vm, key.id.owner.wire, key.id.request)) }
        services.cancel(key.id)
        providerInbox.cancel(key.id)
    }
}
