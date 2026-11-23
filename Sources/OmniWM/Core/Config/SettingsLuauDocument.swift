// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct SettingsLuauError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

struct SettingsLuauDocument {
    struct Field: Sendable {
        let bytes: Range<Int>
        let line: Int
        let literal: Bool
        let record: Bool
    }

    struct ReturnSite: Sendable {
        let bytes: Range<Int>
        let line: Int
        let insertion: Int
    }

    private final class Output {
        var sources: ConfigScriptSources

        init(entry: URL?, bytes: Int) {
            sources = ConfigScriptSources(entry: entry, sourceByteCount: bytes)
        }

        var paths: [[String]] = [[]]
        var fields: [[String]: Field] = [:]
        var tables: [[String]: SettingsSourceTable] = [:]
        var formulas: [[String]: [SettingsCodeSite]] = [:]
        var comments: [Range<Int>] = []
        var returnSites: [ReturnSite] = []
        var json = Data()

        func failure(at site: omni_config_location, message: [CChar]) -> SettingsLuauError {
            let reason = String(decoding: message.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            if site.line > 0 || site.source_id != 0 {
                let file = site.source_id == 0 ? "settings.luau" : sources.name(of: site.source_id)
                return SettingsLuauError(message: "\(file):\(max(1, site.line)): \(reason)")
            }
            return SettingsLuauError(message: reason.hasPrefix("settings.luau:") ? reason : "settings.luau:\(reason)")
        }
    }

    struct Evaluation: Sendable {
        fileprivate let tables: [[String]: SettingsSourceTable]
        fileprivate let fields: [[String]: Field]
        fileprivate let formulas: [[String]: [SettingsCodeSite]]
        fileprivate let comments: [Range<Int>]
        fileprivate let returnSites: [ReturnSite]
        fileprivate let value: SettingsLuauValue
    }

    let source: Data
    let sourceValue: SettingsLuauValue
    let tables: [[String]: SettingsSourceTable]
    let modules: SettingsFileVersions
    let formulas: [[String]: [SettingsCodeSite]]
    let formulaRows: [[String]: [String: Int]]
    var hasFormulas: Bool {
        !formulas.isEmpty
    }

    let export: SettingsExport
    let fields: [[String]: Field]
    let comments: [Range<Int>]
    let returnSites: [ReturnSite]

    static func read(_ source: Data, at entry: URL?) -> SettingsLuauInput {
        let output = Output(entry: entry, bytes: source.count)
        let result = Result { try evaluate(source, output: output) }
        return SettingsLuauInput(source: source, modules: output.sources.versions, result: result)
    }

    private static func evaluate(_ source: Data, output: Output) throws -> Evaluation {
        var site = omni_config_location()
        let resolver: omni_read_module? = output.sources.entry == nil ? nil : settingsReadModule
        var error = [CChar](repeating: 0, count: Int(OMNI_CONFIG_ERROR_CAPACITY))
        let status = source.withUnsafeBytes { bytes in
            omni_settings_evaluate(
                omni_config_span(data: bytes.bindMemory(to: CChar.self).baseAddress, length: bytes.count),
                ConfigScriptLoader.heapLimit, ConfigScriptLoader.cpuBudget, Unmanaged.passUnretained(output).toOpaque(),
                { context, parent, key, start, end, line, literal, record in
                    let out = Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue()
                    let keyBytes = UnsafeRawBufferPointer(start: key.data, count: key.length)
                    let path = key.data == nil ? [] : out.paths[Int(parent)] + [String(
                        decoding: keyBytes,
                        as: UTF8.self
                    )]
                    out.fields[path] = Field(bytes: start ..< end, line: Int(line), literal: literal, record: record)
                    if key.data == nil { return 0 }
                    out.paths.append(path)
                    return UInt32(out.paths.count - 1)
                }, { context, owner, start, end, line in
                    let out = Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue()
                    out.formulas[SettingsLuauDocument.sourcePath(out.paths[Int(owner)]), default: []].append(
                        SettingsCodeSite(line: Int(line), bytes: start ..< end)
                    )
                }, { context, owner, start, end, items, count in
                    let out = Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue()
                    out.tables[out.paths[Int(owner)]] = SettingsSourceTable(
                        bytes: start ..< end,
                        items: UnsafeBufferPointer(start: items, count: count).map(SettingsSourceTable.Item.init)
                    )
                }, { context, start, end in
                    Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue().comments.append(start ..< end)
                }, { context, start, end, line, insertion in
                    Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue().returnSites.append(
                        ReturnSite(bytes: start ..< end, line: Int(line), insertion: insertion)
                    )
                }, { context, bytes, count in
                    Unmanaged<Output>.fromOpaque(context!).takeUnretainedValue().json = Data(
                        bytes: bytes!,
                        count: count
                    )
                }, resolver, &site, &error, error.count
            )
        }
        guard status == OMNI_OK else { throw output.failure(at: site, message: error) }
        return try Evaluation(
            tables: output.tables, fields: output.fields, formulas: output.formulas, comments: output.comments,
            returnSites: output.returnSites,
            value: JSONDecoder().decode(SettingsLuauValue.self, from: output.json)
        )
    }

    private static let settingsReadModule: omni_read_module = { context, requester, spec, result, error, capacity in
        guard let context else { return false }
        return Unmanaged<Output>.fromOpaque(context).takeUnretainedValue().sources.resolve(
            requester, spec: spec, into: result, error: error, capacity: capacity
        )
    }

    init(_ source: Data, at entry: URL? = nil) throws {
        try self.init(Self.read(source, at: entry))
    }

    init(_ input: SettingsLuauInput) throws {
        source = input.source
        modules = input.modules
        let evaluation = try input.result.get()
        tables = evaluation.tables
        fields = evaluation.fields
        comments = evaluation.comments
        returnSites = evaluation.returnSites
        sourceValue = evaluation.value
        formulas = returnSites.isEmpty ? evaluation.formulas :
            [[]: returnSites.map { SettingsCodeSite(line: $0.line, bytes: $0.bytes) }]
        export = try Self.decode(sourceValue, fields: fields)
        formulaRows = Self.indexFormulaRows(in: sourceValue, paths: formulas.keys, export: export)
    }

    static func decode(_ tree: SettingsLuauValue, fields: [[String]: Field]) throws -> SettingsExport {
        let active = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        defer { KeySymbolMapper.setHyperKeyModifiers(active) }
        do {
            let defaults = try SettingsLuauValue.fields(of: .defaults())
            let canonical = try CanonicalTOMLConfig(from: SettingsLuauDecoder(value: tree, defaults: defaults))
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
                message: "settings.luau:\(line): \(SettingsTOMLCodec.diagnosticDescription(for: error, root: "settings.luau"))"
            )
        }
    }

    func hasLiteral(at path: [String]) -> Bool {
        fields[path]?.literal == true
    }

    static func initialSource(_ export: SettingsExport) throws -> Data {
        guard case var .record(fields) = try SettingsLuauValue.fields(of: export) else {
            throw SettingsLuauError(message: "Expected a settings table.")
        }
        fields.removeValue(forKey: "schemaVersion")
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
