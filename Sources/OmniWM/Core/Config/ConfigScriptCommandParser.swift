// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import OmniWMScriptHost

enum ConfigScriptCommandParser {
    struct Group {
        let word: String
        let member: String
        let forms: [IPCCommandDescriptor]
    }

    static func inventory() -> [Group] {
        let grouped = Dictionary(grouping: IPCAutomationManifest.commandDescriptors) { $0.commandWords[0] }
        return grouped.keys.sorted().map { word in
            let parts = word.split(separator: "-")
            let member = String(parts.first ?? "") + parts.dropFirst().map {
                $0.prefix(1).uppercased() + $0.dropFirst()
            }.joined()
            let forms = grouped[word, default: []].sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.path < $1.path
            }
            return Group(word: word, member: member, forms: forms)
        }
    }

    static let maximumArgumentCount = IPCAutomationManifest.commandDescriptors.reduce(0) {
        max($0, $1.commandWords.count - 1 + $1.arguments.count)
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
        let groupEntries: [Range<Int>]
        let groupWords: [String]

        init() {
            let inventory = ConfigScriptCommandParser.inventory()
            var bytes: [UInt8] = []
            var words: [Range<Int>] = []
            var kinds: [IPCCommandArgumentKind] = []
            var entries: [Entry] = []
            var groupEntries: [Range<Int>] = []
            groupEntries.reserveCapacity(inventory.count)
            for group in inventory {
                let start = entries.count
                for descriptor in group.forms {
                    let firstWord = words.count
                    for word in descriptor.commandWords.dropFirst() {
                        let start = bytes.count
                        bytes.append(contentsOf: word.utf8)
                        words.append(start ..< bytes.count)
                    }
                    let firstArgument = kinds.count
                    kinds.append(contentsOf: descriptor.arguments.map(\.kind))
                    entries.append(Entry(
                        name: descriptor.name,
                        words: firstWord ..< words.count,
                        arguments: firstArgument ..< kinds.count
                    ))
                }
                groupEntries.append(start ..< entries.count)
            }
            self.bytes = bytes
            self.words = words
            self.kinds = kinds
            self.entries = entries
            self.groupEntries = groupEntries
            groupWords = inventory.map(\.word)
        }

        func matches(_ word: Int, _ span: omni_config_span) -> Bool {
            bytes[words[word]].elementsEqual(ConfigScriptCommandParser.bytes(span))
        }
    }

    private static let table = Table()

    static func request(group: Int, _ spans: UnsafeBufferPointer<omni_config_span>) -> IPCCommandRequest? {
        guard table.groupEntries.indices.contains(group) else { return nil }
        candidates: for index in table.groupEntries[group] {
            let entry = table.entries[index]
            let wordCount = entry.words.count
            guard spans.count == wordCount + entry.arguments.count else { continue }
            for offset in 0 ..< wordCount where !table.matches(entry.words.lowerBound + offset, spans[offset]) {
                continue candidates
            }
            var values: [IPCCommandArgumentValue] = []
            if !entry.arguments.isEmpty { values.reserveCapacity(entry.arguments.count) }
            for (offset, kind) in table.kinds[entry.arguments].enumerated() {
                guard let token = String(validating: bytes(spans[wordCount + offset]), as: UTF8.self),
                      let value = IPCCommandArgumentValue(token: token, kind: kind)
                else { continue candidates }
                values.append(value)
            }
            if let request = try? IPCCommandRequest(name: entry.name, argumentValues: values) {
                return request
            }
        }
        return nil
    }

    static func word(group: Int) -> String? {
        guard table.groupWords.indices.contains(group) else { return nil }
        return table.groupWords[group]
    }

    static func text(group: Int, _ spans: UnsafeBufferPointer<omni_config_span>) -> String {
        let firstWord = table.groupWords[group]
        guard !spans.isEmpty else { return firstWord }
        var text = Array(firstWord.utf8)
        for span in spans {
            text.append(UInt8(ascii: " "))
            text.append(contentsOf: bytes(span))
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }
}
