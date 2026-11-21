// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct AppThemeTOMLScanner {
    private static let newline = UInt8(ascii: "\n")
    private static let quote = UInt8(ascii: "\"")
    private static let apostrophe = UInt8(ascii: "'")
    private static let backslash = UInt8(ascii: "\\")
    private static let hash = UInt8(ascii: "#")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")

    let bytes: [UInt8]
    private(set) var headers: [AppThemeTOMLTable.Header] = []
    private(set) var statementEnds: [Int] = []

    init(text: [UInt8]) {
        bytes = text
        scan()
    }

    private mutating func scan() {
        var index = 0
        while index < bytes.count {
            let lineStart = index
            index = skipBlanks(from: index)
            guard index < bytes.count else { break }
            switch bytes[index] {
            case Self.newline,
                 UInt8(ascii: "\r"):
                index += 1
            case Self.hash:
                index = endOfLine(from: index)
            case Self.openBracket:
                let lineEnd = endOfLine(from: index)
                if let header = header(at: index, lineStart: lineStart, lineEnd: lineEnd) {
                    headers.append(header)
                }
                index = lineEnd
            default:
                index = endOfStatement(from: index)
                statementEnds.append(index)
            }
        }
    }

    private func header(at start: Int, lineStart: Int, lineEnd: Int) -> AppThemeTOMLTable.Header? {
        let isArray = start + 1 < bytes.count && bytes[start + 1] == Self.openBracket
        var index = start + (isArray ? 2 : 1)
        var keys: [String] = []
        while index < lineEnd {
            index = skipBlanks(from: index)
            guard index < lineEnd, let (key, next) = key(at: index) else { return nil }
            keys.append(key)
            index = skipBlanks(from: next)
            guard index < lineEnd else { return nil }
            if bytes[index] == UInt8(ascii: ".") {
                index += 1
                continue
            }
            guard bytes[index] == Self.closeBracket else { return nil }
            if isArray {
                guard index + 1 < lineEnd, bytes[index + 1] == Self.closeBracket else { return nil }
            }
            return AppThemeTOMLTable.Header(keys: keys, isArray: isArray, lineStart: lineStart, lineEnd: lineEnd)
        }
        return nil
    }

    private func key(at start: Int) -> (String, Int)? {
        switch bytes[start] {
        case Self.quote:
            var index = start + 1
            var value: [UInt8] = []
            while index < bytes.count, bytes[index] != Self.quote, bytes[index] != Self.newline {
                if bytes[index] == Self.backslash, index + 1 < bytes.count {
                    index += 1
                }
                value.append(bytes[index])
                index += 1
            }
            guard index < bytes.count, bytes[index] == Self.quote else { return nil }
            return (String(decoding: value, as: UTF8.self), index + 1)
        case Self.apostrophe:
            guard let close = bytes[(start + 1)...].firstIndex(where: { $0 == Self.apostrophe || $0 == Self.newline }),
                  bytes[close] == Self.apostrophe
            else { return nil }
            return (String(decoding: bytes[(start + 1) ..< close], as: UTF8.self), close + 1)
        default:
            var index = start
            while index < bytes.count, Self.isBareKey(bytes[index]) {
                index += 1
            }
            guard index > start else { return nil }
            return (String(decoding: bytes[start ..< index], as: UTF8.self), index)
        }
    }

    private static func isBareKey(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "_"),
             UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    private func endOfStatement(from start: Int) -> Int {
        var index = start
        var depth = 0
        while index < bytes.count {
            switch bytes[index] {
            case Self.quote,
                 Self.apostrophe:
                index = endOfString(from: index)
            case Self.hash:
                index = endOfLine(from: index) - 1
            case Self.openBracket,
                 UInt8(ascii: "{"):
                depth += 1
                index += 1
            case Self.closeBracket,
                 UInt8(ascii: "}"):
                depth = max(0, depth - 1)
                index += 1
            case Self.newline:
                index += 1
                if depth == 0 { return index }
            default:
                index += 1
            }
        }
        return bytes.count
    }

    private func endOfString(from start: Int) -> Int {
        let delimiter = bytes[start]
        let escapes = delimiter == Self.quote
        let multiline = start + 2 < bytes.count && bytes[start + 1] == delimiter && bytes[start + 2] == delimiter
        var index = start + (multiline ? 3 : 1)
        while index < bytes.count {
            let byte = bytes[index]
            if escapes, byte == Self.backslash {
                index += 2
                continue
            }
            if !multiline, byte == Self.newline { return index }
            if byte == delimiter {
                if !multiline { return index + 1 }
                if index + 2 < bytes.count, bytes[index + 1] == delimiter, bytes[index + 2] == delimiter {
                    var end = index + 3
                    while end < bytes.count, bytes[end] == delimiter, end < index + 5 {
                        end += 1
                    }
                    return end
                }
            }
            index += 1
        }
        return bytes.count
    }

    private func skipBlanks(from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "\t") {
            index += 1
        }
        return index
    }

    private func endOfLine(from start: Int) -> Int {
        guard let newline = bytes[start...].firstIndex(of: Self.newline) else { return bytes.count }
        return newline + 1
    }
}
