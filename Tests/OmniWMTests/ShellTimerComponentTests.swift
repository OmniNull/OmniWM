// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellTimerComponentTests: XCTestCase {
    private struct Request {
        let kind: omni_service_kind
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let seconds: Double
        let cancelled: Bool
        let bytes: [UInt8]
    }

    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)
        var nodes: [omni_wire_node] = []

        init(now: Int = 1000, ownerTimers: Int = 0, seed: [UInt8]? = nil) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            func module(_ path: String, _ source: String) {
                let path = "profile/" + path
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            module("lib/lake/services/timer-clock.luau", "return {now=\(now)}")
            for path in [
                "lib/lake/view.luau",
                "lib/lake/motion.luau",
                "lib/lake/digits.luau",
                "lib/lake/services/timer.luau"
            ] {
                var source = try String(contentsOf: profile.appendingPathComponent(path), encoding: .utf8)
                if path.hasSuffix("services/timer.luau") {
                    source = "local clock=require('./timer-clock') local os={time=function() return clock.now end}\n" +
                        source
                }
                module(path, source)
            }
            let component = try String(
                contentsOf: profile.appendingPathComponent("widgets/timer/component.luau"),
                encoding: .utf8
            )
            module("widgets/timer/component.luau", """
            local component=(function()
            \(component)
            end)()
            local service=require('../lib/lake/services/timer')
            local clock=require('../lib/lake/services/timer-clock')
            local blocked={}
            local initialize=component.init
            component.init=function(instance)
                for _=1,\(ownerTimers) do blocked[#blocked+1]=assert(omniwm.after(3600,function() end)) end
                initialize(instance)
            end
            component.views.fixture=function(ctx)
                return ui.column{component.views.expanded(ctx),ui.box{onClick=function(next,event)
                    if event.value then clock.now=event.value end
                    local command=event.key
                    if command=='start' then
                        local ok,err=service.start(next.instance,'Tea',event.characters)
                        next.state.formError=err
                    elseif command=='pause' then service.pause(next.instance)
                    elseif command=='resume' then service.resume(next.instance)
                    elseif command=='clear' then service.clear(next.instance)
                    elseif command=='retry' then service.retry(next.instance)
                    elseif command=='rename' then service.rename(next.instance,event.characters)
                    elseif command=='free' then table.remove(blocked,1):cancel() end
                end,ui.text{text='fixture-control'}}}
            end
            return component
            """)
            let root = """
            function render(ctx)
                local activity=omniwm.components.activity('timer')
                return ui.column{
                    ui.text{text=activity and activity.alert and 'alert:'..activity.alert.id..':'..tostring(activity.alert.seconds) or 'no-alert'},
                    ui.component{id='timer',view='fixture'}}
            end
            """
            XCTAssertEqual(
                omni_vm_load(
                    vm,
                    "@profile/widgets/root/init.luau",
                    root,
                    root.utf8.count,
                    200_000_000,
                    &error,
                    error.count
                ),
                OMNI_OK,
                message
            )
            if let seed {
                XCTAssertEqual(seed.withUnsafeBufferPointer {
                    omni_vm_seed_store(vm, "timer", 5, $0.baseAddress, $0.count, nil, 0, &error, error.count)
                }, OMNI_OK, message)
            }
            configure()
            _ = try addDisplay()
        }

        isolated deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        var captions: [String] {
            nodes.filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func configure(enabled: Bool = true) {
            let value = ShellServiceValue.array([.object([
                "id": .text("timer"),
                "widget": .text("timer"),
                "enabled": .bool(enabled),
                "options": .object(["label": .text("Timer"), "duration": .number(300)])
            ])])
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func addDisplay() throws -> OpaquePointer {
            let display = try XCTUnwrap(omni_instance_create(vm))
            displays.append(display)
            return display
        }

        func closeDisplays() {
            for display in displays { omni_instance_destroy(display) }
            displays.removeAll()
        }

        func render(_ display: OpaquePointer? = nil, seconds: Double = 1000) throws {
            let display = try XCTUnwrap(display ?? displays.first)
            XCTAssertEqual(omni_instance_set_number(display, "seconds", seconds), OMNI_OK)
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(display, OMNI_VIEW_BAR, 200_000_000, &stats, &error, error.count),
                OMNI_OK,
                message
            )
            var count = 0
            let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &count))
            let bytes = Array(UnsafeBufferPointer(start: output, count: count))
            text.ingest(wire: bytes)
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func action(_ command: String, text: String? = nil, now: Double? = nil) throws {
            try render()
            let action = try XCTUnwrap(nodes.last { $0.action != 0 }).action
            var event = ShellEvent()
            event.key = command
            event.characters = text
            event.value = now
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    displays[0],
                    OMNI_VIEW_BAR,
                    action,
                    0,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func invoke(_ action: UInt32, text: String) {
            var writer = ShellValueWriter()
            ShellServiceValue.object(["text": .text(text)]).write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    displays[0],
                    OMNI_VIEW_BAR,
                    action,
                    0,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
        }

        func drain() -> [Request] {
            var request = omni_service_request()
            var result: [Request] = []
            while omni_vm_next_service(vm, &request) {
                result.append(Request(
                    kind: request.kind,
                    owner: request.owner,
                    id: request.id,
                    revision: request.revision,
                    seconds: request.seconds,
                    cancelled: request.cancelled,
                    bytes: request.value
                        .map { Array(UnsafeBufferPointer(start: $0, count: request.value_length)) } ?? []
                ))
            }
            return result
        }

        @discardableResult
        func complete(_ request: Request, error failure: String? = nil) -> Bool {
            var writer = ShellValueWriter()
            ShellServiceValue.object(failure.map { ["ok": .bool(false), "error": .text($0)] } ?? ["ok": .bool(true)])
                .write(to: &writer)
            var handled = false
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_complete_service(
                    vm,
                    request.owner,
                    request.id,
                    request.revision,
                    $0.baseAddress,
                    $0.count,
                    200_000_000,
                    &handled,
                    &error,
                    error.count
                )
            }, OMNI_OK, message)
            return handled
        }
    }

    func testOneOwnerDeadlineSurvivesAllDisplaysDisappearing() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.action("start", text: "1:30")
        let started = fixture.drain()
        let timer = try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(timer.seconds, 90)
        let store = try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_STORE })
        XCTAssertEqual(try ShellServiceValue.decode(store.bytes).fields?["timer"]?.fields?["deadline"]?.number, 1090)
        fixture.complete(store)
        let second = try fixture.addDisplay()
        try fixture.render(second, seconds: 1030)
        XCTAssertEqual(omni_instance_background_dependencies(second), 0)
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.action("time", now: 1090)
        fixture.closeDisplays()
        XCTAssertTrue(fixture.complete(timer))
        let completed = fixture.drain()
        XCTAssertEqual(completed.filter { $0.kind == OMNI_SERVICE_STORE }.count, 1)
        XCTAssertFalse(completed.contains { $0.kind == OMNI_SERVICE_TIMER })
        _ = try fixture.addDisplay()
        try fixture.render(seconds: 1090)
        XCTAssertTrue(fixture.captions.contains("Timer complete"))
        XCTAssertTrue(fixture.captions.contains("alert:1:1090:4"))
        try fixture.render(seconds: 1100)
        XCTAssertTrue(fixture.captions.contains("alert:1:1090:4"))
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testRestoreUsesAbsoluteDeadlineAndCompletionMarkerSurvivesRestart() throws {
        let expired = try Fixture(now: 1010, seed: seed(status: "running", deadline: 1005))
        let pending = expired.drain()
        XCTAssertFalse(pending.contains { $0.kind == OMNI_SERVICE_TIMER })
        let saved = try XCTUnwrap(pending.first { $0.kind == OMNI_SERVICE_STORE })
        try expired.render()
        XCTAssertTrue(expired.captions.contains("alert:7:1005:4"))
        let restored = try Fixture(now: 2000, seed: saved.bytes)
        XCTAssertTrue(restored.drain().isEmpty)
        try restored.render()
        XCTAssertTrue(restored.captions.contains("alert:7:1005:4"))
        try restored.action("clear")
        try restored.render()
        XCTAssertTrue(restored.captions.contains("no-alert"))
        let future = try Fixture(now: 1000, seed: seed(status: "running", deadline: 1060))
        let first = try XCTUnwrap(future.drain().first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(first.seconds, 60)
        try future.action("time", now: 990)
        future.complete(first)
        let rearmed = future.drain()
        XCTAssertEqual(rearmed.count, 1)
        XCTAssertEqual(rearmed[0].seconds, 70)
    }

    func testPausePersistsRemainingAndResumeDoesNotRestartOriginalDuration() throws {
        let fixture = try Fixture()
        try fixture.action("start", text: "1:00")
        let started = fixture.drain()
        let old = try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_TIMER })
        fixture.complete(try XCTUnwrap(started.first { $0.kind == OMNI_SERVICE_STORE }))
        try fixture.action("pause", now: 1015)
        let paused = fixture.drain()
        XCTAssertTrue(paused.contains { $0.cancelled && $0.id == old.id })
        XCTAssertFalse(fixture.complete(old))
        let snapshot = try XCTUnwrap(paused.first { $0.kind == OMNI_SERVICE_STORE })
        let restored = try Fixture(now: 5000, seed: snapshot.bytes)
        XCTAssertTrue(restored.drain().isEmpty)
        try restored.action("resume")
        let resumed = restored.drain()
        XCTAssertEqual(resumed.first { $0.kind == OMNI_SERVICE_TIMER }?.seconds, 45)
        let store = try XCTUnwrap(resumed.first { $0.kind == OMNI_SERVICE_STORE })
        XCTAssertEqual(try ShellServiceValue.decode(store.bytes).fields?["timer"]?.fields?["deadline"]?.number, 5045)
        restored.configure(enabled: false)
        let teardown = restored.drain()
        XCTAssertTrue(teardown.contains { $0.cancelled && $0.kind == OMNI_SERVICE_TIMER })
    }

    func testOverloadWaitsForExplicitRetryAndStoreFailureStaysVisible() throws {
        let fixture = try Fixture(ownerTimers: 32)
        XCTAssertEqual(fixture.drain().count, 32)
        try fixture.action("start", text: "1:00")
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("Completion paused: overloaded"))
        try fixture.render()
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.action("free")
        _ = fixture.drain()
        try fixture.action("retry")
        let retry = fixture.drain()
        XCTAssertEqual(retry.filter { !$0.cancelled && $0.kind == OMNI_SERVICE_TIMER }.count, 1)
        XCTAssertFalse(retry.contains { $0.kind == OMNI_SERVICE_STORE })
        try fixture.action("free")
        _ = fixture.drain()
        try fixture.action("retry")
        let saved = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_STORE })
        fixture.complete(saved, error: "disk full")
        try fixture.render()
        XCTAssertTrue(fixture.captions.contains("disk full"))
        try fixture.action("retry")
        XCTAssertEqual(fixture.drain().filter { $0.kind == OMNI_SERVICE_STORE }.count, 1)
    }

    func testInputDurationBoundsAndManifestRequireNoExternalCapability() throws {
        let fixture = try Fixture()
        try fixture.render()
        let inputs = fixture.nodes.filter { $0.kind == 10 }
        XCTAssertEqual(inputs.count, 2)
        for input in inputs { XCTAssertEqual(input.height, 28) }
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(fixture.text.string(input.text), "Timer")
        XCTAssertEqual(input.input_max_length, 80)
        fixture.invoke(input.action, text: "Uncommitted draft")
        fixture.invoke(input.input_cancel_action, text: "Uncommitted draft")
        try fixture.render()
        let cancelled = try XCTUnwrap(fixture.nodes.first { $0.kind == 10 })
        XCTAssertNotEqual(cancelled.key, input.key)
        XCTAssertEqual(fixture.text.string(cancelled.text), "Timer")
        XCTAssertTrue(fixture.drain().isEmpty)
        for text in ["", "0:00", "1440:01", "0:60", "-1:00", "1", "inf", "999999:00"] {
            try fixture.action("start", text: text)
            XCTAssertTrue(fixture.drain().isEmpty)
            try fixture.render()
            XCTAssertTrue(fixture.captions.contains("Use m:ss between 0:01 and 1440:00"))
        }
        try fixture.action("start", text: "1440:00")
        XCTAssertEqual(fixture.drain().first { $0.kind == OMNI_SERVICE_TIMER }?.seconds, 86400)
        let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
        let descriptor = try ShellComponentCatalog.load("timer", directories: [profile])
        XCTAssertEqual(descriptor.views, ["compact", "peek", "expanded"])
        XCTAssertTrue(descriptor.capabilities.network.isEmpty)
        XCTAssertNil(descriptor.providerCommand)
        let option = try XCTUnwrap(descriptor.options["duration"])
        XCTAssertTrue(option.accepts(.number(1)))
        XCTAssertTrue(option.accepts(.number(86400)))
        XCTAssertFalse(option.accepts(.number(0)))
        XCTAssertFalse(option.accepts(.number(86401)))
    }

    private func seed(status: String, deadline: Double) -> [UInt8] {
        var writer = ShellValueWriter()
        ShellServiceValue.object(["timer": .object([
            "label": .text("Tea"),
            "duration": .number(60),
            "serial": .number(7),
            "status": .text(status),
            "startedAt": .number(990),
            "deadline": .number(deadline)
        ])]).write(to: &writer)
        return writer.bytes
    }
}
