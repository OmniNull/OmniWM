// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct IPCJSONWriter: ~Copyable {
    enum Failure: Error {
        case nonFiniteNumber
    }

    private var data = Data()
    private let prettyPrinted: Bool
    private var depth = 0

    init(prettyPrinted: Bool) {
        self.prettyPrinted = prettyPrinted
    }

    consuming func finishLine() -> Data {
        data.append(0x0A)
        return data
    }

    mutating func raw(_ value: StaticString) {
        value.withUTF8Buffer { data.append(contentsOf: $0) }
    }

    mutating func text(_ value: borrowing String) {
        data.append(contentsOf: value.utf8)
    }

    mutating func begin(_ byte: UInt8) {
        data.append(byte)
        depth += 1
        if prettyPrinted { data.append(10) }
    }

    mutating func end(_ byte: UInt8) {
        depth -= 1
        if prettyPrinted {
            data.append(10)
            indent()
        }
        data.append(byte)
    }

    mutating func item(_ first: inout Bool) {
        if !first {
            data.append(44)
            if prettyPrinted { data.append(10) }
        }
        first = false
        if prettyPrinted { indent() }
    }

    mutating func key(_ value: StaticString, _ first: inout Bool) {
        item(&first)
        data.append(34)
        raw(value)
        raw(prettyPrinted ? "\" : " : "\":")
    }

    private mutating func indent() {
        for _ in 0 ..< depth { raw("  ") }
    }

    private mutating func stringBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        data.append(34)
        var start = 0
        for index in bytes.indices {
            let byte = bytes[index]
            guard byte < 32 || byte == 34 || byte == 47 || byte == 92 else { continue }
            if index > start { data.append(contentsOf: bytes[start ..< index]) }
            switch byte {
            case 34: raw("\\\"")
            case 47: raw("\\/")
            case 92: raw("\\\\")
            case 8: raw("\\b")
            case 9: raw("\\t")
            case 10: raw("\\n")
            case 12: raw("\\f")
            case 13: raw("\\r")
            default:
                raw("\\u00")
                let high = byte >> 4
                let low = byte & 15
                data.append(high < 10 ? high + 48 : high + 87)
                data.append(low < 10 ? low + 48 : low + 87)
            }
            start = index + 1
        }
        if start < bytes.count { data.append(contentsOf: bytes[start...]) }
        data.append(34)
    }

    mutating func value(_ value: borrowing String) throws {
        if value.utf8.withContiguousStorageIfAvailable({ stringBytes($0) }) == nil {
            Array(value.utf8).withUnsafeBufferPointer { stringBytes($0) }
        }
    }

    mutating func value(_ value: Bool) throws {
        raw(value ? "true" : "false")
    }

    mutating func value(_ value: Int) throws {
        text(String(value))
    }

    mutating func value(_ value: Int32) throws {
        text(String(value))
    }

    mutating func value(_ value: Int64) throws {
        text(String(value))
    }

    mutating func value(_ value: UInt) throws {
        text(String(value))
    }

    mutating func value(_ value: UInt32) throws {
        text(String(value))
    }

    mutating func value(_ value: UInt64) throws {
        text(String(value))
    }

    mutating func value(_ value: Double) throws {
        guard value.isFinite else {
            throw Failure.nonFiniteNumber
        }
        if value == 0 {
            raw(value.sign == .minus ? "-0" : "0")
            return
        }
        var number = String(value)
        if let exponent = number.firstIndex(of: "e") {
            let fraction = number[..<exponent]
            if fraction.hasSuffix(".0") { number.removeSubrange(number.index(exponent, offsetBy: -2) ..< exponent) }
        } else if number.hasSuffix(".0") {
            number.removeLast(2)
        }
        text(number)
    }
}
