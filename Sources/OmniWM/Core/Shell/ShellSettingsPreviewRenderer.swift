// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

actor ShellSettingsPreviewRenderer {
    struct Tree: Sendable {
        let name: String
        let wire: [UInt8]
        let strings: [UInt8]
        let stringCount: Int
        let directories: [URL]
        let packages: [String: URL]
    }

    static let shared = ShellSettingsPreviewRenderer()
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.settings.preview", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func render(
        inputs: [ShellWidgetSourceLoader.Input],
        values: [String: [UInt8]],
        settings: [String: [UInt8]],
        expanded: Bool?
    ) throws -> [Tree] {
        try inputs.map { input in
            try Task.checkCancellation()
            let source = try ShellWidgetSourceLoader.build(input)
            guard let vm = ShellVM.make(memoryLimit: ShellWidgetPackage.memoryLimit) else {
                throw ShellScriptFailure(kind: .memory, message: "The preview could not create a script VM.")
            }
            defer { _ = omni_vm_destroy(vm) }
            var error = [CChar](repeating: 0, count: 512)
            func check(_ status: omni_status) throws {
                try Self.check(status, error: error)
            }
            try load(source, into: vm, expanded: expanded, error: &error)
            guard let instance = omni_instance_create(vm) else {
                throw ShellScriptFailure(kind: .memory, message: "The preview could not create a widget instance.")
            }
            defer { omni_instance_destroy(instance) }
            for key in ShellDataKey.allCases where key != .components {
                let bytes = values[key.rawValue] ?? [UInt8(OMNI_VALUE_NIL.rawValue)]
                try check(bytes.withUnsafeBufferPointer {
                    omni_instance_set_value(instance, key.rawValue, $0.baseAddress, $0.count)
                })
            }
            let bytes = settings[input.name] ?? [UInt8(OMNI_VALUE_NIL.rawValue)]
            try check(bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, "settings", $0.baseAddress, $0.count)
            })
            var stats = omni_render_stats()
            try check(omni_instance_render(
                instance, OMNI_VIEW_BAR, ShellWidgetPackage.renderBudget, &stats, &error, error.count
            ))
            try Task.checkCancellation()
            return try tree(from: instance, input: input, source: source)
        }
    }

    private static func check(_ status: omni_status, error: [CChar]) throws {
        guard status == OMNI_OK else {
            throw ShellScriptFailure(status: status, message: String(
                decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self
            ))
        }
    }

    private func load(
        _ source: ShellWidgetSource, into vm: OpaquePointer, expanded: Bool?, error: inout [CChar]
    ) throws {
        func check(_ status: omni_status) throws {
            try Self.check(status, error: error)
        }
        try check(omni_vm_set_module_limit(vm, source.moduleLimit))
        for module in source.modules {
            try check(omni_vm_add_module(
                vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count
            ))
        }
        var main = source.main
        if let expanded {
            main += "\nlocal previewRender = render\nfunction render(ctx)\nctx.state.expanded = \(expanded)\nreturn previewRender(ctx)\nend\n"
        }
        try check(omni_vm_load(
            vm, source.chunk, main, main.utf8.count, ShellWidgetPackage.loadBudget, &error, error.count
        ))
        if source.isIslandRoot {
            let bytes = ShellComponentCatalog.configurationBytes(
                instances: source.components, descriptors: source.componentDescriptors
            )
            try check(bytes.withUnsafeBufferPointer {
                omni_vm_configure_components(
                    vm,
                    $0.baseAddress,
                    $0.count,
                    ShellWidgetPackage.loadBudget,
                    &error,
                    error.count
                )
            })
        }
    }

    private func tree(
        from instance: OpaquePointer, input: ShellWidgetSourceLoader.Input, source: ShellWidgetSource
    ) throws -> Tree {
        var count = 0
        guard let wire = omni_instance_output(instance, OMNI_VIEW_BAR, &count), count > 0 else {
            throw ShellScriptFailure(kind: .runtime, message: "\(input.name) did not produce a preview.")
        }
        let output = UnsafeRawBufferPointer(start: wire, count: count)
        guard count >= MemoryLayout<omni_wire_header>.stride else {
            throw ShellScriptFailure(kind: .runtime, message: "\(input.name) produced an invalid preview.")
        }
        let header = output.loadUnaligned(as: omni_wire_header.self)
        let nodeBytes = MemoryLayout<omni_wire_header>.stride
            + Int(header.node_count) * MemoryLayout<omni_wire_node>.stride
        guard header.magic == OMNI_WIRE_MAGIC, nodeBytes <= count else {
            throw ShellScriptFailure(kind: .runtime, message: "\(input.name) produced an invalid preview.")
        }
        return Tree(
            name: input.name, wire: Array(output[0 ..< nodeBytes]),
            strings: Array(output[nodeBytes...]), stringCount: Int(header.string_count),
            directories: input.directories, packages: source.assetPackages
        )
    }
}
