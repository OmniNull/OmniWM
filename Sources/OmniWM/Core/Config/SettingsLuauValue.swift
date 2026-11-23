// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsLuauValue: Hashable, Decodable, Sendable {
    case record([String: Self])
    case list([Self])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let fields = try? value.decode([String: Self].self) { self = .record(fields) }
        else if let rows = try? value.decode([Self].self) { self = .list(rows) }
        else if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else { self = try .number(value.decode(Double.self)) }
    }

    subscript(key: String) -> Self? {
        guard case let .record(values) = self else { return nil }
        return values[key]
    }

    static func fields(of export: SettingsExport) throws -> Self {
        let active = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        KeySymbolMapper.setHyperKeyModifiers(export.hyperKeyModifiers)
        defer { KeySymbolMapper.setHyperKeyModifiers(active) }
        let data = try JSONEncoder().encode(CanonicalTOMLConfig(export: export))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func literal(depth: Int = 0) -> String {
        switch self {
        case let .boolean(value): return value ? "true" : "false"
        case let .integer(value): return String(value)
        case let .number(value): return String(value)
        case let .string(value): return Self.quoted(value)
        case let .list(values): return Self.table(values.map { $0.literal(depth: depth + 1) }, depth: depth)
        case let .record(fields):
            let entries = fields.sorted { $0.key < $1.key }.map { key, value in
                "\(Self.keyLiteral(key)) = \(value.literal(depth: depth + 1))"
            }
            return Self.table(entries, depth: depth)
        }
    }

    private static func table(_ entries: [String], depth: Int) -> String {
        guard !entries.isEmpty else { return "{}" }
        let indent = String(repeating: "    ", count: depth)
        return "{\n" + entries.map { indent + "    " + $0 + ",\n" }.joined() + indent + "}"
    }

    private static let reserved = Set(
        "and break do else elseif end false for function if in local nil not or repeat return then true until while"
            .split(separator: " ").map(String.init)
    )

    static func keyLiteral(_ key: String) -> String {
        identifier(key) ? key : "[\(quoted(key))]"
    }

    private static func identifier(_ value: String) -> Bool {
        guard let first = value.utf8.first, !reserved.contains(value) else { return false }
        func letter(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "_")
        }
        return letter(first) && value.utf8
            .allSatisfy { letter($0) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 32: result += String(format: "\\x%02X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

enum SettingsWireVariant {
    case sample(SettingsLuauValue)
    case named(String)
}

protocol SettingsWireVariants {
    static var settingsWireVariants: [SettingsWireVariant] { get }
}

protocol SettingsWireNames {
    static var settingsWireNames: [String: [String]] { get }
}
