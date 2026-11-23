// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsLuauDecoder: Decoder, SingleValueDecodingContainer {
    let value: SettingsLuauValue
    var defaults: SettingsLuauValue?
    var validatesSettings = true
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] {
        [:]
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Expected \(type)."))
    }

    func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case let .record(fields) = value else { throw mismatch([String: SettingsLuauValue].self) }
        if validatesSettings, let unknown = fields.keys.first(where: { Key(stringValue: $0) == nil }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath + [DynamicCodingKey(unknown)],
                debugDescription: "Unknown setting."
            ))
        }
        return KeyedDecodingContainer(Fields<Key>(decoder: self, fields: fields))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        switch value {
        case let .list(elements):
            return Elements(decoder: self, elements: validatesSettings ? SettingsListIdentity.sourceRows(
                path: codingPath.map(\.stringValue), rows: elements
            ) : elements)
        case .record(let fields) where fields.isEmpty: return Elements(decoder: self, elements: [])
        default: throw mismatch([SettingsLuauValue].self)
        }
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        self
    }

    func decodeNil() -> Bool {
        false
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: self)
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case let .boolean(decoded) = value else { throw mismatch(type) }
        return decoded
    }

    func decode(_ type: String.Type) throws -> String {
        guard case let .string(decoded) = value else { throw mismatch(type) }
        return decoded
    }

    func decode(_ type: Double.Type) throws -> Double {
        switch value {
        case let .integer(decoded): return Double(decoded)
        case let .number(decoded): return decoded
        default: throw mismatch(type)
        }
    }

    func decode(_: Float.Type) throws -> Float {
        try Float(decode(Double.self))
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard case let .integer(decoded) = value, let result = T(exactly: decoded) else { throw mismatch(type) }
        return result
    }

    func decode(_ type: Int.Type) throws -> Int {
        try integer(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try integer(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try integer(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try integer(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try integer(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try integer(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try integer(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try integer(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try integer(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try integer(type)
    }

    private struct Fields<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: SettingsLuauDecoder
        let fields: [String: SettingsLuauValue]
        var codingPath: [any CodingKey] {
            decoder.codingPath
        }

        var allKeys: [Key] {
            fields.keys.compactMap(Key.init(stringValue:))
        }

        private func child(_ key: Key) throws -> SettingsLuauDecoder {
            let fallback = decoder.defaults?[key.stringValue]
            guard let value = fields[key.stringValue] ?? fallback else {
                throw DecodingError.keyNotFound(
                    key,
                    .init(codingPath: codingPath, debugDescription: "Missing setting.")
                )
            }
            return SettingsLuauDecoder(
                value: value,
                defaults: fallback,
                validatesSettings: decoder.validatesSettings,
                codingPath: codingPath + [key]
            )
        }

        func contains(_ key: Key) -> Bool {
            fields[key.stringValue] != nil || decoder.defaults?[key.stringValue] != nil
        }

        func decodeNil(forKey _: Key) throws -> Bool {
            false
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try T(from: child(key))
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type,
            forKey key: Key
        ) throws -> KeyedDecodingContainer<NestedKey> {
            try child(key).container(keyedBy: type)
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try child(key)
                .unkeyedContainer()
        }

        func superDecoder() throws -> any Decoder {
            decoder
        }

        func superDecoder(forKey key: Key) throws -> any Decoder {
            try child(key)
        }
    }

    private struct Elements: UnkeyedDecodingContainer {
        let decoder: SettingsLuauDecoder
        let elements: [SettingsLuauValue]
        var currentIndex = 0
        var codingPath: [any CodingKey] {
            decoder.codingPath
        }

        var count: Int? {
            elements.count
        }

        var isAtEnd: Bool {
            currentIndex >= elements.count
        }

        private mutating func next() throws -> SettingsLuauDecoder {
            guard !isAtEnd else { throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "End of list."
            )) }
            defer { currentIndex += 1 }
            return SettingsLuauDecoder(
                value: elements[currentIndex], validatesSettings: decoder.validatesSettings,
                codingPath: codingPath + [DynamicCodingKey(intValue: currentIndex)!]
            )
        }

        mutating func decodeNil() throws -> Bool {
            false
        }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try T(from: next())
        }

        mutating func nestedContainer<Key: CodingKey>(keyedBy type: Key
            .Type) throws -> KeyedDecodingContainer<Key>
        {
            try next().container(keyedBy: type)
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            try next().unkeyedContainer()
        }

        mutating func superDecoder() throws -> any Decoder {
            try next()
        }
    }
}
