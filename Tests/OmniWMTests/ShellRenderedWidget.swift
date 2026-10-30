// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
    var events: [ShellClick] = []
    var invocation: UInt64?

    convenience init(_ name: String) throws {
        let url = try XCTUnwrap(ShellConfig.bundledWidget(name))
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let source = try ShellWidgetSourceLoader.build(.init(
            name: name, shellDirectory: defaults.deletingLastPathComponent(),
            sourceURL: url, directories: [defaults], profile: "default"
        ))
        try self.init(name: name, source: source.main, modules: source.modules, chunk: source.chunk)
    }

    convenience init(source: ShellWidgetSource, scale: CGFloat = 2, resources: ShellResources? = nil) throws {
        try self.init(
            name: source.chunk, source: source.main, modules: source.modules, chunk: source.chunk, scale: scale,
            resources: resources, fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
        guard source.isIslandRoot else { return }
        configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
    }

    init(
        name: String,
        source: String,
        directories: [URL] = [],
        modules: [ShellWidgetSource.Module] = [],
        chunk: String? = nil,
        scale: CGFloat = 2,
        resources: ShellResources? = nil,
        fonts: ShellFontSet = .init(),
        memoryLimit: Int = 8 << 20,
        moduleLimit: Int? = nil
    ) throws {
        vm = try XCTUnwrap(ShellVM.make(memoryLimit: memoryLimit, fonts: fonts))
        if let moduleLimit { XCTAssertEqual(omni_vm_set_module_limit(vm, moduleLimit), OMNI_OK) }
        for module in modules {
            XCTAssertEqual(
                omni_vm_add_module(vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count),
                OMNI_OK
            )
        }
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_vm_load(vm, chunk ?? "=\(name)", source, source.utf8.count, 100_000_000, &error, error.count),
            OMNI_OK,
            "\(name): " + String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        instance = try XCTUnwrap(omni_instance_create(vm))
        self.resources = resources ?? ShellResources(motion: MotionPolicy(animationsEnabled: false))
        surface = ShellWidgetSurface(scale: scale, resources: self.resources, directories: directories)
        surface.onAction = { [unowned self] click in
            actions.append(click.action)
            clicks.append((text.string(click.action), click.event.button))
            events.append(click)
            if let token = click.event.trackingToken {
                let id = ShellInvocation.next()
                surface.bindGestureInvocation(trackToken: token, invocationID: id)
                invocation = id
            }
        }
    }

    isolated deinit {
        omni_instance_destroy(instance)
        _ = omni_vm_destroy(vm)
    }

    func configure(_ components: [UInt8]) {
        var error = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(components.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, 100_000_000, &error, error.count)
        }, OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    func render(_ bar: ShellBarData, acknowledgement: UInt64 = 0) {
        var writer = ShellValueWriter()
        bar.write(to: &writer)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(instance, "bar", $0.baseAddress, $0.count)
        }
        let output = render(OMNI_VIEW_BAR)
        XCTAssertTrue(surface.apply(output, text: text, gestureAcknowledgement: acknowledgement))
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
            guard buffer.count >= MemoryLayout<omni_wire_header>.stride else {
                XCTFail("The widget rendered no tree (\(buffer.count) bytes)")
                return []
            }
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            guard buffer.count >= MemoryLayout<omni_wire_header>.stride
                + Int(header.node_count) * MemoryLayout<omni_wire_node>.stride
            else {
                XCTFail("The widget tree is shorter than its \(header.node_count) nodes")
                return []
            }
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
