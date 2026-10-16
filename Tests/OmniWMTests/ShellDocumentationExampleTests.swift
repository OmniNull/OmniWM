// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellDocumentationExampleTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let vm: OpaquePointer
        let instance: OpaquePointer
        let text = ShellTextStore()
        var nodes: [omni_wire_node] = []
        var error = [CChar](repeating: 0, count: 512)

        init(root: URL, modules: [String: URL] = [:]) throws {
            vm = try XCTUnwrap(ShellVM.make(memoryLimit: 16 << 20))
            for (path, url) in modules {
                let source = try String(contentsOf: url, encoding: .utf8)
                XCTAssertEqual(omni_vm_add_module(vm, path, path.utf8.count, source, source.utf8.count), OMNI_OK)
            }
            let source = try String(contentsOf: root, encoding: .utf8)
            XCTAssertEqual(omni_vm_load(
                vm, "@profile/widgets/root/init.luau", source, source.utf8.count,
                100_000_000, &error, error.count
            ), OMNI_OK)
            instance = try XCTUnwrap(omni_instance_create(vm))
        }

        isolated deinit {
            omni_instance_destroy(instance)
            _ = omni_vm_destroy(vm)
        }

        var message: String {
            error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }

        func set(_ key: String, _ value: ShellServiceValue) {
            var writer = ShellValueWriter()
            value.write(to: &writer)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }

        func configure(_ resolution: ShellComponentCatalog.Resolution) {
            let bytes = ShellComponentCatalog.configurationBytes(
                instances: resolution.instances, descriptors: resolution.descriptors
            )
            XCTAssertEqual(bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
            }, OMNI_OK, message)
        }

        @discardableResult
        func render(_ view: omni_view = OMNI_VIEW_BAR) throws -> [String] {
            var stats = omni_render_stats()
            XCTAssertEqual(
                omni_instance_render(instance, view, 100_000_000, &stats, &error, error.count), OMNI_OK, message
            )
            var size = 0
            let output = try XCTUnwrap(omni_instance_output(instance, view, &size))
            let bytes = Array(UnsafeBufferPointer(start: output, count: size))
            text.ingest(wire: bytes)
            nodes = bytes.withUnsafeBytes { buffer in
                let header = buffer.loadUnaligned(as: omni_wire_header.self)
                return (0 ..< Int(header.node_count)).map {
                    buffer.loadUnaligned(
                        fromByteOffset: MemoryLayout<omni_wire_header>.stride
                            + $0 * MemoryLayout<omni_wire_node>.stride,
                        as: omni_wire_node.self
                    )
                }
            }
            return nodes.filter { $0.kind == ElementKind.label.rawValue }.map { text.string($0.text) }
        }

        func action(containing caption: String) throws -> UInt32 {
            let index = try XCTUnwrap(nodes.firstIndex { text.string($0.text) == caption })
            let parent = try XCTUnwrap((0 ... index).reversed().first {
                nodes[$0].action != 0 && Int(nodes[$0].subtree_end) > index
            })
            return nodes[parent].action
        }

        @discardableResult
        func invoke(
            _ action: UInt32, view: omni_view = OMNI_VIEW_BAR, event: ShellEvent = ShellEvent()
        ) -> [String] {
            XCTAssertEqual(event.bytes.withUnsafeBufferPointer {
                omni_instance_invoke(
                    instance, view, action, 0, $0.baseAddress, $0.count, 100_000_000, &error, error.count
                )
            }, OMNI_OK, message)
            defer { omni_instance_clear_messages(instance) }
            return (0 ..< omni_instance_message_count(instance, OMNI_MESSAGE_REQUEST)).map { index in
                var size = 0
                guard let output = omni_instance_message(instance, OMNI_MESSAGE_REQUEST, index, &size)
                else { return "" }
                return String(decoding: UnsafeRawBufferPointer(start: output, count: size), as: UTF8.self)
            }
        }
    }

    private var examples: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("website/public/examples/omnishell")
    }

    func testClockRendersLocalizedDataAndDeclaredDateSetting() throws {
        let schema = try XCTUnwrap(ShellRootSettings.load("hello-clock", directories: [examples]))
        XCTAssertEqual(schema.options["date"]?.defaultValue, .bool(true))
        XCTAssertEqual(try schema.values(applying: [:])["date"], .bool(true))
        let fixture = try Fixture(root: examples.appendingPathComponent("widgets/hello-clock/init.luau"))
        fixture.set("clock", .text("9:41 AM"))
        fixture.set("date", .text("Wed 14 Oct"))
        fixture.set("settings", .object([:]))
        XCTAssertEqual(try fixture.render(), ["9:41 AM", "Wed 14 Oct"])
        fixture.set("settings", .object(["date": .bool(false)]))
        XCTAssertEqual(try fixture.render(), ["9:41 AM"])
        fixture.set("clock", .text("9:42 AM"))
        XCTAssertEqual(try fixture.render(), ["9:42 AM"])
        fixture.set("settings", .object(["date": .bool(true)]))
        XCTAssertEqual(try fixture.render(), ["9:42 AM", "Wed 14 Oct"])
    }

    func testMenuNavigatesAndEmitsVolumeAndMenuCommands() throws {
        let fixture = try Fixture(root: examples.appendingPathComponent("widgets/quick-menu/init.luau"))
        XCTAssertEqual(try fixture.render(), ["Quick menu"])
        XCTAssertEqual(try fixture.action(containing: "Quick menu"), UInt32(OMNI_ACTION_POPOUT))
        XCTAssertEqual(try fixture.render(OMNI_VIEW_POPOUT), ["Audio…", "OmniWM menu", "Close"])
        XCTAssertEqual(try fixture.action(containing: "Close"), UInt32(OMNI_ACTION_POPOUT))
        XCTAssertEqual(
            fixture.invoke(try fixture.action(containing: "Audio…"), view: OMNI_VIEW_POPOUT), []
        )
        XCTAssertEqual(try fixture.render(OMNI_VIEW_POPOUT), ["Back", "Volume +5%", "Mute output", "Close"])
        XCTAssertEqual(
            fixture.invoke(try fixture.action(containing: "Volume +5%"), view: OMNI_VIEW_POPOUT), ["volume up 5"]
        )
        XCTAssertEqual(
            fixture.invoke(try fixture.action(containing: "Mute output"), view: OMNI_VIEW_POPOUT), ["volume mute"]
        )
        XCTAssertEqual(try fixture.action(containing: "Close"), UInt32(OMNI_ACTION_POPOUT))
        fixture.invoke(try fixture.action(containing: "Back"), view: OMNI_VIEW_POPOUT)
        XCTAssertEqual(try fixture.render(OMNI_VIEW_POPOUT), ["Audio…", "OmniWM menu", "Close"])
        XCTAssertEqual(
            fixture.invoke(try fixture.action(containing: "OmniWM menu"), view: OMNI_VIEW_POPOUT), ["shell menu"]
        )
    }

    func testIslandProfileValidatesAndMountsConfiguredViewsThroughInputTransitions() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shell) }
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        for name in ["tutorial-island", "widgets"] {
            try FileManager.default.copyItem(
                at: examples.appendingPathComponent(name), to: shell.appendingPathComponent(name)
            )
        }
        try Data("profile = \"tutorial-island\"\n".utf8).write(to: shell.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        let island = try XCTUnwrap(config.island)
        XCTAssertEqual(island.root, "tutorial-root")
        XCTAssertEqual(island.displays, .main)
        XCTAssertEqual(island.fullscreen, .hide)
        XCTAssertEqual(island.width, 420)
        XCTAssertEqual(island.height, 240)
        let resolution = try ShellComponentCatalog.resolve(island.components, directories: config.directories)
        XCTAssertEqual(resolution.instances.first?.options["label"], .string("My desk"))
        let descriptor = try XCTUnwrap(resolution.descriptors.first)
        XCTAssertEqual(descriptor.views, ["compact", "expanded"])
        XCTAssertEqual(descriptor.options["label"]?.defaultValue, .string("Desk"))
        let fixture = try Fixture(
            root: examples.appendingPathComponent("tutorial-island/widgets/tutorial-root/init.luau"),
            modules: ["profile/widgets/demo-clock/component.luau": examples
                .appendingPathComponent("widgets/demo-clock/component.luau")]
        )
        fixture.configure(resolution)
        fixture.set("clock", .text("9:41 AM"))
        fixture.set("date", .text("Wed 14 Oct"))
        fixture.set("island", .object([
            "size": .object(["w": .number(420), "h": .number(240)]),
            "menuBar": .number(24), "notch": .object(["h": .number(32)])
        ]))
        XCTAssertEqual(try fixture.render(), ["My desk: 9:41 AM"])
        XCTAssertEqual(fixture.nodes.first { $0.kind == ElementKind.label.rawValue }?.color, 0xFFFFFFFF)
        XCTAssertEqual(fixture.nodes.first { $0.kind == ElementKind.symbol.rawValue }?.color, 0xFFFFFFFF)
        let compact = try XCTUnwrap(fixture.nodes.first { $0.action != 0 })
        XCTAssertEqual(compact.width, 220)
        XCTAssertEqual(compact.height, 36)
        XCTAssertEqual(compact.dy, 40)
        fixture.invoke(compact.action)
        XCTAssertEqual(try fixture.render(), ["My desk", "9:41 AM", "Wed 14 Oct"])
        XCTAssertEqual(fixture.nodes.first { fixture.text.string($0.text) == "9:41 AM" }?.color, 0xFFFFFFFF)
        let expanded = try XCTUnwrap(fixture.nodes.first { $0.outside_press_action != 0 })
        XCTAssertEqual(expanded.width, 340)
        XCTAssertEqual(expanded.height, 164)
        var outside = ShellEvent()
        outside.kind = .outsidePress
        fixture.invoke(expanded.outside_press_action, event: outside)
        XCTAssertEqual(try fixture.render(), ["My desk: 9:41 AM"])
        fixture.invoke(try fixture.action(containing: "My desk: 9:41 AM"))
        XCTAssertEqual(try fixture.render(), ["My desk", "9:41 AM", "Wed 14 Oct"])
        var key = ShellEvent()
        key.kind = .key
        key.key = "escape"
        fixture.invoke(try XCTUnwrap(fixture.nodes.first { $0.key_action != 0 }).key_action, event: key)
        XCTAssertEqual(try fixture.render(), ["My desk: 9:41 AM"])
        var instances = resolution.instances
        instances[0].options["label"] = .string("Studio")
        fixture.configure(try ShellComponentCatalog.resolve(instances, directories: config.directories))
        XCTAssertEqual(try fixture.render(), ["Studio: 9:41 AM"])
    }
}
