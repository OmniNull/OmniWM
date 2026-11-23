// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM

private protocol SettingsCollectionProbe {
    static func record(on decoder: SettingsSchemaRecorder) throws -> Self
}

extension Array: SettingsCollectionProbe where Element: Decodable {
    fileprivate static func record(on decoder: SettingsSchemaRecorder) throws -> Self {
        let item = decoder.element()
        _ = try item.value(Element.self)
        decoder.shape = try .list(item.result())
        return []
    }
}

extension Dictionary: SettingsCollectionProbe where Key == String, Value: Decodable {
    fileprivate static func record(on decoder: SettingsSchemaRecorder) throws -> Self {
        let item = decoder.element()
        _ = try item.value(Value.self)
        decoder.shape = try .map(item.result())
        return [:]
    }
}

final class SettingsSchemaRecorder: Decoder, SingleValueDecodingContainer {
    private let sample: SettingsLuauValue?
    private let defaults: SettingsLuauValue?
    private let discriminants: Bool
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] {
        [:]
    }

    fileprivate var shape: SettingsSchemaShape?
    private var fields: [String: SettingsSchemaField] = [:]
    private var optionalKeys: Set<String> = []

    private init(
        sample: SettingsLuauValue?,
        defaults: SettingsLuauValue? = nil,
        path: [any CodingKey] = [],
        discriminants: Bool = false
    ) {
        self.sample = sample
        self.defaults = defaults
        self.discriminants = discriminants
        codingPath = path
    }

    static func inventory() throws -> SettingsSchemaShape {
        let defaults = try SettingsLuauValue.fields(of: .defaults())
        let modifier = HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers) ?? .default
        defer { KeySymbolMapper.setHyperKeyModifiers(modifier) }
        let decoder = SettingsSchemaRecorder(sample: defaults, defaults: defaults)
        _ = try decoder.value(CanonicalTOMLConfig.self)
        decoder.fields.removeValue(forKey: "schemaVersion")
        return try decoder.result()
    }

    fileprivate func element() -> SettingsSchemaRecorder {
        var sampleValue: SettingsLuauValue?
        if case let .list(rows) = sample { sampleValue = rows.first }
        return SettingsSchemaRecorder(sample: sampleValue, path: codingPath)
    }

    fileprivate func result() throws -> SettingsSchemaShape {
        if case .record = shape { return .record(fields) }
        guard let shape else { throw problem("Decoder produced no wire shape") }
        return shape
    }

    private func problem(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }

    fileprivate func value<T: Decodable>(_ type: T.Type) throws -> T {
        if let collection = type as? any SettingsCollectionProbe.Type,
           let result = try collection.record(on: self) as? T { return result }
        if let variants = type as? any SettingsWireVariants.Type {
            return try recordVariants(type, variants.settingsWireVariants)
        }
        if let cases = type as? any CaseIterable.Type {
            return try recordEnum(type, cases: cases.allCases.map { $0 })
        }
        if type is any RawRepresentable.Type {
            throw problem("\(type) needs CaseIterable or a wire declaration")
        }
        let decoded = try T(from: self)
        if let names = type as? any SettingsWireNames.Type {
            for (key, choices) in names.settingsWireNames {
                guard let field = fields[key] else { throw problem("Unknown named field \(type).\(key)") }
                let shape: SettingsSchemaShape = switch field.shape {
                case .scalar("string"): .names(choices)
                case .list(.scalar("string")): .list(.names(choices))
                default: throw problem("Expected strings at \(type).\(key)")
                }
                fields[key] = SettingsSchemaField(shape: shape, optional: field.optional, hasDefault: field.hasDefault)
            }
        }
        return decoded
    }

    private func recordVariants<T: Decodable>(_ type: T.Type, _ variants: [SettingsWireVariant]) throws -> T {
        var forms: [SettingsSchemaShape] = []
        var result: T?
        for variant in variants {
            let seed: SettingsLuauValue = switch variant {
            case let .sample(value): value
            case let .named(name): .string(name)
            }
            let probe = SettingsSchemaRecorder(sample: seed, path: codingPath, discriminants: true)
            let value = try T(from: probe)
            let form: SettingsSchemaShape = switch variant {
            case let .named(name): .names([name])
            case .sample: try probe.result()
            }
            if !forms.contains(form) { forms.append(form) }
            if result == nil { result = value }
        }
        guard let result, let first = forms.first else { throw problem("No wire examples for \(type)") }
        shape = forms.count == 1 ? first : .alternatives(forms)
        return result
    }

    private func recordEnum<T>(_ type: T.Type, cases: [Any]) throws -> T {
        var names: [String] = []
        var numbers: [Int64] = []
        var selected: T?
        for entry in cases {
            guard let item = entry as? any Encodable else { throw problem("\(type) needs a Codable raw value") }
            let encoded = try JSONDecoder().decode(SettingsLuauValue.self, from: JSONEncoder().encode(item))
            switch encoded {
            case let .string(name): names.append(name)
            case let .integer(number): numbers.append(number)
            default: throw problem("Unsupported enum wire type \(type)")
            }
            if encoded == sample || selected == nil { selected = entry as? T }
        }
        guard let selected else { throw problem("No cases in \(type)") }
        if discriminants, case let .string(name) = sample { shape = .names([name]) }
        else { shape = names.isEmpty ? .numbers(numbers) : .names(names) }
        return selected
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        shape = .record([:])
        return KeyedDecodingContainer(Keys<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw problem("Unkeyed custom codec needs declared wire examples")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        self
    }

    func decodeNil() -> Bool {
        false
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try value(type)
    }

    func decode(_: String.Type) throws -> String {
        shape = .scalar("string")
        if case let .string(text) = sample { return text }
        guard sample == nil else { throw problem("Expected a string") }
        return UUID().uuidString
    }

    func decode(_: Bool.Type) throws -> Bool {
        shape = .scalar("boolean")
        if case let .boolean(value) = sample { return value }
        return false
    }

    private func number<T: BinaryInteger>(_: T.Type) throws -> T {
        shape = .scalar("number")
        if case let .integer(n) = sample, let value = T(exactly: n) { return value }
        guard sample == nil else { throw problem("Expected an integer") }
        return .zero
    }

    func decode(_: Double.Type) throws -> Double {
        shape = .scalar("number")
        switch sample {
        case let .number(n): return n
        case let .integer(n): return Double(n)
        case nil: return .zero
        default: throw problem("Expected a number")
        }
    }

    func decode(_: Float.Type) throws -> Float {
        try Float(decode(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int {
        try number(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try number(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try number(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try number(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try number(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try number(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try number(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try number(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try number(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try number(type)
    }

    private struct Keys<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: SettingsSchemaRecorder
        var codingPath: [any CodingKey] {
            decoder.codingPath
        }

        var allKeys: [Key] {
            guard case let .record(fields) = decoder.sample else { return [] }
            return fields.keys.compactMap(Key.init(stringValue:))
        }

        func contains(_ key: Key) -> Bool {
            decoder.optionalKeys.insert(key.stringValue)
            return true
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            decoder.optionalKeys.insert(key.stringValue)
            return false
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            let fallback = decoder.defaults?[key.stringValue]
            let child = SettingsSchemaRecorder(
                sample: decoder.sample?[key.stringValue],
                defaults: fallback,
                path: codingPath + [key],
                discriminants: decoder.discriminants
            )
            let value = try child.value(type)
            decoder.fields[key.stringValue] = try SettingsSchemaField(
                shape: child.result(), optional: decoder.optionalKeys.contains(key.stringValue),
                hasDefault: fallback != nil
            )
            return value
        }

        func nestedContainer<Nested: CodingKey>(
            keyedBy _: Nested.Type,
            forKey _: Key
        ) throws -> KeyedDecodingContainer<Nested> {
            throw decoder.problem("Unexpected nested container")
        }

        func nestedUnkeyedContainer(forKey _: Key) throws -> any UnkeyedDecodingContainer {
            throw decoder.problem("Unexpected nested unkeyed container")
        }

        func superDecoder() throws -> any Decoder {
            throw decoder.problem("Unexpected superclass")
        }

        func superDecoder(forKey _: Key) throws -> any Decoder {
            throw decoder.problem("Unexpected superclass")
        }
    }
}
