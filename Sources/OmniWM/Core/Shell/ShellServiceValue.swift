// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

indirect enum ShellServiceValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case bytes([UInt8])
    case array([ShellServiceValue])
    case object([String: ShellServiceValue])

    struct Failure: Error, Equatable, Sendable {}

    var string: String? {
        guard case let .bytes(bytes) = self else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    var number: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var boolean: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var fields: [String: ShellServiceValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var values: [ShellServiceValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    static func text(_ value: String) -> ShellServiceValue {
        .bytes(Array(value.utf8))
    }

    static func decode(_ bytes: [UInt8], byteLimit: Int = 4 << 20, nodeLimit: Int = 65536) throws -> ShellServiceValue {
        guard bytes.count <= byteLimit else { throw Failure() }
        var reader = Reader(bytes: bytes, remaining: nodeLimit)
        let result = try reader.read(depth: 0)
        guard reader.offset == bytes.count else { throw Failure() }
        return result
    }

    func write(to writer: inout ShellValueWriter) {
        switch self {
        case .null: writer.null()
        case let .bool(value): writer.bool(value)
        case let .number(value): writer.number(value)
        case let .bytes(value): writer.string(bytes: value)
        case let .array(values):
            writer.array(values.count)
            for value in values { value.write(to: &writer) }
        case let .object(fields):
            writer.map(fields.count)
            for key in fields.keys.sorted() {
                writer.key(key)
                fields[key]?.write(to: &writer)
            }
        }
    }

    var componentValue: ShellComponentValue? {
        switch self {
        case let .bool(value): .bool(value)
        case let .number(value): .number(value)
        case .bytes: string.map(ShellComponentValue.string)
        case let .array(values):
            values.allSatisfy { $0.string != nil } ? .strings(values.compactMap(\.string)) : nil
        case let .object(fields): fields.isEmpty ? .strings([]) : nil
        default: nil
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var remaining: Int
        var offset = 0

        mutating func read(depth: Int) throws -> ShellServiceValue {
            guard depth <= 64, remaining > 0, offset < bytes.count else { throw Failure() }
            remaining -= 1
            let tag = omni_value_tag(rawValue: UInt32(bytes[offset]))
            offset += 1
            switch tag {
            case OMNI_VALUE_NIL: return .null
            case OMNI_VALUE_FALSE: return .bool(false)
            case OMNI_VALUE_TRUE: return .bool(true)
            case OMNI_VALUE_NUMBER:
                let bits: UInt64 = try scalar()
                let value = Double(bitPattern: UInt64(littleEndian: bits))
                guard value.isFinite else { throw Failure() }
                return .number(value)
            case OMNI_VALUE_STRING: return try .bytes(blob())
            case OMNI_VALUE_ARRAY:
                let count = try count()
                guard count <= remaining, count <= bytes.count - offset else { throw Failure() }
                var values: [ShellServiceValue] = []
                values.reserveCapacity(count)
                for _ in 0 ..< count { values.append(try read(depth: depth + 1)) }
                return .array(values)
            case OMNI_VALUE_MAP:
                let count = try count()
                guard count <= remaining, count <= (bytes.count - offset) / 5 else { throw Failure() }
                var fields: [String: ShellServiceValue] = [:]
                fields.reserveCapacity(count)
                for _ in 0 ..< count {
                    guard let key = String(bytes: try blob(), encoding: .utf8), fields[key] == nil else {
                        throw Failure()
                    }
                    fields[key] = try read(depth: depth + 1)
                }
                return .object(fields)
            default: throw Failure()
            }
        }

        private mutating func count() throws -> Int {
            let value: UInt32 = try scalar()
            return Int(UInt32(littleEndian: value))
        }

        private mutating func blob() throws -> [UInt8] {
            let count = try count()
            guard count <= bytes.count - offset else { throw Failure() }
            defer { offset += count }
            return Array(bytes[offset ..< offset + count])
        }

        private mutating func scalar<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard size <= bytes.count - offset else { throw Failure() }
            defer { offset += size }
            return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
    }
}
