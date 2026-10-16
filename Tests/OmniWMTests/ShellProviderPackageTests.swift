// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

private extension ShellWidgetPackage {
    func configureProviderBurst(_ sources: [ShellWidgetSource]) -> [ShellScriptFailure] {
        guard let script else { return [ShellScriptFailure(kind: .internalError, message: "Missing script")] }
        return sources.compactMap { configureComponents($0, in: script.vm) }
    }

    func providerCheckpoint() -> (owner: ShellServiceOwner?, incarnation: UInt64?, pending: Int, reserved: UInt32) {
        let owner = providerOwner("child")
        return (
            owner,
            owner.flatMap { providerInbox.binding(for: $0)?.identity.incarnation },
            pendingProviderRequests.count,
            script.map { omni_vm_service_stats($0.vm).reserved } ?? 0
        )
    }
}

@MainActor
final class ShellProviderPackageTests: XCTestCase {
    @MainActor
    private final class Sink {
        var commands: [ShellWidgetScriptRequest] = []
        var onCommand: ((ShellWidgetScriptRequest) -> Void)?

        func consume(_ batch: [String: ShellWidgetDelivery]) {
            guard let delivery = batch["test"] else { return }
            XCTAssertNil(delivery.failure)
            for command in delivery.requests { commands.append(command)
                onCommand?(command)
            }
        }
    }

    private func makeProvider(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("provider")
        try #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use JSON::PP;
        $| = 1;
        my $options = decode_json($ENV{'OMNIWM_PROVIDER_OPTIONS'});
        my $count = 0;
        my $marker = $ENV{'OMNIWM_WIDGET_DIR'} . '/closed';
        $SIG{'TERM'} = sub { open(my $out, '>', $marker) or die $!; print $out "closed"; close($out); exit(0); };
        while (my $line = <STDIN>) {
            my $message = decode_json($line);
            die "not an action" unless $message->[0] eq 'action';
            ++$count;
            my $value = { tag => $options->{'tag'}, count => $count, argument => $message->[3]->{'tag'}, closed => (-e $marker ? JSON::PP::true : JSON::PP::false) };
            print encode_json(['state', 'latest', $value]), "\n";
            print encode_json(['event', 'changed', $value]), "\n";
            print encode_json(['result', $message->[1], JSON::PP::true, $value]), "\n";
        }
        open(my $out, '>', $marker) or die $!;
        print $out "closed";
        close($out);
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func source(folder: URL, component: String, tag: String = "A") -> ShellWidgetSource {
        var instance = ShellComponentInstance(id: "child", widget: "child")
        instance.provider = true
        instance.options = ["tag": .string(tag)]
        let descriptor = ShellComponentDescriptor(
            widget: "child",
            title: "Child",
            icon: "",
            views: ["compact"],
            uses: [],
            options: [:],
            capabilities: ShellComponentCapabilities(provider: true),
            providerCommand: ["provider"],
            folder: folder
        )
        return ShellWidgetSource(
            chunk: "@look/widgets/test/init.luau",
            main: """
            function render(ctx) return ui.component{id='child',view='compact'} end
            """,
            modules: [.init(path: "look/widgets/child/component.luau", source: component)],
            moduleLimit: 512,
            components: [instance],
            componentDescriptors: [descriptor]
        )
    }

    private func connect(_ package: ShellWidgetPackage) -> (AsyncStream<ShellWidgetMessage>.Continuation, Task<
        Void,
        Never
    >) {
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        package.services.attachWake { mailbox.yield(.services) }
        package.providerInbox.attachWake { mailbox.yield(.providers) }
        let task = Task {
            for await message in messages { await package.receive(message) }
        }
        return (mailbox, task)
    }

    func testProviderResultTakesLedgerRegistrationExactlyOnceWithoutOrdinaryCompletionWake() {
        let owner = ShellServiceOwner(generation: 42, owner: 1, epoch: 3)
        let id = ShellServiceID(owner: owner, request: 8)
        let ledger = ShellServiceLedger(generation: owner.generation)
        let cancelled = Mutex(0)
        let wakes = Mutex(0)
        ledger.attachWake { wakes.withLock { $0 += 1 } }
        XCTAssertTrue(ledger.register(id, cancel: { cancelled.withLock { $0 += 1 } }))
        XCTAssertTrue(ledger.takeRegistered(id))
        XCTAssertFalse(ledger.takeRegistered(id))
        XCTAssertFalse(ledger.complete(ShellServiceCompletion(id: id, payload: [0])))
        XCTAssertEqual(cancelled.withLock { $0 }, 1)
        XCTAssertEqual(wakes.withLock { $0 }, 0)
        XCTAssertEqual(ledger.activeCount, 0)
    }

    func testInitSendReceivesLatestStateThenOneEventAndResultAcrossTwoDisplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("widget", isDirectory: true)
        try makeProvider(in: folder)
        let sink = Sink()
        let delivered = expectation(description: "one event followed by its result")
        delivered.expectedFulfillmentCount = 2
        sink.onCommand = { command in
            XCTAssertNotEqual(command.owner?.owner, 0)
            XCTAssertNil(command.bar)
            delivered.fulfill()
        }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store"))
        )
        let input = source(folder: folder, component: """
        return {
            init=function(instance)
                assert(instance.provider.status=='starting')
                assert(omniwm.provider.send('echo',{tag='init'},nil,function(result)
                    assert(result.ok and result.value.tag=='A' and result.value.argument=='init')
                    assert(instance.provider.state.latest.count==1 and instance.state.received==1)
                    instance.state.done=true
                    omniwm.run('switch-workspace 2')
                end))
            end,
            receive=function(instance,event)
                assert(event.kind=='event' and event.name=='changed')
                assert(instance.provider.state.latest.count==event.value.count)
                instance.state.received=(instance.state.received or 0)+1
                assert(instance.state.received==1)
                omniwm.run('switch-workspace 1')
            end,
            views={compact=function(ctx) return ui.box{w=ctx.instance.state.done and 20 or 10,h=10} end}
        }
        """)
        let failure = await package.load(input)
        XCTAssertNil(failure)
        await package.receive(.bars([
            ShellBarKey(monitor: .init(displayId: 98112)): ShellBarData(),
            ShellBarKey(monitor: .init(displayId: 98113)): ShellBarData()
        ]))
        let (mailbox, consumer) = connect(package)
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(sink.commands.map(\.text), ["switch-workspace 1", "switch-workspace 2"])
        let checkpoint = await package.providerCheckpoint()
        XCTAssertEqual(checkpoint.incarnation, 1)
        XCTAssertEqual(checkpoint.pending, 0)
        XCTAssertEqual(checkpoint.reserved, 0)
        XCTAssertEqual(package.services.activeCount, 0)
        mailbox.finish()
        await consumer.value
        await package.close()
    }

    func testCoalescedOptionsReturnToActualConfigurationSettlesSupersededSendWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("widget", isDirectory: true)
        try makeProvider(in: folder)
        let sink = Sink()
        let initial = expectation(description: "initial A request finished")
        let replacement = expectation(description: "B fails before final A completes")
        replacement.expectedFulfillmentCount = 2
        sink.onCommand = { command in
            if command.text == "switch-workspace 1" { initial.fulfill() }
            else { replacement.fulfill() }
        }
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: directory.appendingPathComponent("store"))
        )
        let component = """
        local function send(instance,label)
            assert(omniwm.provider.send('echo',{tag=label},nil,function(result)
                if label=='B' then
                    assert(not result.ok and result.error=='configuration_changed')
                    omniwm.run('switch-workspace 2')
                else
                    assert(result.ok and result.value.tag=='A' and result.value.argument==label)
                    assert(instance.provider.state.latest.count==instance.state.received)
                    if label=='init' then
                        assert(result.value.count==1)
                        omniwm.run('switch-workspace 1')
                    else
                        assert(result.value.count==2)
                        omniwm.run('switch-workspace 3')
                    end
                end
            end))
        end
        return {
            init=function(instance) send(instance,'init') end,
            options=function(instance) send(instance,instance.options.tag) end,
            receive=function(instance,event)
                assert(instance.provider.state.latest.count==event.value.count)
                instance.state.received=(instance.state.received or 0)+1
            end,
            views={compact=function() return ui.box{w=10,h=10} end}
        }
        """
        let first = source(folder: folder, component: component)
        let failure = await package.load(first)
        XCTAssertNil(failure)
        let (mailbox, consumer) = connect(package)
        await fulfillment(of: [initial], timeout: 10)
        let before = await package.providerCheckpoint()
        let failures = await package.configureProviderBurst([
            source(folder: folder, component: component, tag: "B"), first
        ])
        XCTAssertTrue(failures.isEmpty)
        await fulfillment(of: [replacement], timeout: 10)
        XCTAssertEqual(sink.commands.map(\.text), ["switch-workspace 1", "switch-workspace 2", "switch-workspace 3"])
        let after = await package.providerCheckpoint()
        XCTAssertEqual(after.owner, before.owner)
        XCTAssertEqual(after.incarnation, before.incarnation)
        XCTAssertEqual(after.pending, 0)
        XCTAssertEqual(after.reserved, 0)
        XCTAssertEqual(package.services.activeCount, 0)
        mailbox.finish()
        await consumer.value
        await package.close()
    }

    func testWidgetIdentityChangeRetiresOldProviderAndStoreWhileBothTypesRemainLoaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("widget", isDirectory: true)
        try makeProvider(in: folder)
        let sink = Sink()
        let initial = expectation(description: "first owner has a live provider")
        let replacement = expectation(description: "replacement has the retired owner's saved state")
        sink.onCommand = { command in
            if command.text == "switch-workspace 1" { initial.fulfill() }
            else { XCTAssertEqual(command.text, "switch-workspace 2")
                replacement.fulfill()
            }
        }
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let package = ShellWidgetPackage(
            name: "test",
            generation: 1,
            outbox: ShellWidgetOutbox { sink.consume($0) },
            store: ShellStore(directoryURL: storeDirectory)
        )
        let component = """
        return {
            init=function(instance)
                if instance.id~='child' then return end
                local second=instance.widget=='b'
                if second then assert(omniwm.store.get('retired')=='a') end
                assert(omniwm.provider.send('echo',{tag=instance.widget},nil,function(result)
                    assert(result.ok and result.value.tag==instance.widget)
                    if second then
                        assert(result.value.closed)
                        omniwm.run('switch-workspace 2')
                    else omniwm.run('switch-workspace 1') end
                end))
            end,
            deinit=function(instance)
                if instance.id=='child' then assert(omniwm.store.set('retired',instance.widget)) end
            end,
            views={compact=function() return ui.box{w=10,h=10} end}
        }
        """
        var first = source(folder: folder, component: component)
        first = ShellWidgetSource(
            chunk: first.chunk,
            main: first.main,
            modules: ["a", "b"].map { .init(
                path: "look/widgets/\($0)/component.luau",
                source: component
            ) },
            moduleLimit: 512
        )
        first.componentDescriptors = ["a", "b"].map {
            ShellComponentDescriptor(
                widget: $0,
                title: $0,
                icon: "",
                views: ["compact"],
                uses: [],
                options: [:],
                capabilities: ShellComponentCapabilities(provider: true),
                providerCommand: ["provider"],
                folder: folder
            )
        }
        var child = ShellComponentInstance(id: "child", widget: "a")
        child.provider = true
        child.options = ["tag": .string("a")]
        first.components = [
            ShellComponentInstance(id: "keep-a", widget: "a"),
            ShellComponentInstance(id: "keep-b", widget: "b"),
            child
        ]
        let failure = await package.load(first)
        XCTAssertNil(failure)
        let (mailbox, consumer) = connect(package)
        await fulfillment(of: [initial], timeout: 10)
        let before = await package.providerCheckpoint()
        let loaded = await package.loadedModules
        var second = first
        child = ShellComponentInstance(id: "child", widget: "b")
        child.provider = true
        child.options = ["tag": .string("b")]
        second.components[2] = child
        await package.receive(.components(second))
        await fulfillment(of: [replacement], timeout: 10)
        let after = await package.providerCheckpoint()
        XCTAssertNotEqual(after.owner, before.owner)
        XCTAssertEqual(after.incarnation, 1)
        XCTAssertEqual(after.pending, 0)
        XCTAssertEqual(after.reserved, 0)
        let modules = await package.loadedModules
        XCTAssertEqual(modules, loaded)
        XCTAssertEqual(modules.count, 2)
        let reloaded = await ShellStore(directoryURL: storeDirectory).load(
            ShellStoreNamespace(profile: first.profile, package: "test", instance: "child")
        )
        XCTAssertNil(reloaded.error)
        let stored = reloaded.bytes.flatMap { try? ShellServiceValue.decode($0) }
        XCTAssertEqual(stored?.fields?["retired"]?.string, "a")
        XCTAssertEqual(sink.commands.map(\.text), ["switch-workspace 1", "switch-workspace 2"])
        mailbox.finish()
        await consumer.value
        await package.close()
    }
}
