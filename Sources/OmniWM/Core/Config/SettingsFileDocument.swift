// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsFileInput: Sendable {
    case luau(SettingsLuauInput)
    case toml(source: Data, values: SettingsLuauValue)

    static func read(_ data: Data, at url: URL) throws -> Self {
        if url.pathExtension == "toml" {
            return try .toml(source: data, values: SettingsTOMLDocument.read(data))
        }
        return .luau(SettingsLuauDocument.read(data, at: url))
    }

    var modules: SettingsFileVersions {
        if case let .luau(input) = self { return input.modules }
        return [:]
    }
}

enum SettingsFileDocument {
    case luau(SettingsLuauDocument)
    case toml(SettingsTOMLDocument)

    init(_ input: SettingsFileInput) throws {
        switch input {
        case let .luau(input): self = try .luau(SettingsLuauDocument(input))
        case let .toml(source, values): self = try .toml(SettingsTOMLDocument(source: source, values: values))
        }
    }

    init(_ data: Data, at url: URL) throws {
        try self.init(SettingsFileInput.read(data, at: url))
    }

    var source: Data {
        switch self {
        case let .luau(document): document.source
        case let .toml(document): document.source
        }
    }

    var export: SettingsExport {
        switch self {
        case let .luau(document): document.export
        case let .toml(document): document.export
        }
    }

    var luau: SettingsLuauDocument? {
        if case let .luau(document) = self { return document }
        return nil
    }

    var modules: SettingsFileVersions {
        luau?.modules ?? [:]
    }

    func hasLiteral(at path: [String]) -> Bool {
        switch self {
        case let .luau(document): document.hasLiteral(at: path)
        case let .toml(document):
            path.reduce(Optional(document.values)) { $0?[$1] } != nil
        }
    }

    static func initialSource(_ export: SettingsExport, at url: URL) throws -> Data {
        if url.pathExtension == "toml" { return try SettingsTOMLDocument.initialSource(export) }
        return try SettingsLuauDocument.initialSource(export)
    }

    func edit(
        from previous: SettingsExport,
        to desired: SettingsExport,
        origins: SettingsListOrigins
    ) throws -> SettingsSourceEdit {
        switch self {
        case let .luau(document): try document.edit(from: previous, to: desired, origins: origins)
        case .toml:
            try SettingsSourceEdit(source: SettingsTOMLDocument.initialSource(desired), question: nil, expected: nil)
        }
    }
}

struct SettingsFileLoad {
    let modules: SettingsFileVersions
    let result: Result<SettingsFileDocument, any Error>

    init(_ source: Data, at url: URL) {
        self.init(Result { try SettingsFileInput.read(source, at: url) })
    }

    init(_ read: Result<SettingsFileInput, any Error>) {
        modules = (try? read.get().modules) ?? [:]
        result = read.flatMap { input in Result { try SettingsFileDocument(input) } }
    }
}
