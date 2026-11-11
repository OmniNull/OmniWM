// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

enum AppThemeTOMLTableError: Error, Equatable, LocalizedError {
    case invalidConfig(String)
    case invalidSection
    case wouldChangeOtherTables

    var errorDescription: String? {
        switch self {
        case let .invalidConfig(path):
            String(localized: "\(path) is not valid TOML, so OmniWM left it unchanged")
        case .invalidSection:
            String(localized: "The rendered template is not a valid TOML table")
        case .wouldChangeOtherTables:
            String(
                localized: "Replacing the table would change other settings in the file, so OmniWM left it unchanged"
            )
        }
    }
}

struct AppThemeTOMLTable {
    struct Header: Equatable {
        let keys: [String]
        let isArray: Bool
        let lineStart: Int
        let lineEnd: Int
    }

    let keys: [String]

    func section(in text: String) -> Range<Int>? {
        let scan = AppThemeTOMLScanner(text: Array(text.utf8))
        let headers = scan.headers
        guard let index = headers.firstIndex(where: { $0.keys == keys && !$0.isArray }) else { return nil }
        let header = headers[index]
        let limit = headers.indices.contains(index + 1) ? headers[index + 1].lineStart : scan.bytes.count
        let lastStatement = scan.statementEnds.last { $0 > header.lineEnd && $0 <= limit } ?? header.lineEnd
        return header.lineStart ..< lastStatement
    }

    func current(in text: String) -> String? {
        section(in: text).map { Self.slice(text, $0) }
    }

    func replacing(in text: String, with replacement: String, path: String) throws -> String {
        let original = try Self.parse(text, path: path)
        let rendered = try Self.parse(replacement, path: path)
        guard Self.table(at: keys, in: rendered) != nil,
              rendered.count == 1 || keys.isEmpty
        else {
            throw AppThemeTOMLTableError.invalidSection
        }
        let body = replacement.hasSuffix("\n") ? replacement : replacement + "\n"
        let candidate: String
        if let range = section(in: text) {
            let bytes = Array(text.utf8)
            let after = String(decoding: bytes[range.upperBound...], as: UTF8.self)
            let before = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
            candidate = before + body + (after.hasPrefix("\n") || after.isEmpty ? after : "\n" + after)
        } else {
            let separator = text.isEmpty ? "" : text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            candidate = text + separator + body
        }
        let parsed = try Self.parse(candidate, path: path)
        guard Self.removingScalars(at: keys, from: parsed) == Self.removingScalars(at: keys, from: original),
              Self.scalars(at: keys, in: parsed) == Self.scalars(at: keys, in: rendered)
        else {
            throw AppThemeTOMLTableError.wouldChangeOtherTables
        }
        return candidate
    }

    private static func slice(_ text: String, _ range: Range<Int>) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    private static func parse(_ text: String, path: String) throws -> [String: TOMLNode] {
        do {
            return try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
        } catch {
            throw AppThemeTOMLTableError.invalidConfig(path)
        }
    }

    private static func table(at keys: [String], in root: [String: TOMLNode]) -> [String: TOMLNode]? {
        var current = root
        for key in keys {
            guard case let .table(next)? = current[key] else { return nil }
            current = next
        }
        return current
    }

    private static func scalars(at keys: [String], in root: [String: TOMLNode]) -> [String: TOMLNode] {
        (table(at: keys, in: root) ?? [:]).filter { if case .table = $0.value { false } else { true } }
    }

    private static func removingScalars(at keys: [String], from root: [String: TOMLNode]) -> [String: TOMLNode] {
        guard let first = keys.first else { return root }
        var root = root
        guard case let .table(child)? = root[first] else { return root }
        if keys.count == 1 {
            let kept = child.filter { if case .table = $0.value { true } else { false } }
            root[first] = kept.isEmpty ? nil : .table(kept)
        } else {
            let stripped = removingScalars(at: Array(keys.dropFirst()), from: child)
            root[first] = stripped.isEmpty ? nil : .table(stripped)
        }
        return root
    }
}
