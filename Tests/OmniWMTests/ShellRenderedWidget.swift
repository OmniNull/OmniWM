// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellRenderedWidget {
    let vm: OpaquePointer
    let instance: OpaquePointer
    let surface: ShellWidgetSurface
    let resources: ShellResources
    let text = ShellTextStore()
    var clicks: [(action: String, button: ShellEvent.Button)] = []
    var actions: [UInt32] = []

    convenience init(_ name: String) throws {
        let url = try XCTUnwrap(ShellConfig.bundledWidget(name))
        try self.init(name: name, source: String(contentsOf: url, encoding: .utf8))
    }

    init(
        name: String,
        source: String,
        directories: [URL] = [],
        modules: [ShellWidgetSource.Module] = [],
        chunk: String? = nil,
        scale: CGFloat = 2,
        resources: ShellResources? = nil
    ) throws {
        vm = try XCTUnwrap(ShellVM.make(memoryLimit: 8 << 20))
        for module in modules {
            XCTAssertEqual(
                omni_vm_add_module(vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count),
                OMNI_OK
            )
        }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_vm_load(vm, chunk ?? "=\(name)", source, source.utf8.count, 100_000_000, &error, error.count),
            OMNI_OK
        )
        instance = try XCTUnwrap(omni_instance_create(vm))
        self.resources = resources ?? ShellResources(motion: MotionPolicy(animationsEnabled: false))
        surface = ShellWidgetSurface(scale: scale, resources: self.resources, directories: directories)
        surface.onAction = { [unowned self] click in
            actions.append(click.action)
            clicks.append((text.string(click.action), click.event.button))
        }
    }

    isolated deinit {
        omni_instance_destroy(instance)
        _ = omni_vm_destroy(vm)
    }

    func render(_ bar: ShellBarData) {
        var writer = ShellValueWriter()
        bar.write(to: &writer)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(instance, "bar", $0.baseAddress, $0.count)
        }
        let output = render(OMNI_VIEW_BAR)
        XCTAssertTrue(surface.apply(output, text: text))
        ShellLayerScene.engineQueue.sync {}
    }

    func renderPopout() -> [TreeNode] {
        tree(render(OMNI_VIEW_POPOUT))
    }

    func set(_ key: String, _ write: (inout ShellValueWriter) -> Void) {
        var writer = ShellValueWriter()
        write(&writer)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(instance, key, $0.baseAddress, $0.count)
        }
    }

    func layoutPopout() {
        XCTAssertTrue(surface.apply(render(OMNI_VIEW_POPOUT), text: text))
    }

    @discardableResult
    func invoke(_ action: UInt32, view: omni_view = OMNI_VIEW_BAR, event: ShellEvent = ShellEvent()) -> [String] {
        var error = [CChar](repeating: 0, count: 256)
        let status = event.bytes.withUnsafeBufferPointer {
            omni_instance_invoke(instance, view, action, 0, $0.baseAddress, $0.count, 25_000_000, &error, error.count)
        }
        XCTAssertEqual(
            status,
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        defer { omni_instance_clear_messages(instance) }
        return (0 ..< omni_instance_message_count(instance, OMNI_MESSAGE_REQUEST)).map { index in
            var length = 0
            guard let message = omni_instance_message(instance, OMNI_MESSAGE_REQUEST, index, &length) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: message, count: length), as: UTF8.self)
        }
    }

    func tree() -> [TreeNode] {
        tree(output())
    }

    private func render(_ view: omni_view) -> [UInt8] {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        let status = omni_instance_render(instance, view, 100_000_000, &stats, &error, error.count)
        XCTAssertEqual(
            status,
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        guard status == OMNI_OK else { return [] }
        let output = output(view)
        text.ingest(wire: output)
        return output
    }

    private func tree(_ output: [UInt8]) -> [TreeNode] {
        let capacity = 1024
        let nodes = UnsafeMutablePointer<TreeNode>.allocate(capacity: capacity)
        defer { nodes.deallocate() }
        nodes.initialize(repeating: TreeNode(kind: .group, subtreeEnd: 1), count: capacity)
        let count = output.withUnsafeBytes {
            ShellWireDecoder.decode($0.baseAddress!, length: $0.count, into: nodes, capacity: capacity)
        }
        return Array(UnsafeBufferPointer(start: nodes, count: count))
    }

    func strings(_ view: omni_view = OMNI_VIEW_BAR) -> [String] {
        output(view).withUnsafeBytes { buffer in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            return (0 ..< Int(header.node_count)).flatMap { index -> [String] in
                let node = buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + index * MemoryLayout<omni_wire_node>.stride,
                    as: omni_wire_node.self
                )
                return [node.text, node.help].filter { $0 != 0 }.map(text.string)
            }
        }
    }

    func layers() -> [CALayer] {
        surface.view.layer?.flattened ?? []
    }

    func output(_ view: omni_view = OMNI_VIEW_BAR) -> [UInt8] {
        var size = 0
        guard let bytes = omni_instance_output(instance, view, &size) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes, count: size))
    }
}
