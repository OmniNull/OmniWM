// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import OmniWMScriptHost

enum ConfigScriptCommandParser {
    enum Outcome {
        case request(IPCCommandRequest)
        case unknown
        case invalidArguments
    }

    static let maximumWordCount = IPCAutomationManifest.commandDescriptors.reduce(0) {
        max($0, $1.commandWords.count + $1.arguments.count)
    }

    private struct Entry {
        let name: IPCCommandName
        let words: Range<Int>
        let arguments: Range<Int>
    }

    private struct Table {
        let bytes: [UInt8]
        let words: [Range<Int>]
        let kinds: [IPCCommandArgumentKind]
        let entries: [Entry]
        let groups: [Int: Range<Int>]

        init() {
            let ordered = IPCAutomationManifest.commandDescriptors.map { descriptor in
                (Array(descriptor.commandWords[0].utf8).withUnsafeBytes(ConfigScriptCommandParser.hash), descriptor)
            }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.1, rhs.1)
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                if left.commandWords[0] != right.commandWords[0] {
                    return left.commandWords[0] < right.commandWords[0]
                }
                if left.commandWords.count != right.commandWords.count {
                    return left.commandWords.count > right.commandWords.count
                }
                return left.path < right.path
            }
            var bytes: [UInt8] = []
            var words: [Range<Int>] = []
            var kinds: [IPCCommandArgumentKind] = []
            var entries: [Entry] = []
            var groups: [Int: Range<Int>] = [:]
            for (key, descriptor) in ordered {
                let firstWord = words.count
                for word in descriptor.commandWords {
                    let start = bytes.count
                    bytes.append(contentsOf: word.utf8)
                    words.append(start ..< bytes.count)
                }
                let firstArgument = kinds.count
                kinds.append(contentsOf: descriptor.arguments.map(\.kind))
                let index = entries.count
                entries.append(Entry(
                    name: descriptor.name,
                    words: firstWord ..< words.count,
                    arguments: firstArgument ..< kinds.count
                ))
                groups[key] = (groups[key]?.lowerBound ?? index) ..< index + 1
            }
            self.bytes = bytes
            self.words = words
            self.kinds = kinds
            self.entries = entries
            self.groups = groups
        }

        func matches(_ word: Int, _ span: omni_config_span) -> Bool {
            bytes[words[word]].elementsEqual(ConfigScriptCommandParser.bytes(span))
        }
    }

    private static let table = Table()

    static func request(_ spans: UnsafeBufferPointer<omni_config_span>) -> Outcome {
        guard let group = table.groups[hash(bytes(spans[0]))] else { return .unknown }
        var named = false
        candidates: for entry in table.entries[group] {
            let wordCount = entry.words.count
            guard wordCount <= spans.count else { continue }
            for offset in 0 ..< wordCount where !table.matches(entry.words.lowerBound + offset, spans[offset]) {
                continue candidates
            }
            named = true
            guard spans.count == wordCount + entry.arguments.count else { continue }
            var values: [IPCCommandArgumentValue] = []
            if !entry.arguments.isEmpty { values.reserveCapacity(entry.arguments.count) }
            for (offset, kind) in table.kinds[entry.arguments].enumerated() {
                guard let token = String(validating: bytes(spans[wordCount + offset]), as: UTF8.self),
                      let value = IPCCommandArgumentValue(token: token, kind: kind)
                else { continue candidates }
                values.append(value)
            }
            if let request = try? IPCCommandRequest(name: entry.name, argumentValues: values) {
                return .request(request)
            }
        }
        return named ? .invalidArguments : .unknown
    }

    static func text(_ spans: UnsafeBufferPointer<omni_config_span>) -> String {
        var text: [UInt8] = []
        for (index, span) in spans.enumerated() {
            if index > 0 { text.append(UInt8(ascii: " ")) }
            text.append(contentsOf: bytes(span))
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }

    private static func hash(_ bytes: UnsafeRawBufferPointer) -> Int {
        var hasher = Hasher()
        hasher.combine(bytes: bytes)
        return hasher.finalize()
    }
}
