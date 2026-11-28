// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsTableText {
    struct Row {
        var origin: Int?
        var text: String?
    }

    private struct Trivia {
        var spacing: String
        var leading: String
        let end: Int
        let comments: Range<Int>
        let endsInLineComment: Bool
    }

    let document: LuauTableDocument
    let table: SettingsSourceTable
    let newline: String

    private func text(_ range: Range<Int>) -> String {
        String(decoding: document.source[range], as: UTF8.self)
    }

    private func indentation(at offset: Int) -> String {
        let bytes = document.source
        let start = bytes[..<offset].lastIndex(of: 10).map { $0 + 1 } ?? 0
        return String(decoding: bytes[start ..< offset].prefix { $0 == 9 || $0 == 32 }, as: UTF8.self)
    }

    private var rowIndent: String {
        let parent = indentation(at: table.bytes.lowerBound)
        for item in table.items {
            let indent = indentation(at: item.bytes.lowerBound)
            if indent.hasPrefix(parent), indent.count > parent.count { return indent }
        }
        let firstIndent = document.source.split(separator: 10).lazy.map { $0.prefix { $0 == 9 || $0 == 32 } }
            .first { !$0.isEmpty }
        return parent + (firstIndent.map { String(decoding: $0, as: UTF8.self) } ?? "    ")
    }

    func literal(_ value: SettingsLuauValue) -> String {
        let source = value.literal()
        guard source.utf8.contains(10) else { return source }
        let indent = rowIndent
        let parent = indentation(at: table.bytes.lowerBound)
        let unit = String(indent.dropFirst(parent.count))
        return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            guard index > 0 else { return String(line) }
            let leading = line.prefix { $0 == " " }.count
            return indent + String(repeating: unit, count: leading / 4) + line.dropFirst(leading)
        }.joined(separator: newline)
    }

    func render(_ rows: [Row]) -> String {
        let items = table.items
        if rows.count == items.count, rows.enumerated().allSatisfy({ $0.offset == $0.element.origin }) {
            var copy = document.source.subdata(in: table.bytes)
            for (item, row) in zip(items, rows).reversed() {
                guard let replacement = row.text else { continue }
                let lower = item.bytes.lowerBound - table.bytes.lowerBound
                copy.replaceSubrange(lower ..< lower + item.bytes.count, with: replacement.utf8)
            }
            return String(decoding: copy, as: UTF8.self)
        }
        return renderStructure(rows)
    }

    private func trivia() -> [Trivia] {
        var begin = table.bytes.lowerBound + 1
        var result: [Trivia] = []
        let comments = document.comments
        var cursor = comments.firstIndex { $0.lowerBound >= begin } ?? comments.endIndex
        for (index, item) in table.items.enumerated() {
            let firstComment = cursor
            let first = cursor < comments.count ? min(comments[cursor].lowerBound, item.bytes.lowerBound) : item.bytes
                .lowerBound
            var end = item.separator?.upperBound ?? item.bytes.upperBound
            while cursor < comments.count, comments[cursor].lowerBound < end { cursor += 1 }
            let limit = index + 1 < table.items.count ? table.items[index + 1].bytes.lowerBound : table.bytes
                .upperBound - 1
            var trailing: Range<Int>?
            while cursor < comments.count, comments[cursor].upperBound <= limit {
                let comment = comments[cursor]
                guard !document.source[end ..< comment.lowerBound].contains(10) else { break }
                end = comment.upperBound
                trailing = comment
                cursor += 1
            }
            result.append(Trivia(
                spacing: text(begin ..< first),
                leading: text(first ..< item.bytes.lowerBound),
                end: end,
                comments: firstComment ..< cursor,
                endsInLineComment: trailing.map(isLineComment) ?? false
            ))
            begin = end
        }
        return result
    }

    private func isLineComment(_ range: Range<Int>) -> Bool {
        let opener = document.source[range].dropFirst(2)
        guard opener.first == UInt8(ascii: "[") else { return true }
        return opener.dropFirst().drop { $0 == UInt8(ascii: "=") }.first != UInt8(ascii: "[")
    }

    private func standaloneComment(_ range: Range<Int>) -> String {
        let bytes = document.source[range]
        return String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes, as: UTF8.self)
    }

    private func renderStructure(_ rows: [Row]) -> String {
        let trivia = trivia()
        let items = table.items
        let suffix = text((trivia.last?.end ?? table.bytes.lowerBound + 1) ..< table.bytes.upperBound - 1)
        let multiline = items.isEmpty || suffix.utf8.contains(10) || trivia.contains { $0.spacing.utf8.contains(10) }
        let indent = rowIndent
        let spacing = multiline ? newline + indent : (trivia.dropFirst().first?.spacing ?? " ")
        let survivors = Set(rows.compactMap(\.origin))
        var standalone: [Int: [String]] = [:]
        var kept = 0
        for (index, piece) in trivia.enumerated() {
            if survivors.contains(index) {
                kept += 1
                continue
            }
            let removed = document.comments[piece.comments]
            if !removed.isEmpty { standalone[kept, default: []] += removed.map(standaloneComment) }
        }
        let separator = items.compactMap(\.separator).first.map(text) ?? ","
        var result = "{"
        var seen = 0
        var lineComment = false
        for (index, row) in rows.enumerated() {
            let notes = standalone.removeValue(forKey: seen) ?? []
            for note in notes { result += newline + indent + note }
            let originalGap = row.origin.map { trivia[$0].spacing }
            let slotGap = index < trivia.count ? trivia[index].spacing : spacing
            let gap = originalGap.flatMap { $0.utf8.contains(10) ? $0 : nil } ?? slotGap
            result += gap.utf8.contains(10) || (notes.isEmpty && !lineComment) ? gap : newline + indent
            lineComment = false
            guard let origin = row.origin else {
                result += (row.text ?? "") + separator
                continue
            }
            seen += 1
            let item = items[origin]
            result += trivia[origin].leading + (row.text ?? text(item.bytes))
            let insertSeparator = item.separator == nil && index + 1 < rows.count
            if insertSeparator { result += separator }
            result += text(item.bytes.upperBound ..< trivia[origin].end)
            lineComment = trivia[origin].endsInLineComment
        }
        for key in standalone.keys.sorted() {
            for note in standalone[key] ?? [] { result += newline + indent + note }
        }
        if !suffix.utf8.contains(10), lineComment || !standalone.isEmpty || (items.isEmpty && !rows.isEmpty) {
            result += newline + indentation(at: table.bytes.lowerBound)
        }
        return result + suffix + "}"
    }
}
