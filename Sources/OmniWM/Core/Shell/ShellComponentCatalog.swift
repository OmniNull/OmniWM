// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

enum ShellComponentValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    init?(_ node: TOMLNode) {
        switch node {
        case let .boolean(value): self = .bool(value)
        case let .integer(value): self = .number(Double(value))
        case let .float(value) where value.isFinite: self = .number(value)
        case let .string(value): self = .string(value)
        case let .array(values):
            let strings = values.compactMap { value -> String? in
                guard case let .string(string) = value else { return nil }
                return string
            }
            guard strings.count == values.count else { return nil }
            self = .strings(strings)
        default: return nil
        }
    }

    func write(to writer: inout ShellValueWriter) {
        switch self {
        case let .bool(value): writer.bool(value)
        case let .number(value): writer.number(value)
        case let .string(value): writer.string(value)
        case let .strings(values):
            writer.array(values.count)
            for value in values { writer.string(value) }
        }
    }

    var node: TOMLNode {
        switch self {
        case let .bool(value): .boolean(value)
        case let .number(value): .float(value)
        case let .string(value): .string(value)
        case let .strings(values): .array(values.map(TOMLNode.string))
        }
    }
}

struct ShellComponentCapabilities: Equatable, Sendable {
    var commands: [String] = []
    var network: [String] = []
    var files = false
    var clipboard = false
    var provider = false
}

struct ShellComponentInstance: Equatable, Sendable {
    let id: String
    let widget: String
    var enabled = true
    var provider = false
    var options: [String: ShellComponentValue] = [:]
    var capabilities: ShellComponentCapabilities?
}

struct ShellComponentOption: Equatable, Sendable {
    enum Kind: String, Sendable {
        case boolean
        case number
        case string
        case choice
        case strings
    }

    let kind: Kind
    var title: String
    var defaultValue: ShellComponentValue?
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    var maxLength = 4096
    var choices: [String] = []

    func accepts(_ value: ShellComponentValue) -> Bool {
        switch (kind, value) {
        case (.boolean, .bool): true
        case let (.number, .number(number)):
            number.isFinite && minimum.map { number >= $0 } != false
                && maximum.map { number <= $0 } != false
                && step.map { step in
                    let count = (number - (minimum ?? 0)) / step
                    return abs(count - count.rounded()) <= max(1, abs(count)) * 1e-9
                } != false
        case let (.string, .string(string)): string.count <= maxLength
        case let (.choice, .string(string)): choices.contains(string)
        case let (.strings, .strings(strings)):
            strings.count <= 256 && strings.allSatisfy { $0.count <= maxLength }
        default: false
        }
    }
}

struct ShellComponentDescriptor: Equatable, Sendable {
    let widget: String
    let title: String
    let icon: String
    let views: [String]
    let uses: [String]
    let options: [String: ShellComponentOption]
    let capabilities: ShellComponentCapabilities
    let providerCommand: [String]?
    let folder: URL

    func validate(_ instance: ShellComponentInstance) throws -> ShellComponentInstance {
        var result = instance
        for (key, value) in instance.options {
            guard let option = options[key], option.accepts(value) else {
                throw ShellComponentCatalog.Failure("\(instance.id): invalid option \(key) for \(widget)")
            }
        }
        for (key, option) in options where result.options[key] == nil {
            result.options[key] = option.defaultValue
        }
        return result
    }
}

enum ShellComponentCatalog {
    static let rootModuleLimit = 512
    static let instanceLimit = 64
    static let reservedOptions: Set<String> = [
        "id", "widget", "enabled", "provider", "capabilities", "commands", "network", "files", "clipboard"
    ]

    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    struct Resolution {
        let instances: [ShellComponentInstance]
        let descriptors: [ShellComponentDescriptor]
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func instances(from node: TOMLNode?) throws -> [ShellComponentInstance] {
        guard let node else { return [] }
        guard case let .array(values) = node, values.count <= instanceLimit else {
            throw Failure("[island] components must be an array of at most \(instanceLimit) instances")
        }
        var seen: Set<String> = []
        return try values.map { value in
            guard case let .table(table) = value,
                  case let .string(id)? = table["id"], validName(id), seen.insert(id).inserted,
                  case let .string(widget)? = table["widget"], validName(widget)
            else { throw Failure("[island] each component needs a unique id and a widget name") }
            var instance = ShellComponentInstance(id: id, widget: widget)
            for key in ["enabled", "provider"] where table[key] != nil {
                guard case let .boolean(flag)? = table[key] else {
                    throw Failure("[island] component \(id): \(key) must be boolean")
                }
                if key == "enabled" { instance.enabled = flag } else { instance.provider = flag }
            }
            if let capabilities = table["capabilities"] {
                instance.capabilities = try parseCapabilities(capabilities, place: id)
            }
            for (key, node) in table where !["id", "widget", "enabled", "provider", "capabilities"].contains(key) {
                guard !reservedOptions.contains(key), let value = ShellComponentValue(node) else {
                    throw Failure("[island] component \(id): invalid option \(key)")
                }
                instance.options[key] = value
            }
            return instance
        }
    }

    static func load(_ widget: String, directories: [URL]) throws -> ShellComponentDescriptor {
        guard validName(widget), let folder = directories.lazy.map({
            $0.appendingPathComponent("widgets/\(widget)", isDirectory: true)
        }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("component.toml").path) })
        else { throw Failure("No component named \(widget) is installed") }
        let url = folder.appendingPathComponent("component.toml")
        let data = try SettingsFileAccess.readContents(at: url).data
        guard data.count <= 256 * 1024 else { throw Failure("\(widget)/component.toml is larger than 256 KiB") }
        let table = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("component.luau").path) else {
            throw Failure("\(widget) has no component.luau")
        }
        try checkKeys(
            table,
            allowed: ["title", "icon", "views", "uses", "options", "capabilities", "provider"],
            place: widget
        )
        let title = try string(table["title"], fallback: widget, place: "\(widget) title")
        let icon = try string(table["icon"], fallback: "square.grid.2x2", place: "\(widget) icon")
        let views = try strings(table["views"], fallback: [], place: "\(widget) views")
        guard !views.isEmpty, views.allSatisfy(validName), Set(views).count == views.count else {
            throw Failure("\(widget) views must contain unique view names")
        }
        let uses = try strings(table["uses"], fallback: [], place: "\(widget) uses")
        guard uses.allSatisfy(validName), Set(uses).count == uses.count else {
            throw Failure("\(widget) uses must contain unique component names")
        }
        let options = try parseOptions(table["options"], place: widget)
        let capabilities = try parseCapabilities(table["capabilities"], place: widget)
        var command: [String]?
        if let node = table["provider"] {
            guard case let .table(provider) = node else { throw Failure("\(widget) provider must be a table") }
            try checkKeys(provider, allowed: ["command"], place: "\(widget) provider")
            let argv = try strings(provider["command"], fallback: [], place: "\(widget) provider command")
            guard let executable = argv.first, !executable.isEmpty, argv.count <= 64,
                  !executable.hasPrefix("/"), !executable.split(separator: "/").contains("..")
            else { throw Failure("\(widget) provider command must name a program inside its package") }
            command = argv
        }
        return ShellComponentDescriptor(
            widget: widget,
            title: title,
            icon: icon,
            views: views,
            uses: uses,
            options: options,
            capabilities: capabilities,
            providerCommand: command,
            folder: folder
        )
    }

    static func resolve(_ instances: [ShellComponentInstance], directories: [URL]) throws -> Resolution {
        var descriptors: [String: ShellComponentDescriptor] = [:]
        var ordered: [ShellComponentDescriptor] = []
        var visiting: Set<String> = []
        func visit(_ widget: String) throws {
            guard descriptors[widget] == nil else { return }
            guard descriptors.count + visiting.count < rootModuleLimit else {
                throw Failure("Component dependencies exceed the \(rootModuleLimit)-module limit")
            }
            guard visiting.insert(widget).inserted else { throw Failure("Component dependency cycle at \(widget)") }
            let descriptor = try load(widget, directories: directories)
            for dependency in descriptor.uses { try visit(dependency) }
            visiting.remove(widget)
            descriptors[widget] = descriptor
            ordered.append(descriptor)
        }
        for instance in instances { try visit(instance.widget) }
        let validated = try instances.map { instance in
            guard let descriptor = descriptors[instance.widget]
            else { throw Failure("Missing component \(instance.widget)") }
            return try descriptor.validate(instance)
        }
        return Resolution(instances: validated, descriptors: ordered)
    }

    static func configurationBytes(
        instances: [ShellComponentInstance],
        descriptors: [ShellComponentDescriptor]
    ) -> [UInt8] {
        let descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.widget, $0) })
        var writer = ShellValueWriter()
        writer.array(instances.count)
        for instance in instances {
            writer.map(6)
            writer.key("id")
            writer.string(instance.id)
            writer.key("widget")
            writer.string(instance.widget)
            writer.key("title")
            writer.string(descriptors[instance.widget]?.title ?? instance.widget)
            writer.key("enabled")
            writer.bool(instance.enabled)
            writer.key("provider")
            writer.bool(descriptors[instance.widget]?.authorizesProvider(instance) == true)
            writer.key("options")
            writer.map(instance.options.count)
            for key in instance.options.keys.sorted() {
                writer.key(key)
                instance.options[key]?.write(to: &writer)
            }
        }
        return writer.bytes
    }

    static func parseOptions(
        _ node: TOMLNode?, place: String, reservedNames: Set<String> = reservedOptions
    ) throws -> [String: ShellComponentOption] {
        guard let node else { return [:] }
        guard case let .table(entries) = node else { throw Failure("\(place) options must be a table") }
        var options: [String: ShellComponentOption] = [:]
        for (key, node) in entries {
            guard validName(key), !reservedNames.contains(key) else {
                throw Failure("\(place): reserved or invalid option name \(key)")
            }
            options[key] = try option(node, key: key, widget: place)
        }
        return options
    }

    private static func option(_ node: TOMLNode, key: String, widget: String) throws -> ShellComponentOption {
        let place = "\(widget) option \(key)"
        guard case let .table(table) = node, case let .string(type)? = table["type"],
              let kind = ShellComponentOption.Kind(rawValue: type)
        else { throw Failure("\(place) needs a valid type") }
        try checkKeys(
            table,
            allowed: ["type", "title", "default", "min", "max", "step", "maxLength", "choices"],
            place: place
        )
        var option = ShellComponentOption(kind: kind, title: try string(table["title"], fallback: key, place: place))
        try applyNumberConstraints(table, to: &option, place: place)
        if let node = table["maxLength"] {
            guard kind == .string || kind == .strings, case let .integer(count) = node, (0 ... 65536).contains(count)
            else { throw Failure("\(place): invalid maxLength") }
            option.maxLength = Int(count)
        }
        option.choices = try strings(table["choices"], fallback: [], place: place)
        guard kind != .choice || !option.choices.isEmpty else { throw Failure("\(place) needs choices") }
        if let node = table["default"] {
            guard let value = ShellComponentValue(node), option.accepts(value) else {
                throw Failure("\(place): invalid default")
            }
            option.defaultValue = value
        }
        return option
    }

    private static func applyNumberConstraints(
        _ table: [String: TOMLNode], to option: inout ShellComponentOption, place: String
    ) throws {
        for key in ["min", "max", "step"] where table[key] != nil {
            guard option.kind == .number, let number = ShellConfig.number(table[key]), number.isFinite,
                  key != "step" || number > 0
            else { throw Failure("\(place): invalid \(key)") }
            if key == "min" { option.minimum = number }
            else if key == "max" { option.maximum = number }
            else { option.step = number }
        }
        if let minimum = option.minimum, let maximum = option.maximum, minimum > maximum {
            throw Failure("\(place): min is greater than max")
        }
    }

    private static func parseCapabilities(_ node: TOMLNode?, place: String) throws -> ShellComponentCapabilities {
        guard let node else { return ShellComponentCapabilities() }
        guard case let .table(table) = node else { throw Failure("\(place) capabilities must be a table") }
        try checkKeys(table, allowed: ["commands", "network", "provider", "files", "clipboard"], place: place)
        var result = ShellComponentCapabilities()
        result.commands = try strings(table["commands"], fallback: [], place: "\(place) commands")
        result.network = try strings(table["network"], fallback: [], place: "\(place) network")
        for key in ["provider", "files", "clipboard"] where table[key] != nil {
            guard case let .boolean(value)? = table[key] else { throw Failure("\(place) \(key) must be boolean") }
            if key == "provider" { result.provider = value }
            else if key == "files" { result.files = value }
            else { result.clipboard = value }
        }
        return result
    }

    static func rootNetwork(_ node: TOMLNode?, place: String) throws -> [String] {
        guard let node else { return [] }
        guard case let .table(table) = node else { throw Failure("\(place) capabilities must be a table") }
        try checkKeys(table, allowed: ["network"], place: place)
        return try strings(table["network"], fallback: [], place: "\(place) network")
    }

    private static func checkKeys(_ table: [String: TOMLNode], allowed: Set<String>, place: String) throws {
        if let key = table.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Failure("\(place): unknown key \(key)")
        }
    }

    private static func string(_ node: TOMLNode?, fallback: String, place: String) throws -> String {
        guard let node else { return fallback }
        guard case let .string(value) = node else { throw Failure("\(place) must be a string") }
        return value
    }

    private static func strings(_ node: TOMLNode?, fallback: [String], place: String) throws -> [String] {
        guard let node else { return fallback }
        guard case let .array(values) = node else { throw Failure("\(place) must be a string array") }
        return try values.map { value in
            guard case let .string(string) = value else { throw Failure("\(place) must contain strings") }
            return string
        }
    }
}
