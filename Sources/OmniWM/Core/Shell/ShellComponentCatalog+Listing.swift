// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

struct ShellRootSettings: Equatable, Sendable {
    let widget: String
    let options: [String: ShellComponentOption]
    let network: [String]
    let folder: URL

    static func load(_ widget: String, directories: [URL]) throws -> ShellRootSettings? {
        guard ShellComponentCatalog.validName(widget) else {
            throw ShellComponentCatalog.Failure("Invalid root widget name \(widget)")
        }
        guard let folder = directories.lazy.map({ $0.appendingPathComponent("widgets/\(widget)") }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("settings.toml").path)
        }) else { return nil }
        return try load(widget, folder: folder)
    }

    static func load(_ widget: String, folder: URL) throws -> ShellRootSettings {
        let data = try SettingsFileAccess.readContents(at: folder.appendingPathComponent("settings.toml")).data
        guard data.count <= 256 * 1024 else {
            throw ShellComponentCatalog.Failure("\(widget)/settings.toml is larger than 256 KiB")
        }
        let table = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        if let key = table.keys.sorted().first(where: { $0 != "options" && $0 != "capabilities" }) {
            throw ShellComponentCatalog.Failure("\(widget)/settings.toml: unknown key \(key)")
        }
        return try ShellRootSettings(
            widget: widget,
            options: ShellComponentCatalog.parseOptions(
                table["options"], place: widget,
                reservedNames: ShellComponentCatalog.reservedOptions.subtracting(["network"])
            ),
            network: ShellComponentCatalog.rootNetwork(table["capabilities"], place: widget),
            folder: folder
        )
    }

    func values(applying configured: [String: ShellComponentValue]) throws -> [String: ShellComponentValue] {
        var result = options.compactMapValues(\.defaultValue)
        for (key, value) in configured {
            guard let option = options[key], option.accepts(value) else {
                throw ShellComponentCatalog.Failure("Invalid root setting \(key) for \(widget)")
            }
            result[key] = value
        }
        return result
    }
}

extension ShellComponentCatalog {
    struct Entry: Equatable, Sendable {
        let widget: String
        let sources: [URL]
        let descriptor: ShellComponentDescriptor?
        let error: String?
    }

    static func installed(directories: [URL]) throws -> [Entry] {
        var sources: [String: [URL]] = [:]
        for directory in directories {
            for folder in ShellConfig.widgetFolders(in: directory) {
                let name = folder.lastPathComponent
                guard validName(name),
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent("component.toml").path)
                else { continue }
                if sources[name] == nil, sources.count >= rootModuleLimit {
                    throw Failure("Installed component catalog exceeds \(rootModuleLimit) packages")
                }
                if sources[name]?.contains(folder) != true { sources[name, default: []].append(folder) }
            }
        }
        return sources.keys.sorted().map { name in
            do {
                return try Entry(
                    widget: name,
                    sources: sources[name] ?? [],
                    descriptor: load(name, directories: directories),
                    error: nil
                )
            } catch {
                return Entry(
                    widget: name,
                    sources: sources[name] ?? [],
                    descriptor: nil,
                    error: error.localizedDescription
                )
            }
        }
    }

    static let metadataByteLimit = 4 << 20

    static func catalogBytes(_ entries: [Entry]) throws -> [UInt8] {
        var writer = ShellValueWriter()
        writer.array(entries.count)
        for entry in entries {
            writer.map(8)
            writer.key("widget")
            writer.string(entry.widget)
            writer.key("title")
            writer.string(entry.descriptor?.title ?? entry.widget)
            writer.key("icon")
            writer.string(entry.descriptor?.icon ?? "exclamationmark.triangle")
            writer.key("views")
            ShellComponentValue.strings(entry.descriptor?.views ?? []).write(to: &writer)
            writer.key("options")
            writeOptions(entry.descriptor?.options ?? [:], to: &writer)
            writer.key("source")
            writer.string(entry.sources.first?.path ?? "")
            writer.key("overrides")
            ShellComponentValue.strings(entry.sources.dropFirst().map(\.path)).write(to: &writer)
            writer.key("error")
            if let error = entry.error { writer.string(error) } else { writer.null() }
            guard writer.bytes.count <= metadataByteLimit else { throw Failure("Component catalog exceeds 4 MiB") }
        }
        return writer.bytes
    }

    static func settingsBytes(_ options: [String: ShellComponentOption]) throws -> [UInt8] {
        var writer = ShellValueWriter()
        writeOptions(options, to: &writer)
        guard writer.bytes.count <= metadataByteLimit else { throw Failure("Root settings schema exceeds 4 MiB") }
        return writer.bytes
    }

    private static func writeOptions(_ options: [String: ShellComponentOption], to writer: inout ShellValueWriter) {
        writer.map(options.count)
        for key in options.keys.sorted() {
            guard let option = options[key] else { continue }
            writer.key(key)
            writer.map(8)
            writer.key("type")
            writer.string(option.kind.rawValue)
            writer.key("title")
            writer.string(option.title)
            writer.key("default")
            if let value = option.defaultValue { value.write(to: &writer) } else { writer.null() }
            writer.key("min")
            if let value = option.minimum { writer.number(value) } else { writer.null() }
            writer.key("max")
            if let value = option.maximum { writer.number(value) } else { writer.null() }
            writer.key("step")
            if let value = option.step { writer.number(value) } else { writer.null() }
            writer.key("maxLength")
            writer.number(Double(option.maxLength))
            writer.key("choices")
            ShellComponentValue.strings(option.choices).write(to: &writer)
        }
    }
}
