// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

struct ShellIslandLayout: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case add(widget: String, options: [String: ShellComponentValue])
        case remove(id: String)
        case move(id: String, index: Int)
        case enable(id: String, value: Bool)
        case set(id: String, key: String, value: ShellComponentValue)
        case rootSetting(key: String, value: ShellComponentValue)
    }

    enum Change: Equatable, Sendable {
        case components([ShellComponentInstance])
        case rootSetting(key: String, value: ShellComponentValue)
    }

    struct Edit: Equatable, Sendable {
        let layout: ShellIslandLayout
        let change: Change
        let instanceID: String?
    }

    let profile: String
    let root: String
    var components: [ShellComponentInstance]

    func applying(
        _ operation: Operation,
        catalog: [String: ShellComponentDescriptor],
        rootOptions: [String: ShellComponentOption] = [:],
        makeID: () -> String = { "c-" + UUID().uuidString.lowercased() }
    ) throws -> Edit {
        var next = self
        var affected: String?
        switch operation {
        case let .add(widget, options):
            guard components.count < ShellComponentCatalog.instanceLimit else {
                throw ShellComponentCatalog.Failure("The island already has 64 component instances")
            }
            guard let descriptor = catalog[widget] else {
                throw ShellComponentCatalog.Failure("No component named \(widget) is installed")
            }
            let id = makeID()
            guard ShellComponentCatalog.validName(id), !components.contains(where: { $0.id == id }) else {
                throw ShellComponentCatalog.Failure("Could not assign a unique component instance ID")
            }
            try Self.validateKeys(options.keys)
            let instance = try descriptor.validate(ShellComponentInstance(id: id, widget: widget, options: options))
            next.components.append(instance)
            affected = id
        case let .remove(id):
            next.components.remove(at: try position(of: id))
            affected = id
        case let .move(id, index):
            guard (1 ... max(1, components.count)).contains(index), !components.isEmpty else {
                throw ShellComponentCatalog.Failure("Component index must be between 1 and \(components.count)")
            }
            let instance = next.components.remove(at: try position(of: id))
            next.components.insert(instance, at: index - 1)
            affected = id
        case let .enable(id, value):
            next.components[try position(of: id)].enabled = value
            affected = id
        case let .set(id, key, value):
            try Self.validateKeys([key])
            let index = try position(of: id)
            let widget = components[index].widget
            guard let descriptor = catalog[widget] else {
                throw ShellComponentCatalog.Failure("No component named \(widget) is installed")
            }
            next.components[index].options[key] = value
            next.components[index] = try descriptor.validate(next.components[index])
            affected = id
        case let .rootSetting(key, value):
            try Self.validateKeys([key])
            guard let option = rootOptions[key], option.accepts(value) else {
                throw ShellComponentCatalog.Failure("Invalid root setting \(key) for \(root)")
            }
            return Edit(layout: self, change: .rootSetting(key: key, value: value), instanceID: nil)
        }
        return Edit(layout: next, change: .components(next.components), instanceID: affected)
    }

    private func position(of id: String) throws -> Int {
        guard let index = components.firstIndex(where: { $0.id == id }) else {
            throw ShellComponentCatalog.Failure("No component instance named \(id) is configured")
        }
        return index
    }

    private static func validateKeys(_ keys: some Sequence<String>) throws {
        for key in keys
            where !ShellComponentCatalog.validName(key) || ShellComponentCatalog.reservedOptions.contains(key)
        {
            throw ShellComponentCatalog.Failure("Component option \(key) is reserved or invalid")
        }
    }

    static func persisted(_ change: Change, profile: String, root: String, in original: String) throws -> String {
        let entry: (key: [String], value: TOMLNode?)
        switch change {
        case let .components(instances):
            entry = (ShellProfiles.key("island", of: profile) + ["components"], .array(instances.map(node)))
        case let .rootSetting(key, value):
            entry = (ShellProfiles.key("widgets", of: profile) + [root, key], value.node)
        }
        return try ShellTOMLText.settingNodes([entry], in: original)
    }

    private static func node(_ instance: ShellComponentInstance) -> TOMLNode {
        var table = instance.options.mapValues(\.node)
        table["id"] = .string(instance.id)
        table["widget"] = .string(instance.widget)
        table["enabled"] = .boolean(instance.enabled)
        if instance.provider { table["provider"] = .boolean(true) }
        if let capabilities = instance.capabilities {
            table["capabilities"] = .table([
                "commands": .array(capabilities.commands.map(TOMLNode.string)),
                "network": .array(capabilities.network.map(TOMLNode.string)),
                "files": .boolean(capabilities.files),
                "clipboard": .boolean(capabilities.clipboard),
                "provider": .boolean(capabilities.provider)
            ])
        }
        return .table(table)
    }
}
