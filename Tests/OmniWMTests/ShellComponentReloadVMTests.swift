// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ShellComponentReloadVMTests: XCTestCase {
    private final class Fixture {
        let vm: OpaquePointer
        let display: OpaquePointer
        let text = ShellTextStore()
        var error = [CChar](repeating: 0, count: 512)

        init(root: String, modules: [String: String]) throws {
            let created = try XCTUnwrap(ShellVM.make(memoryLimit: 32 << 20))
            for (name, source) in modules {
                let path = "profile/widgets/\(name)"
                XCTAssertEqual(omni_vm_add_module(created, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            var message = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(omni_vm_load(
                created, "@profile/widgets/root/init.luau", root, root.utf8.count,
                100_000_000, &message, message.count
            ), OMNI_OK, message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            vm = created
            display = try XCTUnwrap(omni_instance_create(created))
        }

        deinit {
            omni_instance_destroy(display)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func configure(_ widgets: [String]) {
            var writer = ShellValueWriter()
            writer.array(widgets.count)
            for widget in widgets {
                writer.map(4)
                writer.key("id")
                writer.string(widget)
                writer.key("widget")
                writer.string(widget)
                writer.key("enabled")
                writer.bool(true)
                writer.key("options")
                writer.map(0)
            }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        func reload(_ widgets: [String], _ modules: [(String, String?)], budget: UInt64 = 100_000_000) -> omni_status {
            var writer = ShellValueWriter()
            writer.array(widgets.count)
            for widget in widgets { writer.string(widget) }
            var storage: [CChar] = []
            let spans = modules.map { name, source in
                let path = "profile/widgets/\(name)"
                let start = storage.count
                storage.append(contentsOf: path.utf8.map { CChar(bitPattern: $0) })
                let code = storage.count
                if let source { storage.append(contentsOf: source.utf8.map { CChar(bitPattern: $0) }) }
                return (start, code - start, code, storage.count - code, source == nil)
            }
            return storage.withUnsafeBufferPointer { buffer in
                let changes = spans.map { span in
                    omni_module_change(
                        path: buffer.baseAddress?.advanced(by: span.0), path_length: span.1,
                        source: span.4 ? nil : buffer.baseAddress?.advanced(by: span.2),
                        source_length: span.3, remove: span.4
                    )
                }
                return writer.bytes.withUnsafeBufferPointer { names in
                    changes.withUnsafeBufferPointer { changes in
                        omni_vm_reload_components(
                            vm, names.baseAddress, names.count, changes.baseAddress, changes.count,
                            budget, &error, error.count
                        )
                    }
                }
            }
        }

        func matches(_ module: String, _ source: String) -> Bool {
            let path = "profile/widgets/\(module)"
            return omni_vm_module_matches(vm, path, path.utf8.count, source, source.utf8.count)
        }

        func render() throws -> [omni_wire_node] {
            var stats = omni_render_stats()
            XCTAssertEqual(omni_instance_render(
                display, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count
            ), OMNI_OK, message)
            var length = 0
            let pointer = try XCTUnwrap(omni_instance_output(display, OMNI_VIEW_BAR, &length))
            let wire = Array(UnsafeBufferPointer(start: pointer, count: length))
            text.ingest(wire: wire)
            return wire.withUnsafeBytes { bytes in
                let header = bytes.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    bytes.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * MemoryLayout<omni_wire_node>
                            .stride,
                        as: omni_wire_node.self
                    )
                }
            }
        }

        func captions() throws -> [String] {
            try render().filter { $0.text != 0 }.map { text.string($0.text) }
        }

        func invoke(_ action: UInt32) -> omni_status {
            omni_instance_invoke(display, OMNI_VIEW_BAR, action, 0, nil, 0, 100_000_000, &error, error.count)
        }
    }

    private static func component(_ label: String, initial: Int = 1) -> String {
        """
        return { init = function(instance) instance.state.value = \(initial) end,
            views = { compact = function(ctx)
                ctx.state.calls = (ctx.state.calls or 0) + 1
                return ui.text{ text = "\(label):" .. ctx.instance.state.value .. ":" .. ctx.state.calls,
                    onClick = function(c) c.instance.state.value += 1 end }
            end } }
        """
    }

    func testScopedReloadResetsOnlyAffectedOwnerAndRejectsOldActions() throws {
        let original = Self.component("old")
        let replacement = Self.component("new", initial: 40)
        let fixture = try Fixture(root: """
        function render(ctx)
            return ui.stack{ ui.text{ text = "root:" .. (ctx.state.mark or 0),
                onClick = function(c) c.state.mark = 1 end },
                ui.component{ id = "a" }, ui.component{ id = "b" } }
        end
        """, modules: ["a/component.luau": original, "b/component.luau": Self.component("b")])
        fixture.configure(["a", "b"])
        let actions = try fixture.render().filter { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }.map(\.action)
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(fixture.invoke(actions[0]), OMNI_OK)
        XCTAssertEqual(fixture.invoke(actions[1]), OMNI_OK)
        XCTAssertEqual(try fixture.captions(), ["root:1", "old:2:2", "b:1:1"])
        XCTAssertEqual(fixture.reload(["a"], [("a/component.luau", replacement)]), OMNI_OK, fixture.message)
        XCTAssertEqual(fixture.invoke(actions[1]), OMNI_ERR_STALE_ACTION)
        fixture.configure(["a", "b"])
        XCTAssertEqual(try fixture.captions(), ["root:1", "new:40:1", "b:1:1"])
        XCTAssertEqual(fixture.invoke(actions[1]), OMNI_ERR_STALE_ACTION)
        XCTAssertEqual(fixture.invoke(actions[2]), OMNI_OK)
    }

    func testDeclaredDependentReloadSeesReplacementExport() throws {
        let fixture = try Fixture(root: """
        function render(ctx) return ui.stack{ ui.component{ id = "dependent" }, ui.component{ id = "b" } } end
        """, modules: [
            "a/component.luau": "return { views = {}, label = 'old' }",
            "dependent/component.luau": """
            local dependency = require("@component/a")
            return { views = { compact = function(ctx) return ui.text{ text = dependency.label } end } }
            """,
            "b/component.luau": Self.component("b")
        ])
        fixture.configure(["dependent", "b"])
        XCTAssertEqual(try fixture.captions(), ["old", "b:1:1"])
        XCTAssertEqual(fixture.reload(["a", "dependent"], [
            ("a/component.luau", "return { views = {}, label = 'new' }")
        ]), OMNI_OK, fixture.message)
        fixture.configure(["dependent", "b"])
        XCTAssertEqual(try fixture.captions(), ["new", "b:1:1"])
    }

    func testRootRetainedExportRequiresFullReloadBeforeAnyRetirement() throws {
        let source = Self.component("old")
        let fixture = try Fixture(root: """
        local definition = require("@component/a")
        function render(ctx)
            assert(type(definition.views.compact) == "function")
            return ui.component{ id = "a" }
        end
        """, modules: ["a/component.luau": source])
        fixture.configure(["a"])
        let action = try XCTUnwrap(fixture.render().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        XCTAssertEqual(fixture.reload(["a"], [("a/component.luau", Self.component("new"))]), OMNI_ERR_RELOAD_REQUIRED)
        XCTAssertTrue(fixture.matches("a/component.luau", source))
        XCTAssertEqual(fixture.invoke(action), OMNI_OK)
        XCTAssertEqual(try fixture.captions(), ["old:2:2"])
    }

    func testCachedRootImportIncludesItsTransitiveDependencies() throws {
        let fixture = try Fixture(root: """
        function render(ctx)
            local proxy = require("@component/proxy")
            return ui.text{ text = proxy.label }
        end
        """, modules: [
            "a/component.luau": "return { views = {}, label = 'old' }",
            "proxy/component.luau": "local a = require('@component/a'); return { views = {}, label = a.label }"
        ])
        fixture.configure(["proxy"])
        XCTAssertEqual(try fixture.captions(), ["old"])
        XCTAssertEqual(
            fixture.reload(["a"], [("a/component.luau", "return { views = {}, label = 'new' }")]),
            OMNI_ERR_RELOAD_REQUIRED
        )
        XCTAssertEqual(try fixture.captions(), ["old"])
    }

    func testInvalidBatchAndModuleLimitLeaveLiveModulesAndOwnersIntact() throws {
        let source = Self.component("old")
        let fixture = try Fixture(
            root: "function render(ctx) return ui.component{ id = 'a' } end",
            modules: ["a/component.luau": source]
        )
        fixture.configure(["a"])
        let action = try XCTUnwrap(fixture.render().first { $0.action & UInt32(OMNI_ACTION_HANDLER) != 0 }).action
        XCTAssertEqual(
            fixture.reload(["a"], [("a/component.luau", Self.component("new")), ("b/component.luau", source)]),
            OMNI_ERR_RUNTIME
        )
        XCTAssertTrue(fixture.matches("a/component.luau", source))
        var malformed = ShellValueWriter()
        malformed.map(0)
        XCTAssertEqual(malformed.bytes.withUnsafeBufferPointer {
            omni_vm_reload_components(
                fixture.vm,
                $0.baseAddress,
                $0.count,
                nil,
                0,
                100_000_000,
                &fixture.error,
                fixture.error.count
            )
        }, OMNI_ERR_RUNTIME)
        XCTAssertEqual(fixture.invoke(action), OMNI_OK)
        XCTAssertEqual(omni_vm_set_module_limit(fixture.vm, 1), OMNI_OK)
        XCTAssertEqual(fixture.reload(["a"], [("a/helper.luau", "return 1")]), OMNI_ERR_RUNTIME)
        XCTAssertTrue(fixture.matches("a/component.luau", source))
        XCTAssertEqual(try fixture.captions(), ["old:2:2"])
    }

    func testRemovalAndReadditionClearStaleModuleExports() throws {
        let fixture = try Fixture(root: "function render(ctx) return ui.component{ id = 'a' } end", modules: [
            "a/component.luau": "local value = require('@self/old'); return { views = { compact = function() return ui.text{ text = value } end } }",
            "a/old.luau": "return 'old'"
        ])
        fixture.configure(["a"])
        XCTAssertEqual(try fixture.captions(), ["old"])
        fixture.configure([])
        XCTAssertEqual(fixture.reload(["a"], [
            ("a/old.luau", nil), ("a/new.luau", "return 'new'"),
            (
                "a/component.luau",
                "local value = require('@self/new'); return { views = { compact = function() return ui.text{ text = value } end } }"
            )
        ]), OMNI_OK, fixture.message)
        XCTAssertFalse(fixture.matches("a/old.luau", "return 'old'"))
        fixture.configure(["a"])
        XCTAssertEqual(try fixture.captions(), ["new"])
    }

    func testInvalidReplacementCompileAndInitRemainContained() throws {
        let source = Self.component("good")
        let fixture = try Fixture(root: """
        function render(ctx)
            return ui.stack{ ui.text{ text = ctx.data.components[1].status }, ui.component{ id = "a" } }
        end
        """, modules: ["a/component.luau": source])
        fixture.configure(["a"])
        XCTAssertEqual(try fixture.captions(), ["ready", "good:1:1"])
        for invalid in ["return {", "return { views = {}, init = function() error('init failed') end }"] {
            XCTAssertEqual(fixture.reload(["a"], [("a/component.luau", invalid)]), OMNI_OK)
            fixture.configure(["a"])
            XCTAssertEqual(try fixture.captions(), ["failed"])
        }
        XCTAssertEqual(fixture.reload(["a"], [("a/component.luau", source)]), OMNI_OK)
        fixture.configure(["a"])
        XCTAssertEqual(try fixture.captions(), ["ready", "good:1:1"])
    }

    func testDeinitFailureStillCancelsServicesAndCommitsReplacement() throws {
        for teardown in ["error('deinit failed')", "while true do end"] {
            let fixture = try Fixture(
                root: "function render(ctx) return ui.component{ id = 'a' } end",
                modules: ["a/component.luau": """
                return { init = function(instance) omniwm.after(60, function() error("stale callback") end) end,
                    deinit = function(instance) \(teardown) end,
                    views = { compact = function() return ui.text{ text = "old" } end } }
                """]
            )
            fixture.configure(["a"])
            var request = omni_service_request()
            XCTAssertTrue(omni_vm_next_service(fixture.vm, &request))
            XCTAssertFalse(request.cancelled)
            let replacement = Self.component("new")
            XCTAssertEqual(
                fixture.reload(["a"], [("a/component.luau", replacement)], budget: 2_000_000),
                OMNI_ERR_COMPONENT
            )
            XCTAssertTrue(fixture.matches("a/component.luau", replacement))
            var cancellation = omni_service_request()
            XCTAssertTrue(omni_vm_next_service(fixture.vm, &cancellation))
            XCTAssertTrue(cancellation.cancelled)
            XCTAssertEqual(cancellation.id, request.id)
            var handled = true
            XCTAssertEqual(omni_vm_complete_service(
                fixture.vm, request.owner, request.id, 0, nil, 0, 100_000_000,
                &handled, &fixture.error, fixture.error.count
            ), OMNI_OK)
            XCTAssertFalse(handled)
            fixture.configure(["a"])
            XCTAssertEqual(try fixture.captions(), ["new:1:1"])
        }
    }

    func testFinalDeinitStoreSnapshotReachesReplacementInit() throws {
        let fixture = try Fixture(
            root: "function render(ctx) return ui.component{ id = 'a' } end",
            modules: ["a/component.luau": """
            return { deinit = function(instance) assert(omniwm.store.set("final", "saved")) end, views = {} }
            """]
        )
        fixture.configure(["a"])
        XCTAssertEqual(fixture.reload(["a"], [("a/component.luau", """
        return { init = function(instance) instance.state.saved = omniwm.store.get("final") end,
            views = { compact = function(ctx) return ui.text{ text = ctx.instance.state.saved or "missing" } end } }
        """)]), OMNI_OK, fixture.message)
        fixture.configure(["a"])
        XCTAssertEqual(try fixture.captions(), ["saved"])
    }
}
