// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsLuauError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

struct SettingsLuauDocument {
    typealias Field = LuauTableDocument.Field

    let table: LuauTableDocument
    let export: SettingsExport
    let formulaRows: [[String]: [String: Int]]

    var source: Data {
        table.source
    }

    var sourceValue: SettingsLuauValue {
        table.sourceValue
    }

    var modules: SettingsFileVersions {
        table.modules
    }

    var tables: [[String]: SettingsSourceTable] {
        table.tables
    }

    var fields: [[String]: Field] {
        table.fields
    }

    var formulas: [[String]: [SettingsCodeSite]] {
        table.formulas
    }

    var hasFormulas: Bool {
        table.hasFormulas
    }

    static func read(_ source: Data, at entry: URL?) -> SettingsLuauInput {
        LuauTableDocument.read(source, at: entry, filename: "settings.luau")
    }

    init(_ source: Data, at entry: URL? = nil) throws {
        try self.init(Self.read(source, at: entry))
    }

    init(_ input: SettingsLuauInput) throws {
        table = try LuauTableDocument(input)
        export = try Self.decode(table.sourceValue, fields: table.fields)
        formulaRows = Self.indexFormulaRows(in: table.sourceValue, paths: table.formulas.keys, export: export)
    }

    static func decode(_ tree: SettingsLuauValue, fields: [[String]: Field]) throws -> SettingsExport {
        let active = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        defer { KeySymbolMapper.setHyperKeyModifiers(active) }
        do {
            let defaults = try SettingsLuauValue.fields(of: .defaults())
            let canonical = try SettingsFileModel(from: SettingsLuauDecoder(value: tree, defaults: defaults))
            return canonical.toSettingsExport()
        } catch {
            let path: [any CodingKey]
            switch error {
            case let DecodingError.keyNotFound(key, context): path = context.codingPath + [key]
            case let DecodingError.typeMismatch(_, context),
                 let DecodingError.valueNotFound(_, context),
                 let DecodingError.dataCorrupted(context): path = context.codingPath
            default: path = []
            }
            let line = Self.site(for: path.map(\.stringValue), in: fields)?.line ?? fields[[]]?.line ?? 1
            throw SettingsLuauError(
                message: "settings.luau:\(line): \(SettingsLuauError.diagnosticDescription(for: error))"
            )
        }
    }

    func hasLiteral(at path: [String]) -> Bool {
        fields[path]?.literal == true
    }

    static func initialSource(_ export: SettingsExport) throws -> Data {
        guard case let .record(fields) = try SettingsLuauValue.fields(of: export) else {
            throw SettingsLuauError(message: "Expected a settings table.")
        }
        return Data(("--!strict\nlocal settings: OmniWMSettings = " + SettingsLuauValue.record(fields)
                .literal() + "\nreturn settings\n").utf8)
    }

    private static func site(for path: [String], in fields: [[String]: Field]) -> Field? {
        var prefix = path
        while !prefix.isEmpty {
            if let field = fields[prefix] { return field }
            prefix.removeLast()
        }
        return nil
    }
}

extension SettingsLuauError {
    static func diagnosticDescription(for error: Error, root: String = "settings.luau") -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            "\(diagnosticPath(context.codingPath + [key], root: root)): \(context.debugDescription)"
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context),
             let DecodingError.dataCorrupted(context):
            "\(diagnosticPath(context.codingPath, root: root)): \(context.debugDescription)"
        default:
            error.localizedDescription
        }
    }

    private static func diagnosticPath(_ codingPath: [CodingKey], root: String) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? root : result
    }
}
