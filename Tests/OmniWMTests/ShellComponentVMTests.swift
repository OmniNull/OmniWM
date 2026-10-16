// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellComponentVMTests: XCTestCase {
    private struct Item {
        let id: String
        var widget = "counter"
        var enabled = true
        var amount = 1.0
    }

    private final class Fixture {
        let vm: OpaquePointer
        var displays: [OpaquePointer] = []
        var error = [CChar](repeating: 0, count: 512)
        let text = ShellTextStore()

        init(_ root: String, modules: [String: String]) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 16 << 20))
            for (name, source) in modules {
                let path = "profile/widgets/\(name)"
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            XCTAssertEqual(omni_vm_load(
                vm,
                "@profile/widgets/root/init.luau",
                root,
                root.utf8.count,
                100_000_000,
                &error,
                error.count
            ), OMNI_OK, message)
        }

        deinit {
            for display in displays { omni_instance_destroy(display) }
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func display() throws -> OpaquePointer {
            let result = try XCTUnwrap(omni_instance_create(vm))
            displays.append(result)
            return result
        }

        func configure(_ items: [Item]) {
            var writer = ShellValueWriter()
            writer.array(items.count)
            for item in items {
                writer.map(5)
                writer.key("id")
                writer.string(item.id)
                writer.key("widget")
                writer.string(item.widget)
                writer.key("title")
                writer.string(item.widget)
                writer.key("enabled")
                writer.bool(item.enabled)
                writer.key("options")
                writer.map(1)
                writer.key("amount")
                writer.number(item.amount)
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func render(_ display: OpaquePointer) throws -> [omni_wire_node] {
            var stats = omni_render_stats()
            let status = omni_instance_render(
                display,
                OMNI_VIEW_BAR,
                100_000_000,
                &stats,
                &error,
                error.count
            )
            XCTAssertEqual(status, OMNI_OK, message)
            guard status == OMNI_OK else { return [] }
            var length = 0
            let pointer = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
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

        func captions(_ display: OpaquePointer) throws -> [String] {
            try render(display).filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func invoke(_ display: OpaquePointer, _ action: UInt32) -> omni_status {
            omni_instance_invoke(display, OMNI_VIEW_BAR, action, 0, nil, 0, 100_000_000, &error, error.count)
        }
    }

    private let counter = """
    local component = { starts = 0, stops = 0, updates = 0, previous = 0, views = {} }
    function component.init(instance)
        component.starts += 1
        instance.state.clicks = 0
    end
    function component.options(instance, previous)
        component.updates += 1
        component.previous = previous.amount
    end
    function component.deinit(instance)
        component.stops += 1
        instance.state.stopped = true
    end
    function component.views.compact(ctx)
        assert(table.isfrozen(ctx.instance) and table.isfrozen(ctx.instance.options))
        return ui.text{ text = ctx.instance.id .. ":" .. ctx.instance.state.clicks .. ":" .. (ctx.state.clicks or 0) .. ":" .. ctx.instance.options.amount,
            onClick = function(next)
                assert(next.instance == ctx.instance)
                next.instance.state.clicks += 1
                next.state.clicks = (next.state.clicks or 0) + 1
            end }
    end
    function component.activity(ctx)
        return { priority = ctx.instance.state.clicks, label = ctx.instance.id }
    end
    return component
    """

    func testSharedLifecycleAndDisplayStatePreserveRootWrapperContext() throws {
        let fixture = try Fixture("""
        local component = require("@component/counter")
        function render(ctx)
            local nodes = { ui.text{ text = "root:" .. (ctx.state.clicks or 0) } }
            for _, item in ctx.data.components do
                table.insert(nodes, ui.component{ id = item.id, view = "compact", w = 90,
                    onClick = function(root)
                        assert(root.instance == nil)
                        root.state.clicks = (root.state.clicks or 0) + 1
                    end })
            end
            table.insert(nodes, ui.text{ text = "life:" .. component.starts .. ":" .. component.updates .. ":" .. component.stops .. ":" .. component.previous })
            return ui.stack(nodes)
        end
        """, modules: ["counter/component.luau": counter])
        fixture.configure([Item(id: "a"), Item(id: "b", amount: 2)])
        let first = try fixture.display()
        let second = try fixture.display()
        let nodes = try fixture.render(first)
        XCTAssertEqual(try fixture.captions(second), ["root:0", "a:0:0:1", "b:0:0:2", "life:2:0:0:0"])
        XCTAssertEqual(fixture.invoke(first, nodes[3].action), OMNI_OK, fixture.message)
        XCTAssertEqual(try fixture.captions(first), ["root:0", "a:1:1:1", "b:0:0:2", "life:2:0:0:0"])
        XCTAssertEqual(try fixture.captions(second), ["root:0", "a:1:0:1", "b:0:0:2", "life:2:0:0:0"])
        XCTAssertEqual(fixture.invoke(first, nodes[2].action), OMNI_OK, fixture.message)
        XCTAssertEqual(try fixture.captions(first).first, "root:1")
        fixture.configure([Item(id: "a", amount: 3), Item(id: "b", amount: 2)])
        XCTAssertEqual(try fixture.captions(first), ["root:1", "a:1:1:3", "b:0:0:2", "life:2:1:0:1"])
        fixture.configure([Item(id: "a", enabled: false, amount: 3), Item(id: "b", amount: 2)])
        XCTAssertEqual(try fixture.captions(first), ["root:1", "b:0:0:2", "life:2:1:1:1"])
        fixture.configure([Item(id: "a", amount: 3), Item(id: "b", amount: 2)])
        XCTAssertEqual(try fixture.captions(first), ["root:1", "a:0:0:3", "b:0:0:2", "life:3:1:1:1"])
        fixture.configure([])
        XCTAssertEqual(try fixture.captions(first), ["root:1", "life:3:1:3:1"])
    }

    func testComponentFailuresAndRemovedHandlersStayInsideComponentBoundary() throws {
        let fixture = try Fixture("""
        function render(ctx)
            return ui.stack{
                ui.component{ id = "bad", onClick = function(root) root.state.clicked = true end },
                ui.text{ text = tostring(ctx.state.clicked or false) },
                ui.text{ text = ctx.data.components[1] and ctx.data.components[1].status or "removed" },
            }
        end
        """, modules: ["bad/component.luau": """
        return { views = { compact = function(ctx)
            return ui.text{ text = "alive", onClick = function() error("component click failed") end }
        end } }
        """])
        fixture.configure([Item(id: "bad", widget: "bad")])
        let display = try fixture.display()
        let nodes = try fixture.render(display)
        for _ in 0 ..< 6 {
            XCTAssertEqual(fixture.invoke(display, nodes[2].action), OMNI_ERR_COMPONENT)
        }
        XCTAssertEqual(fixture.invoke(display, nodes[1].action), OMNI_OK, fixture.message)
        XCTAssertEqual(try fixture.captions(display), ["alive", "true", "failed"])
        let retained = try fixture.render(display)
        fixture.configure([])
        XCTAssertEqual(fixture.invoke(display, retained[2].action), OMNI_ERR_STALE_ACTION)
        XCTAssertEqual(fixture.invoke(display, retained[1].action), OMNI_OK, fixture.message)
        XCTAssertEqual(try fixture.captions(display), ["true", "removed"])
    }

    func testViewActivityAndEncodingErrorsDoNotAbortRoot() throws {
        let fixture = try Fixture("""
        function render(ctx)
            assert(omniwm.components.activity("activity") == nil)
            local result = ui.stack{
                ui.component{ id = "view" }, ui.component{ id = "encode" },
                ui.text{ text = "root survived" },
            }
            if ctx.data.checkEncoded then
                assert(ctx.data.components[1].status == "failed")
                assert(ctx.data.components[2].status == "failed")
            end
            return result
        end
        """, modules: [
            "view/component.luau": "return { views = { compact = function() error('view failed') end } }",
            "encode/component.luau": "return { views = { compact = function() return ui.path{ d = 'M0 0', viewBox = 'invalid' } end } }",
            "activity/component.luau": "return { views = {}, activity = function() error('activity failed') end }"
        ])
        fixture.configure([
            Item(id: "view", widget: "view"),
            Item(id: "encode", widget: "encode"),
            Item(id: "activity", widget: "activity")
        ])
        let display = try fixture.display()
        XCTAssertEqual(try fixture.captions(display), ["root survived"])
        XCTAssertEqual(omni_instance_set_number(display, "checkEncoded", 1), OMNI_OK)
        XCTAssertEqual(try fixture.captions(display), ["root survived"])
    }

    func testPropsAreReadonlyBoundedValuesAndInvalidInputsAreContained() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local value
            local mode = ctx.data.mode or 0
            if mode == 0 then value = { list = {1, 2}, label = "ok" }
            elseif mode == 1 then value = function() end
            elseif mode == 2 then value = {}; value.self = value
            elseif mode == 3 then value = string.rep("x", 65536)
            elseif mode == 4 then value = { bad = 0 / 0 }
            else value = {}; local next = value; for i = 1, 65 do next.child = {}; next = next.child end end
            local child = ui.component{ id = "a", w = 80, h = 20, props = value }
            if mode == 0 then assert(ctx.data.components[1].status == "ready")
            else assert(ctx.data.components[1].status == "failed" and ctx.data.components[1].error) end
            return ui.stack{ child, ui.text{ text = "root survived" } }
        end
        """, modules: ["counter/component.luau": """
        return { views = { compact = function(ctx)
            assert(ctx.view.w == 80 and ctx.view.h == 20 and ctx.view.name == "compact")
            assert(table.isfrozen(ctx.view.props) and table.isfrozen(ctx.view.props.list))
            assert(ctx.view.props.list[2] == 2)
            return ui.text{ text = ctx.view.props.label }
        end } }
        """])
        fixture.configure([Item(id: "a")])
        let display = try fixture.display()
        XCTAssertEqual(try fixture.captions(display), ["ok", "root survived"])
        for mode in 1 ... 5 {
            XCTAssertEqual(omni_instance_set_number(display, "mode", Double(mode)), OMNI_OK)
            XCTAssertEqual(try fixture.captions(display), ["root survived"])
        }
    }

    func testComponentResolutionAssetsAndPostLoadInjection() throws {
        let fixture = try Fixture("""
        local base = require("@component/base")
        assert(base.asset == "@omni-asset:base/icon.png")
        assert(base.helper == 42)
        function render(ctx)
            return ui.component{ id = "custom" }
        end
        """, modules: [
            "base/component.luau": """
            local asset = omniwm.asset("@self/icon.png")
            local helper = require("@self/helper")
            assert(not pcall(omniwm.asset, "@self/../outside.png"))
            return { asset = asset, helper = helper, views = { compact = function()
                return ui.image{ image = asset }
            end } }
            """,
            "base/helper.luau": "return 42"
        ])
        let custom = """
        local base = require("@component/base")
        local own = omniwm.asset("@self/icon.png")
        assert(own == "@omni-asset:custom/icon.png")
        return { views = { compact = function(ctx)
            return ui.stack{ base.views.compact(ctx), ui.image{ image = own } }
        end } }
        """
        let path = "profile/widgets/custom/component.luau"
        XCTAssertEqual(omni_vm_add_module(fixture.vm, path, path.utf8.count, custom, custom.utf8.count), OMNI_OK)
        fixture.configure([Item(id: "custom", widget: "custom")])
        let nodes = try fixture.render(fixture.display())
        XCTAssertEqual(
            nodes.filter { $0.kind == 5 }.map { fixture.text.string($0.text) },
            ["@omni-asset:base/icon.png", "@omni-asset:custom/icon.png"]
        )
    }

    func testModuleCapsRejectOverflowAndCanBeRaisedExplicitly() throws {
        let fixture = try Fixture("function render(ctx) return ui.box{} end", modules: [:])
        XCTAssertEqual(omni_vm_set_module_limit(fixture.vm, 1), OMNI_OK)
        let first = "profile/widgets/root/first.luau"
        let second = "profile/widgets/root/second.luau"
        XCTAssertEqual(omni_vm_add_module(fixture.vm, first, first.utf8.count, "return 1", 8), OMNI_OK)
        XCTAssertTrue(omni_vm_module_matches(fixture.vm, first, first.utf8.count, "return 1", 8))
        XCTAssertFalse(omni_vm_module_matches(fixture.vm, first, first.utf8.count, "return 2", 8))
        XCTAssertFalse(omni_vm_module_matches(fixture.vm, second, second.utf8.count, "return 2", 8))
        XCTAssertNotEqual(omni_vm_add_module(fixture.vm, second, second.utf8.count, "return 2", 8), OMNI_OK)
        XCTAssertEqual(omni_vm_set_module_limit(fixture.vm, 512), OMNI_OK)
        XCTAssertEqual(omni_vm_add_module(fixture.vm, second, second.utf8.count, "return 2", 8), OMNI_OK)
        XCTAssertEqual(omni_vm_set_module_limit(fixture.vm, 1), OMNI_ERR_RUNTIME)
        XCTAssertEqual(omni_vm_set_module_limit(fixture.vm, 513), OMNI_ERR_RUNTIME)
    }

    func testUnconfiguredMountTracksConfigurationChanges() throws {
        let fixture = try Fixture("""
        function render(ctx) return ui.component{ id = "a" } end
        """, modules: ["counter/component.luau": counter])
        let display = try fixture.display()
        _ = try fixture.render(display)
        fixture.configure([Item(id: "a")])
        XCTAssertTrue(omni_instance_needs_render(display, OMNI_VIEW_BAR, ShellDataKey.components.bit))
        XCTAssertEqual(try fixture.captions(display), ["a:0:0:1"])
    }

    func testPropsAcceptExactlyDepth64AndEncoded64KiB() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local value = {}
            local cursor = value
            for i = 1, 64 do cursor.child = {}; cursor = cursor.child end
            return ui.stack{
                ui.component{ id = "deep", props = value },
                ui.component{ id = "large", props = string.rep("x", 65531) },
            }
        end
        """, modules: ["counter/component.luau": """
        return { views = { compact = function(ctx)
            if ctx.instance.id == "deep" then
                local depth, value = 0, ctx.view.props
                while value.child do depth += 1; value = value.child end
                assert(depth == 64)
            else
                assert(#ctx.view.props == 65531)
            end
            return ui.text{ text = ctx.instance.id }
        end } }
        """])
        fixture.configure([Item(id: "deep"), Item(id: "large")])
        XCTAssertEqual(try fixture.captions(fixture.display()), ["deep", "large"])
    }

    func testErrorObjectsAndReturnedMetatablesStayContained() throws {
        let fixture = try Fixture("""
        function render(ctx)
            local child = ui.component{ id = "a" }
            local item = ctx.data.components[1]
            if ctx.data.phase == 1 then assert(item.error == "(non-string error)") end
            return ui.stack{ child, ui.text{ text = "root survived" }, ui.text{ text = item.status } }
        end
        """, modules: ["counter/component.luau": """
        return { views = { compact = function(ctx)
            if ctx.instance.options.amount == 1 then
                error(setmetatable({}, { __tostring = function() error("format escaped") end }))
            elseif ctx.instance.options.amount == 2 then
                return setmetatable({}, { __metatable = "protected" })
            end
            return setmetatable({ kind = 2, text = "metatable accepted" }, {
                __newindex = function() error("key escaped") end,
            })
        end } }
        """])
        fixture.configure([Item(id: "a")])
        let display = try fixture.display()
        _ = try fixture.render(display)
        XCTAssertEqual(omni_instance_set_number(display, "phase", 1), OMNI_OK)
        XCTAssertEqual(try fixture.captions(display), ["root survived", "failed"])
        XCTAssertEqual(omni_instance_set_number(display, "phase", 2), OMNI_OK)
        fixture.configure([Item(id: "a", amount: 2)])
        _ = try fixture.render(display)
        XCTAssertEqual(try fixture.captions(display), ["root survived", "failed"])
        fixture.configure([Item(id: "a", amount: 3)])
        XCTAssertEqual(try fixture.captions(display), ["metatable accepted", "root survived", "ready"])
    }
}
