// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellRetainedUnitTests: XCTestCase {
    private final class Fixture {
        let vm: OpaquePointer
        let instance: OpaquePointer
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)

        init(_ root: String, modules: [String: String], components: [(String, String)] = [("clock", "clock")]) throws {
            let createdVM = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            for (name, source) in modules {
                let path = "profile/widgets/\(name)/component.luau"
                XCTAssertEqual(omni_vm_add_module(createdVM, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            var errors = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_vm_load(
                createdVM, "@profile/widgets/root/init.luau", root, root.utf8.count,
                100_000_000, &errors, errors.count
            ), OMNI_OK, errors.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            var writer = ShellValueWriter()
            writer.array(components.count)
            for (id, widget) in components {
                writer.map(4)
                writer.key("id")
                writer.string(id)
                writer.key("widget")
                writer.string(widget)
                writer.key("enabled")
                writer.bool(true)
                writer.key("options")
                writer.map(0)
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(createdVM, $0.baseAddress, $0.count, 100_000_000, &errors, errors.count)
            }, OMNI_OK, errors.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            instance = try XCTUnwrap(omni_instance_create(createdVM))
            vm = createdVM
        }

        deinit {
            omni_instance_destroy(instance)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func number(_ key: ShellDataKey, _ value: Double) {
            XCTAssertEqual(omni_instance_set_number(instance, key.rawValue, value), OMNI_OK)
        }

        func begin(_ changed: UInt64, visible: Bool = true) {
            XCTAssertEqual(omni_instance_begin_update(instance, OMNI_VIEW_BAR, changed, visible), OMNI_OK)
        }

        func step(budget: UInt64 = 100_000_000) -> omni_render_step_stats {
            var stats = omni_render_step_stats()
            XCTAssertEqual(omni_instance_step_update(
                instance, OMNI_VIEW_BAR, budget, &stats, &error, error.count
            ), OMNI_OK, message)
            return stats
        }

        func update(
            _ changed: UInt64 = .max,
            view: omni_view = OMNI_VIEW_BAR,
            visible: Bool = true,
            display: OpaquePointer? = nil
        ) -> [omni_render_step_stats] {
            let target = display ?? instance
            XCTAssertEqual(omni_instance_begin_update(target, view, changed, visible), OMNI_OK)
            var steps: [omni_render_step_stats] = []
            for _ in 0 ..< 160 {
                var stats = omni_render_step_stats()
                XCTAssertEqual(omni_instance_step_update(
                    target, view, 100_000_000, &stats, &error, error.count
                ), OMNI_OK, message)
                steps.append(stats)
                if stats.done { return steps }
            }
            XCTFail("retained update did not reach its explicit completion state")
            return steps
        }

        func nodes(display: OpaquePointer? = nil) throws -> [omni_wire_node] {
            var length = 0
            let pointer = try XCTUnwrap(omni_instance_output(display ?? instance, OMNI_VIEW_BAR, &length))
            let bytes = Array(UnsafeBufferPointer(start: pointer, count: length))
            text.ingest(wire: bytes)
            return bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride
                            + $0 * MemoryLayout<omni_wire_node>.stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func captions(display: OpaquePointer? = nil) throws -> [String] {
            try nodes(display: display).filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func invoke(_ action: UInt32) {
            XCTAssertEqual(omni_instance_invoke(
                instance, OMNI_VIEW_BAR, action, 0, nil, 0, 100_000_000, &error, error.count
            ), OMNI_OK, message)
        }
    }

    func testComponentDataChangeSkipsRootAndUnrelatedView() throws {
        let fixture = try Fixture("""
        local calls = 0
        function render(ctx)
            calls += 1
            return ui.stack{ ui.text{ text = "root:" .. calls },
                ui.component{ id = "clock" }, ui.component{ id = "battery" } }
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "clock:" .. ctx.data.seconds }
        end } }
        """, "battery": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "battery:" .. ctx.data.battery }
        end } }
        """], components: [("clock", "clock"), ("battery", "battery")])
        fixture.number(.seconds, 1)
        fixture.number(.battery, 80)
        let initial = fixture.update()
        XCTAssertEqual(initial.filter { $0.kind == OMNI_RENDER_ROOT }.count, 1)
        XCTAssertEqual(initial.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 2)
        XCTAssertEqual(try fixture.captions(), ["root:1", "clock:1", "battery:80"])
        fixture.number(.seconds, 2)
        let changed = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(changed.filter { $0.kind == OMNI_RENDER_ROOT }.count, 0)
        XCTAssertEqual(changed.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["root:1", "clock:2", "battery:80"])
        XCTAssertEqual(fixture.update(0).map(\.kind), [OMNI_RENDER_IDLE])
    }

    func testEqualInputsReuseCacheAndReusedMutablePropsAreComparedByValue() throws {
        let fixture = try Fixture("""
        local props = { value = 1 }
        function render(ctx)
            local tick = ctx.data.seconds
            props.value = ctx.data.battery
            return ui.component{ id = "clock", w = ctx.data.cpu, props = props }
        end
        """, modules: ["clock": """
        local calls = 0
        return { views = { compact = function(ctx)
            calls += 1
            return ui.text{ text = calls .. ":" .. ctx.view.w .. ":" .. ctx.view.props.value }
        end } }
        """])
        fixture.number(.seconds, 1)
        fixture.number(.cpu, 90)
        fixture.number(.battery, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1:90:1"])
        fixture.number(.seconds, 2)
        let equal = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(equal.filter { $0.kind == OMNI_RENDER_ROOT }.count, 1)
        XCTAssertFalse(equal.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW })
        fixture.number(.cpu, 100)
        _ = fixture.update(ShellDataKey.cpu.bit)
        XCTAssertEqual(try fixture.captions(), ["2:100:1"])
        fixture.number(.battery, 2)
        _ = fixture.update(ShellDataKey.battery.bit)
        XCTAssertEqual(try fixture.captions(), ["3:100:2"])
    }

    func testFailedRootCompositionCannotChangeRetainedMountInputs() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local mode = ctx.data.cpu
            local component = ui.component{ id = "clock", w = if mode == 0 then 20 else 40 }
            if mode == 1 then error("root failed after mount") end
            if mode == 2 then return ui.stack{ component, ui.box{ onHover = "invalid" } } end
            return component
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = ctx.view.w .. ":" .. ctx.data.seconds }
        end } }
        """])
        fixture.number(.cpu, 0)
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["20:1"])
        for mode in [1.0, 2.0] {
            fixture.number(.cpu, mode)
            fixture.begin(ShellDataKey.cpu.bit)
            var failed = omni_render_step_stats()
            XCTAssertEqual(omni_instance_step_update(
                fixture.instance, OMNI_VIEW_BAR, 100_000_000, &failed, &fixture.error, fixture.error.count
            ), OMNI_ERR_RUNTIME, fixture.message)
            XCTAssertTrue(failed.done)
            fixture.number(.seconds, mode + 1)
            let updated = fixture.update(ShellDataKey.seconds.bit)
            XCTAssertFalse(updated.contains { $0.kind == OMNI_RENDER_ROOT })
            XCTAssertEqual(try fixture.captions(), ["20:\(Int(mode) + 1)"])
        }
    }

    func testRuntimeAndEncodeFailuresPreserveLastGoodView() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.component{ id = "clock" } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            local value = ctx.data.seconds
            if value == 2 then error("view failed") end
            if value == 3 then return ui.box{ onHover = "bad callback" } end
            return ui.text{ text = tostring(value) }
        end } }
        """])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        for value in [2.0, 3.0] {
            fixture.number(.seconds, value)
            let steps = fixture.update(ShellDataKey.seconds.bit)
            XCTAssertTrue(steps
                .contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW && $0.unit_status == OMNI_ERR_RUNTIME })
            XCTAssertEqual(try fixture.captions(), ["1"])
        }
        fixture.number(.seconds, 4)
        _ = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(try fixture.captions(), ["4"])
    }

    func testComponentTimeoutDoesNotConsumeFollowingUnitBudget() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.stack{ ui.component{ id = "bad" }, ui.component{ id = "good" } }
        end
        """, modules: ["bad": """
        return { views = { compact = function(ctx)
            if ctx.data.seconds == 2 then while true do end end
            return ui.text{ text = "last good" }
        end } }
        """, "good": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "next:" .. ctx.data.seconds }
        end } }
        """], components: [("bad", "bad"), ("good", "good")])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["last good", "next:1"])
        fixture.number(.seconds, 2)
        fixture.begin(ShellDataKey.seconds.bit)
        let bad = fixture.step(budget: 2_000_000)
        XCTAssertEqual(bad.kind, OMNI_RENDER_COMPONENT_VIEW)
        XCTAssertEqual(bad.unit_status, OMNI_ERR_TIMEOUT)
        var following: [omni_render_step_stats] = []
        for _ in 0 ..< 4 {
            let step = fixture.step()
            following.append(step)
            if step.done { break }
        }
        XCTAssertTrue(following.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW && $0.unit_status == OMNI_OK })
        XCTAssertEqual(following.last?.done, true)
        XCTAssertEqual(try fixture.captions(), ["last good", "next:2"])
    }

    func testCancellationLeavesPublishedTreeUntilResumedAssembly() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.component{ id = "clock" } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx) return ui.text{ text = tostring(ctx.data.seconds) } end } }
        """])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        fixture.number(.seconds, 2)
        fixture.begin(ShellDataKey.seconds.bit)
        XCTAssertEqual(fixture.step().kind, OMNI_RENDER_COMPONENT_VIEW)
        omni_instance_cancel_update(fixture.instance, OMNI_VIEW_BAR)
        XCTAssertTrue(fixture.step().done)
        XCTAssertEqual(try fixture.captions(), ["1"])
        let resumed = fixture.update(0)
        XCTAssertEqual(resumed.map(\.kind), [OMNI_RENDER_ASSEMBLE])
        XCTAssertEqual(try fixture.captions(), ["2"])
    }

    func testMountDefaultsRespectExplicitRecipesAndMaskRoots() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local nodes = {}
            for _, id in { "plain", "explicit", "masked" } do
                local component = ui.component{ id = id }
                local child = rawget(component, 1)
                if rawget(child, "appear") == nil then rawset(child, "appear", { opacity = 0 }) end
                if rawget(child, "exit") == nil then rawset(child, "exit", { scale = 0.9 }) end
                nodes[#nodes + 1] = component
            end
            return ui.stack(nodes)
        end
        """, modules: ["plain": """
        return { views = { compact = function(ctx) return ui.text{ text = "plain" } end } }
        """, "explicit": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "explicit", appear = { opacity = 0.4 }, exit = { opacity = 0.6 } }
        end } }
        """, "masked": """
        return { views = { compact = function(ctx) return ui.box{ mask = true, ui.text{ text = "mask" } } end } }
        """], components: [("plain", "plain"), ("explicit", "explicit"), ("masked", "masked")])
        _ = fixture.update()
        let nodes = try fixture.nodes()
        let plain = try XCTUnwrap(nodes.first { $0.text != 0 && fixture.text.string($0.text) == "plain" })
        let explicit = try XCTUnwrap(nodes.first { $0.text != 0 && fixture.text.string($0.text) == "explicit" })
        let mask = try XCTUnwrap(nodes.first { $0.options & UInt8(OMNI_NODE_OPTION_MASK) != 0 })
        XCTAssertNotEqual(plain.appear, 0)
        XCTAssertNotEqual(plain.exit, 0)
        XCTAssertNotEqual(explicit.appear, plain.appear)
        XCTAssertNotEqual(explicit.exit, plain.exit)
        XCTAssertEqual(mask.appear, 0)
        XCTAssertEqual(mask.exit, 0)
    }

    func testReplacedCompositionDoesNotCountOrphanedUnitCacheAgainstItsLimit() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local id = if ctx.data.seconds == 1 then "first" else "second"
            return ui.component{ id = id }
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            local nodes = { ui.text{ text = ctx.instance.id } }
            for index = 1, 3000 do nodes[#nodes + 1] = ui.box{ key = index, w = 1, h = 1 } end
            return ui.row(nodes)
        end } }
        """], components: [("first", "clock"), ("second", "clock")])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["first"])
        fixture.number(.seconds, 2)
        let steps = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertTrue(steps.allSatisfy { $0.unit_status == OMNI_OK })
        XCTAssertEqual(try fixture.captions(), ["second"])
    }

    func testActivityCachesCompareValuesAndContinueWhileHidden() throws {
        let fixture = try Fixture("""
        local calls = 0
        function render(ctx)
            calls += 1
            local activity = omniwm.components.activity("clock")
            return ui.text{ text = calls .. ":" .. activity.bucket }
        end
        popout = render
        """, modules: ["clock": """
        return { views = {}, activity = function(ctx)
            return { bucket = math.floor(ctx.data.seconds / 10) }
        end }
        """])
        fixture.number(.seconds, 10)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1:1"])
        fixture.number(.seconds, 11)
        let same = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(same.filter { $0.kind == OMNI_RENDER_ACTIVITY }.count, 1)
        XCTAssertFalse(same.contains { $0.kind == OMNI_RENDER_ROOT })
        XCTAssertEqual(same.last?.background_deps, ShellDataKey.seconds.bit)
        fixture.number(.seconds, 20)
        let hidden = fixture.update(ShellDataKey.seconds.bit, visible: false)
        XCTAssertEqual(hidden.filter { $0.kind == OMNI_RENDER_ACTIVITY }.count, 1)
        XCTAssertFalse(hidden.contains { $0.kind == OMNI_RENDER_ROOT })
        XCTAssertEqual(hidden.last?.background_deps, ShellDataKey.seconds.bit)
        XCTAssertEqual(try fixture.captions(), ["1:1"])
        _ = fixture.update(0)
        XCTAssertEqual(try fixture.captions(), ["2:2"])
        let popout = fixture.update(ShellDataKey.seconds.bit, view: OMNI_VIEW_POPOUT)
        XCTAssertFalse(popout.contains { $0.kind == OMNI_RENDER_ACTIVITY })
        let idle = fixture.update(0)
        XCTAssertEqual(idle.map(\.kind), [OMNI_RENDER_IDLE])
        XCTAssertEqual(idle.last?.background_deps, ShellDataKey.seconds.bit)
        XCTAssertEqual(idle.last?.render.deps, ShellDataKey.components.bit)
    }

    func testActivityFailureRetainsValueWithoutTrippingAnotherUnit() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.text{ text = omniwm.components.activity("bad").value .. ":" .. omniwm.components.activity("good").value }
        end
        """, modules: ["bad": """
        return { views = {}, activity = function(ctx)
            if ctx.data.seconds == 2 then while true do end end
            return { value = ctx.data.seconds }
        end }
        """, "good": """
        return { views = {}, activity = function(ctx) return { value = ctx.data.seconds } end }
        """], components: [("bad", "bad"), ("good", "good")])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1:1"])
        fixture.number(.seconds, 2)
        fixture.begin(ShellDataKey.seconds.bit)
        var steps: [omni_render_step_stats] = []
        for _ in 0 ..< 20 {
            let step = fixture.step(budget: 2_000_000)
            steps.append(step)
            if step.done { break }
        }
        XCTAssertEqual(steps.last?.done, true)
        XCTAssertTrue(steps.contains { $0.kind == OMNI_RENDER_ACTIVITY && $0.unit_status == OMNI_ERR_TIMEOUT })
        XCTAssertTrue(steps.contains { $0.kind == OMNI_RENDER_ACTIVITY && $0.unit_status == OMNI_OK })
        XCTAssertEqual(try fixture.captions(), ["1:2"])
        XCTAssertFalse(fixture.update(0).contains { $0.kind == OMNI_RENDER_ACTIVITY })
        fixture.number(.seconds, 3)
        _ = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(try fixture.captions(), ["3:3"])
    }

    func testComponentActionInvalidatesOnlyItsOwnerAcrossDisplays() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.stack{ ui.component{ id = "clock" }, ui.component{ id = "other" } }
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = tostring(ctx.instance.state.value or 0), onClick = function(c)
                c.instance.state.value = (c.instance.state.value or 0) + 1
            end }
        end } }
        """], components: [("clock", "clock"), ("other", "clock")])
        let second = try XCTUnwrap(omni_instance_create(fixture.vm))
        defer { omni_instance_destroy(second) }
        _ = fixture.update()
        let action = try XCTUnwrap(fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        _ = fixture.update(display: second)
        fixture.invoke(action)
        let first = fixture.update(0)
        XCTAssertEqual(first.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertFalse(first.contains { $0.kind == OMNI_RENDER_ROOT })
        XCTAssertEqual(try fixture.captions(), ["1", "0"])
        let other = fixture.update(0, display: second)
        XCTAssertEqual(other.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertFalse(other.contains { $0.kind == OMNI_RENDER_ROOT })
        XCTAssertEqual(try fixture.captions(display: second), ["1", "0"])
    }

    func testUnrelatedPublicationsDoNotExpireActionButOwnRevisionsDo() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.stack{ ui.component{ id = "clock" }, ui.component{ id = "other" } } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = tostring(ctx.data.seconds), onClick = function(c) c.instance.state.clicked = true end }
        end } }
        """, "other": """
        return { views = { compact = function(ctx) return ui.text{ text = tostring(ctx.data.battery) } end } }
        """], components: [("clock", "clock"), ("other", "other")])
        fixture.number(.seconds, 1)
        fixture.number(.battery, 1)
        _ = fixture.update()
        let action = try XCTUnwrap(fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        for value in 2 ... 7 {
            fixture.number(.battery, Double(value))
            _ = fixture.update(ShellDataKey.battery.bit)
            _ = try fixture.nodes()
        }
        fixture.invoke(action)
        for value in 2 ... 5 {
            fixture.number(.seconds, Double(value))
            _ = fixture.update(ShellDataKey.seconds.bit)
            _ = try fixture.nodes()
        }
        XCTAssertEqual(omni_instance_invoke(
            fixture.instance, OMNI_VIEW_BAR, action, 0, nil, 0, 100_000_000, &fixture.error, fixture.error.count
        ), OMNI_ERR_STALE_ACTION)
        XCTAssertFalse(fixture.update(0).contains { $0.kind == OMNI_RENDER_ROOT })
    }

    func testEqualOutputRefreshesCallbackWithoutChangingItsHandle() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.component{ id = "clock" } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            local captured = ctx.data.seconds
            return ui.text{ text = "same", onClick = function() omniwm.log(tostring(captured)) end }
        end } }
        """])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        let original = try XCTUnwrap(fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        for value in 2 ... 7 {
            fixture.number(.seconds, Double(value))
            _ = fixture.update(ShellDataKey.seconds.bit)
            XCTAssertEqual(try fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }?.action, original)
        }
        fixture.invoke(original)
        var length = 0
        let pointer = try XCTUnwrap(omni_instance_message(fixture.instance, OMNI_MESSAGE_LOG, 0, &length))
        XCTAssertEqual(String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self), "7")
    }

    func testConflictingRepeatedMountsFailCompositionAndPreserveOldOffers() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.stack{
                ui.box{ key = "left", ui.component{ id = "clock", w = 20 } },
                ui.box{ key = "right", ui.component{ id = "clock", w = ctx.data.cpu } },
            }
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx) return ui.text{ text = ctx.view.w .. ":" .. ctx.data.seconds } end } }
        """])
        fixture.number(.cpu, 20)
        fixture.number(.seconds, 1)
        let shared = fixture.update()
        XCTAssertEqual(shared.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["20:1", "20:1"])
        fixture.number(.cpu, 40)
        fixture.begin(ShellDataKey.cpu.bit)
        var failed = omni_render_step_stats()
        XCTAssertEqual(omni_instance_step_update(
            fixture.instance, OMNI_VIEW_BAR, 100_000_000, &failed, &fixture.error, fixture.error.count
        ), OMNI_ERR_RUNTIME)
        XCTAssertTrue(fixture.message.contains("equal size and props"))
        fixture.number(.seconds, 2)
        _ = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(try fixture.captions(), ["20:2", "20:2"])
    }

    func testRemovedOwnerInvalidatesOnlyItsActionsAndDirectRenderUsesRetainedEngine() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.stack{ onClick = function(c) c.state.clicked = true end, ui.component{ id = "clock" } }
        end
        """, modules: ["clock": """
        return { views = { compact = function(ctx) return ui.text{ text = "child", onClick = function() end } end } }
        """])
        var direct = omni_render_stats()
        XCTAssertEqual(omni_instance_render(
            fixture.instance, OMNI_VIEW_BAR, 100_000_000, &direct, &fixture.error, fixture.error.count
        ), OMNI_OK, fixture.message)
        let actions = try fixture.nodes().filter { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }.map(\.action)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(fixture.update(0).map(\.kind), [OMNI_RENDER_IDLE])
        var writer = ShellValueWriter()
        writer.array(0)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(
                fixture.vm,
                $0.baseAddress,
                $0.count,
                100_000_000,
                &fixture.error,
                fixture.error.count
            )
        }, OMNI_OK)
        XCTAssertEqual(omni_instance_invoke(
            fixture.instance, OMNI_VIEW_BAR, actions[1], 0, nil, 0, 100_000_000, &fixture.error, fixture.error.count
        ), OMNI_ERR_STALE_ACTION)
        fixture.invoke(actions[0])
        _ = fixture.update(0)
        XCTAssertEqual(try fixture.captions(), [])
    }

    func testStringResetInvalidatesActionsAndRebuildsUnitCaches() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.component{ id = "clock" } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "rebuilt", onClick = function() end }
        end } }
        """])
        _ = fixture.update()
        let action = try XCTUnwrap(fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        omni_vm_reset_strings(fixture.vm)
        XCTAssertEqual(omni_instance_invoke(
            fixture.instance, OMNI_VIEW_BAR, action, 0, nil, 0, 100_000_000, &fixture.error, fixture.error.count
        ), OMNI_ERR_STALE_ACTION)
        let steps = fixture.update(0)
        XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_ROOT }.count, 1)
        XCTAssertEqual(steps.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["rebuilt"])
        XCTAssertNotEqual(try fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }?.action, action)
    }

    func testChangingMetadataErrorCannotRetryActivityForeverWithinOneUpdate() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local activity = omniwm.components.activity("clock")
            return ui.text{ text = tostring(activity.value) }
        end
        """, modules: ["clock": """
        return { views = {}, activity = function(ctx)
            local metadata = ctx.data.components
            local value = ctx.data.seconds
            if value == 2 then
                ctx.state.attempts = (ctx.state.attempts or 0) + 1
                error("attempt:" .. ctx.state.attempts)
            end
            return { value = value }
        end }
        """])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1"])
        fixture.number(.seconds, 2)
        let failed = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(failed.filter { $0.kind == OMNI_RENDER_ACTIVITY && $0.unit_status == OMNI_ERR_RUNTIME }.count, 1)
        XCTAssertEqual(failed.last?.done, true)
        XCTAssertLessThan(failed.count, 6)
        XCTAssertEqual(try fixture.captions(), ["1"])
        XCTAssertFalse(fixture.update(0).contains { $0.kind == OMNI_RENDER_ACTIVITY })
        fixture.number(.seconds, 3)
        let recovered = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertEqual(recovered.filter { $0.kind == OMNI_RENDER_ACTIVITY }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["3"])
    }

    func testRetiredMountDoesNotBlockLiveUnitAfterRootCompositionFails() throws {
        let fixture = try Fixture("""
        function render(ctx)
            if #ctx.data.components < 2 then error("root cannot compose replacement") end
            return ui.stack{ ui.component{ id = "gone" }, ui.component{ id = "live" } }
        end
        """, modules: ["gone": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "gone", onClick = function() end }
        end } }
        """, "live": """
        return { views = { compact = function(ctx) return ui.text{ text = "live:" .. ctx.data.seconds } end } }
        """], components: [("gone", "gone"), ("live", "live")])
        fixture.number(.seconds, 1)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["gone", "live:1"])
        let retiredAction = try XCTUnwrap(fixture.nodes().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        var writer = ShellValueWriter()
        writer.array(1)
        writer.map(3)
        writer.key("id")
        writer.string("live")
        writer.key("widget")
        writer.string("live")
        writer.key("enabled")
        writer.bool(true)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(
                fixture.vm,
                $0.baseAddress,
                $0.count,
                100_000_000,
                &fixture.error,
                fixture.error.count
            )
        }, OMNI_OK)
        fixture.begin(0)
        var rootStatus = OMNI_OK
        for _ in 0 ..< 4 {
            var step = omni_render_step_stats()
            rootStatus = omni_instance_step_update(
                fixture.instance, OMNI_VIEW_BAR, 100_000_000, &step, &fixture.error, fixture.error.count
            )
            if rootStatus != OMNI_OK || step.done { break }
        }
        XCTAssertEqual(rootStatus, OMNI_ERR_RUNTIME)
        fixture.number(.seconds, 2)
        let update = fixture.update(ShellDataKey.seconds.bit)
        XCTAssertFalse(update.contains { $0.kind == OMNI_RENDER_ROOT })
        XCTAssertEqual(try fixture.captions(), ["live:2"])
        XCTAssertEqual(omni_instance_invoke(
            fixture.instance, OMNI_VIEW_BAR, retiredAction, 0, nil, 0, 100_000_000, &fixture.error, fixture.error.count
        ), OMNI_ERR_STALE_ACTION)
    }

    func testOptionsChangeWithoutHookInvalidatesOnlyChangedOwner() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.stack{ ui.component{ id = "clock" }, ui.component{ id = "other" } } end
        """, modules: ["clock": """
        return { views = { compact = function(ctx)
            return ui.text{ text = tostring(ctx.instance.options.amount or 1) }
        end } }
        """], components: [("clock", "clock"), ("other", "clock")])
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1", "1"])
        var writer = ShellValueWriter()
        writer.array(2)
        for id in ["clock", "other"] {
            writer.map(4)
            writer.key("id")
            writer.string(id)
            writer.key("widget")
            writer.string("clock")
            writer.key("enabled")
            writer.bool(true)
            writer.key("options")
            writer.map(id == "clock" ? 1 : 0)
            if id == "clock" { writer.key("amount")
                writer.number(2)
            }
        }
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_vm_configure_components(
                fixture.vm,
                $0.baseAddress,
                $0.count,
                100_000_000,
                &fixture.error,
                fixture.error.count
            )
        }, OMNI_OK)
        let changed = fixture.update(0)
        XCTAssertEqual(changed.filter { $0.kind == OMNI_RENDER_COMPONENT_VIEW }.count, 1)
        XCTAssertEqual(try fixture.captions(), ["2", "1"])
    }

    func testRootRecoveryRepublishesEqualOutputAndKeepsComponentCache() throws {
        let fixture = try Fixture("""
        function render(ctx)
            if ctx.data.cpu == 1 then error("root failed") end
            return ui.component{ id = "clock" }
        end
        """, modules: ["clock": """
        local calls = 0
        return { views = { compact = function(ctx)
            calls += 1
            return ui.text{ text = tostring(calls) }
        end } }
        """])
        fixture.number(.cpu, 0)
        _ = fixture.update()
        XCTAssertEqual(try fixture.captions(), ["1"])
        fixture.number(.cpu, 1)
        fixture.begin(ShellDataKey.cpu.bit)
        var failure = omni_render_step_stats()
        XCTAssertEqual(omni_instance_step_update(
            fixture.instance, OMNI_VIEW_BAR, 100_000_000, &failure, &fixture.error, fixture.error.count
        ), OMNI_ERR_RUNTIME)
        XCTAssertTrue(omni_instance_needs_render(fixture.instance, OMNI_VIEW_BAR, 0))
        XCTAssertEqual(try fixture.captions(), ["1"])
        fixture.number(.cpu, 0)
        let recovered = fixture.update(ShellDataKey.cpu.bit)
        XCTAssertEqual(recovered.last?.render.changed, 1)
        XCTAssertFalse(recovered.contains { $0.kind == OMNI_RENDER_COMPONENT_VIEW })
        XCTAssertEqual(try fixture.captions(), ["1"])
        XCTAssertFalse(omni_instance_needs_render(fixture.instance, OMNI_VIEW_BAR, 0))
    }
}
