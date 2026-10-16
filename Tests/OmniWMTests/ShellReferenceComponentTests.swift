// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellReferenceComponentTests: XCTestCase {
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
        let widget: String
        var displays: [OpaquePointer] = []
        let text = ShellTextStore()
        var nodes: [omni_wire_node] = []
        var error = [CChar](repeating: 0, count: 512)
        var dependencies: UInt64 = 0

        init(_ widget: String, timers: Int = 0, width: Int = 520, seed: [UInt8]? = nil) throws {
            self.widget = widget
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            let profile = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("lake")
            func module(_ path: String, _ source: String) {
                let path = "profile/" + path
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            module("lib/lake/services/reference-clock.luau", "return {now=1000}")
            for path in [
                "lib/lake/view.luau",
                "lib/lake/motion.luau",
                "lib/lake/services/notice.luau",
                "lib/lake/services/\(widget).luau"
            ] {
                var source = try String(contentsOf: profile.appendingPathComponent(path), encoding: .utf8)
                if widget == "calendar", path.hasSuffix("services/calendar.luau") {
                    source =
                        "local clock=require('./reference-clock') local os={time=function() return clock.now end}\n" +
                        source
                }
                module(path, source)
            }
            let component = try String(
                contentsOf: profile.appendingPathComponent("widgets/\(widget)/component.luau"),
                encoding: .utf8
            )
            module("widgets/\(widget)/component.luau", """
            local component=(function()
            \(component)
            end)()
            local blocked={}
            local initialize=component.init
            component.init=function(instance)
                if initialize then initialize(instance) end
                for _=1,\(timers) do blocked[#blocked+1]=assert(omniwm.after(3600,function() end)) end
            end
            local expanded=component.views.expanded
            component.views.fixture=function(ctx)
                return ui.column{expanded(ctx),ui.box{onClick=function() if #blocked>0 then table.remove(blocked,1):cancel() end end,ui.text{text='free-fixture-slot'}}}
            end
            return component
            """)
            let root = """
            local clock=require('../lib/lake/services/reference-clock')
            function render(ctx)
                local activity=omniwm.components.activity('subject') or {}
                return ui.column{
                    ui.text{text=activity.alert and 'alert:'..activity.alert.id or 'no-alert'},
                    ui.text{text='priority:'..tostring(activity.priority or 0)},
                    ui.text{text='label:'..tostring(activity.label or '')},
                    ui.component{id='subject',view=ctx.data.title or 'expanded',w=\(width),h=300,props={top=0}},
                    ui.box{onClick=function(_,event) clock.now=event.value end,ui.text{text='clock-fixture'}}}
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
                    omni_vm_seed_store(vm, "subject", 7, $0.baseAddress, $0.count, nil, 0, &error, error.count)
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

        var alert: String? {
            captions.first { $0.hasPrefix("alert:") }
        }

        func configure(options: [String: ShellServiceValue] = [:], enabled: Bool = true) {
            var writer = ShellValueWriter()
            ShellServiceValue.array([.object([
                "id": .text("subject"),
                "widget": .text(widget),
                "enabled": .bool(enabled),
                "options": .object(options)
            ])]).write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 200_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func addDisplay() throws -> OpaquePointer {
            let result = try XCTUnwrap(omni_instance_create(vm))
            displays.append(result)
            return result
        }

        func set(_ key: String, _ value: ShellServiceValue, display: OpaquePointer? = nil) {
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(display ?? displays[0], key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }

        @discardableResult
        func update(_ changed: UInt64 = .max, display: OpaquePointer? = nil) throws -> [omni_render_step_stats] {
            let display = display ?? displays[0]
            XCTAssertEqual(omni_instance_begin_update(display, OMNI_VIEW_BAR, changed, true), OMNI_OK)
            var result: [omni_render_step_stats] = []
            for _ in 0 ..< 32 {
                var step = omni_render_step_stats()
                XCTAssertEqual(
                    omni_instance_step_update(display, OMNI_VIEW_BAR, 200_000_000, &step, &error, error.count),
                    OMNI_OK,
                    message
                )
                XCTAssertEqual(step.unit_status, OMNI_OK, message)
                result.append(step)
                if step.done {
                    dependencies = step.render.deps
                    var count = 0
                    let output = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &count))
                    let bytes = Array(UnsafeBufferPointer(start: output, count: count))
                    text.ingest(wire: bytes)
                    nodes = bytes.withUnsafeBytes { buffer in
                        let header = buffer.loadUnaligned(as: omni_wire_header.self)
                        return (0 ..< Int(header.node_count)).map {
                            buffer.loadUnaligned(
                                fromByteOffset: MemoryLayout<omni_wire_header>
                                    .stride + $0 * MemoryLayout<omni_wire_node>.stride,
                                as: omni_wire_node.self
                            )
                        }
                    }
                    return result
                }
            }
            XCTFail("reference component did not complete its retained update")
            return result
        }

        func action(containing caption: String) throws -> UInt32 {
            let index = try XCTUnwrap(nodes.firstIndex { text.string($0.text) == caption })
            let parent = try XCTUnwrap((0 ... index).reversed()
                .first { nodes[$0].action != 0 && Int(nodes[$0].subtree_end) > index })
            return nodes[parent].action
        }

        @discardableResult
        func invoke(_ action: UInt32, value: Double? = nil) -> [String] {
            var event = ShellEvent()
            event.value = value
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
            defer { omni_instance_clear_messages(displays[0]) }
            return (0 ..< omni_instance_message_count(displays[0], OMNI_MESSAGE_REQUEST)).map { index in
                var length = 0
                guard let pointer = omni_instance_message(displays[0], OMNI_MESSAGE_REQUEST, index, &length)
                else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
            }
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

        func complete(_ request: Request, failure: String? = nil) {
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
            XCTAssertTrue(handled)
        }
    }

    private func bluetooth(_ connected: [String], access: String = "granted") -> ShellServiceValue {
        .object([
            "power": .bool(true),
            "access": .text(access),
            "devices": .array(connected.map { .object([
                "id": .text($0),
                "name": .text($0),
                "kind": .text("headphones"),
                "connected": .bool(true),
                "battery": .number(80),
                "left": .number(0),
                "right": .number(75)
            ]) })
        ])
    }

    private func calendar(start: Double = 1600, access: String = "full") -> ShellServiceValue {
        .object([
            "access": .text(access),
            "events": .array([.object([
                "id": .text("event-a"),
                "title": .text("Design review"),
                "calendar": .text("Work"),
                "color": .text("#ff0000"),
                "start": .number(start),
                "end": .number(start + 3600),
                "allDay": .bool(false),
                "time": .text("10:00"),
                "day": .text("Today")
            ])])
        ])
    }

    func testBatteryCrossingsAndChargingUseStableAlertsWithoutTimers() throws {
        let fixture = try Fixture("battery")
        fixture.set("battery", .number(40))
        fixture.set("charging", .bool(false))
        fixture.set("power", .object(["source": .text("battery"), "charged": .bool(false), "lowPower": .bool(false)]))
        try fixture.update()
        XCTAssertNil(fixture.alert)
        fixture.set("battery", .number(19))
        try fixture.update(ShellDataKey.battery.bit)
        let low = try XCTUnwrap(fixture.alert)
        try fixture.update()
        XCTAssertEqual(fixture.alert, low)
        fixture.set("battery", .number(21))
        try fixture.update(ShellDataKey.battery.bit)
        fixture.set("battery", .number(19))
        try fixture.update(ShellDataKey.battery.bit)
        XCTAssertNotEqual(fixture.alert, low)
        fixture.set("charging", .bool(true))
        try fixture.update(ShellDataKey.charging.bit)
        XCTAssertTrue(try XCTUnwrap(fixture.alert).contains("charging"))
        fixture.configure(options: ["alerts": .bool(false)])
        try fixture.update()
        XCTAssertNil(fixture.alert)
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testBluetoothBaselineConnectionsAndRawBatteryChannels() throws {
        let fixture = try Fixture("devices")
        fixture.set("bluetooth", bluetooth(["A"]))
        try fixture.update()
        XCTAssertNil(fixture.alert)
        fixture.set("bluetooth", bluetooth(["A", "B"]))
        try fixture.update(ShellDataKey.bluetooth.bit)
        let first = try XCTUnwrap(fixture.alert)
        XCTAssertTrue(fixture.captions.contains("80% · L 0% · R 75%"))
        let display = try fixture.addDisplay()
        fixture.set("bluetooth", bluetooth(["A", "B"]), display: display)
        try fixture.update(display: display)
        XCTAssertEqual(fixture.alert, first)
        fixture.set("bluetooth", bluetooth(["A"]))
        try fixture.update(ShellDataKey.bluetooth.bit)
        fixture.set("bluetooth", bluetooth(["A", "B"]))
        try fixture.update(ShellDataKey.bluetooth.bit)
        XCTAssertNotEqual(fixture.alert, first)
        fixture.set("bluetooth", bluetooth([], access: "notDetermined"))
        try fixture.update(ShellDataKey.bluetooth.bit)
        XCTAssertNil(fixture.alert)
        XCTAssertEqual(fixture.invoke(try fixture.action(containing: "lock.open")), ["bluetooth authorize"])
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testPrivacyUsesOnlyActualBooleanStateAndHasNoActions() throws {
        let fixture = try Fixture("privacy")
        for microphone in [false, true] {
            for camera in [false, true] {
                fixture.set("privacy", .object(["microphone": .bool(microphone), "camera": .bool(camera)]))
                try fixture.update()
                XCTAssertTrue(fixture.captions.contains("priority:\(microphone || camera ? 75 : 0)"))
                XCTAssertTrue(fixture.captions.contains("Microphone: \(microphone ? "in use" : "idle")"))
                XCTAssertTrue(fixture.captions.contains("Camera: \(camera ? "in use" : "idle")"))
                XCTAssertEqual(fixture.nodes.filter { $0.action != 0 }.count, 1)
            }
        }
        fixture.set("privacy", .null)
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("Privacy status unavailable"))
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
    }

    func testBadgesPreserveLabelsAndCountAppsInsteadOfInventingUnreadTotals() throws {
        let fixture = try Fixture("badges")
        fixture.set("badges", .object(["app.a": .text("99+"), "app.b": .text("!")]))
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("99+"))
        XCTAssertTrue(fixture.captions.contains("!"))
        XCTAssertTrue(fixture.captions.contains("label:2 apps with badges"))
        fixture.set("badges", .object([:]))
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("No app badges"))
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testRemindersRequireExplicitAuthorizationAndKeepNativeFailureVisible() throws {
        let fixture = try Fixture("reminders")
        fixture.set(
            "reminders",
            .object([
                "access": .text("notDetermined"),
                "items": .array([]),
                "total": .number(0),
                "truncated": .bool(false)
            ])
        )
        try fixture.update()
        XCTAssertEqual(fixture.invoke(try fixture.action(containing: "lock.open")), ["reminders authorize"])
        let items: ShellServiceValue = .array([
            .object([
                "id": .text("writable"),
                "title": .text("Buy milk"),
                "list": .text("Home"),
                "allDay": .bool(false),
                "canComplete": .bool(true)
            ]),
            .object([
                "id": .text("readonly"),
                "title": .text("Shared task"),
                "list": .text("Work"),
                "allDay": .bool(false),
                "canComplete": .bool(false)
            ])
        ])
        fixture.set(
            "reminders",
            .object([
                "access": .text("full"),
                "items": items,
                "total": .number(2),
                "truncated": .bool(false),
                "error": .text("reminder_read_only")
            ])
        )
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("Buy milk"))
        XCTAssertTrue(fixture.captions.contains("Shared task"))
        XCTAssertTrue(fixture.captions.contains("reminder_read_only"))
        XCTAssertEqual(fixture.nodes.filter { $0.action != 0 }.count, 2)
        XCTAssertEqual(fixture.invoke(try fixture.action(containing: "circle")), ["reminders complete writable"])
        try fixture.update(0)
        XCTAssertTrue(fixture.captions.contains("Buy milk"))
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testCalendarUsesOneOwnerTimerAndPersistsLeadDedupe() throws {
        let fixture = try Fixture("calendar")
        fixture.set("calendar", calendar())
        try fixture.update()
        XCTAssertNil(fixture.alert)
        let timer = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })
        XCTAssertEqual(timer.seconds, 300)
        let second = try fixture.addDisplay()
        fixture.set("calendar", calendar(), display: second)
        try fixture.update(display: second)
        XCTAssertTrue(fixture.drain().isEmpty)
        try fixture.update(display: fixture.displays[0])
        fixture.invoke(try fixture.action(containing: "clock-fixture"), value: 1300)
        fixture.complete(timer)
        try fixture.update(0)
        XCTAssertEqual(fixture.alert, "alert:event-a:1600")
        let completed = fixture.drain()
        let store = try XCTUnwrap(completed.first { $0.kind == OMNI_SERVICE_STORE && !$0.cancelled })
        XCTAssertEqual(completed.filter { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled }.count, 1)
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        fixture.complete(store)
        let restored = try Fixture("calendar", seed: store.bytes)
        restored.set("calendar", calendar())
        try restored.update()
        XCTAssertNil(restored.alert)
        XCTAssertEqual(try XCTUnwrap(restored.drain().first { $0.kind == OMNI_SERVICE_TIMER }).seconds, 600)
    }

    func testCalendarZeroLeadAndOverloadRetryFollowActualBoundaries() throws {
        let zero = try Fixture("calendar")
        zero.configure(options: ["leadMinutes": .number(0)])
        zero.set("calendar", calendar(start: 1100))
        try zero.update()
        let timer = try XCTUnwrap(zero.drain().first { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })
        XCTAssertEqual(timer.seconds, 100)
        zero.invoke(try zero.action(containing: "clock-fixture"), value: 1100)
        zero.complete(timer)
        try zero.update(0)
        XCTAssertEqual(zero.alert, "alert:event-a:1100")
        XCTAssertFalse(zero.drain().contains { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })

        let blocked = try Fixture("calendar", timers: 32)
        _ = blocked.drain()
        blocked.set("title", .text("fixture"))
        blocked.set("calendar", calendar())
        try blocked.update()
        XCTAssertTrue(blocked.captions.contains { $0.hasPrefix("Calendar alerts paused:") })
        XCTAssertTrue(blocked.drain().isEmpty)
        try blocked.update()
        XCTAssertTrue(blocked.drain().isEmpty)
        blocked.invoke(try blocked.action(containing: "free-fixture-slot"))
        try blocked.update(0)
        XCTAssertFalse(blocked.drain().contains { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })
        blocked.invoke(try blocked.action(containing: "arrow.clockwise"))
        try blocked.update(0)
        let resumed = blocked.drain()
        XCTAssertEqual(resumed.filter { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled }.count, 1)
        blocked.configure(enabled: false)
        XCTAssertTrue(blocked.drain().contains { $0.kind == OMNI_SERVICE_TIMER && $0.cancelled })
    }

    func testCalendarOptionsAndAccessChangesCancelTheExactOwnedDeadline() throws {
        let fixture = try Fixture("calendar")
        fixture.set("calendar", calendar())
        try fixture.update()
        let first = try XCTUnwrap(fixture.drain().first { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })
        fixture.configure(options: ["leadMinutes": .number(1)])
        let changed = fixture.drain()
        XCTAssertTrue(changed.contains { $0.kind == OMNI_SERVICE_TIMER && $0.id == first.id && $0.cancelled })
        let replacement = try XCTUnwrap(changed.first { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled })
        XCTAssertEqual(replacement.seconds, 540)
        fixture.set("calendar", calendar(access: "denied"))
        try fixture.update(ShellDataKey.calendar.bit)
        XCTAssertTrue(fixture.drain()
            .contains { $0.kind == OMNI_SERVICE_TIMER && $0.id == replacement.id && $0.cancelled })
        XCTAssertNil(fixture.alert)
        XCTAssertEqual(fixture.invoke(try fixture.action(containing: "lock.open")), ["calendar settings"])
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
    }

    func testWeatherTextFitsTheMinimumProfileWidth() throws {
        let fixture = try Fixture("weather", width: 380)
        fixture.set("weather", .object([
            "temp": .number(12), "unit": .text("°C"),
            "condition": .text(String(repeating: "Heavy rain and strong winds ", count: 10)),
            "symbol": .text("cloud.rain.fill"), "status": .text("ready"),
            "place": .text(String(repeating: "Long place name ", count: 10))
        ]))
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains { $0.hasPrefix("Long place name") })
        XCTAssertTrue(fixture.captions.contains { $0.hasPrefix("Heavy rain") })
        var length = 0
        let output = try XCTUnwrap(omni_instance_output(fixture.displays[0], OMNI_VIEW_BAR, &length))
        let bytes = Array(UnsafeBufferPointer(start: output, count: length))
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(bytes, text: fixture.text))
        XCTAssertEqual(layout.size.width, 380)
        let elements = layout.core.elements { _ in true }
        XCTAssertFalse(elements.isEmpty)
        for handle in elements {
            let frame = layout.core.absoluteFrame(of: handle)
            XCTAssertGreaterThanOrEqual(frame.x, 0)
            XCTAssertLessThanOrEqual(frame.x + frame.width, 380)
        }
    }

    func testWeatherUnavailableAndStaleStatesDoNotPromiseFreshData() throws {
        let fixture = try Fixture("weather")
        fixture.set("weather", .null)
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("Weather unavailable"))
        fixture.set(
            "weather",
            .object([
                "temp": .number(12),
                "unit": .text("°C"),
                "condition": .text("Cloudy"),
                "symbol": .text("cloud.fill"),
                "status": .text("stale"),
                "place": .text("Toronto")
            ])
        )
        try fixture.update()
        XCTAssertTrue(fixture.captions.contains("12°C"))
        XCTAssertTrue(fixture.captions.contains("Showing the last weather update"))
        XCTAssertEqual(fixture.dependencies & ShellDataKey.seconds.bit, 0)
        XCTAssertTrue(fixture.drain().isEmpty)
    }
}
