// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation
import OmniWMIPC
import OmniWMScriptHost

enum ConfigScriptCommandParser {
    enum Request: Equatable {
        case workspaceSwitch(IPCWorkspaceCommand)
        case ipc(IPCCommandRequest)
    }

    enum FormName {
        case workspaceSwitch(IPCWorkspaceCommandName)
        case ipc(IPCCommandName)
    }

    struct Form {
        let name: FormName
        let commandWords: [String]
        let arguments: [IPCCommandArgumentKind]
        let sortKey: String
    }

    struct Group {
        let word: String
        let member: String
        let forms: [Form]
    }

    static func inventory() -> [Group] {
        let switchWord = IPCWorkspaceCommandName.switchTo.rawValue
        let switches = IPCWorkspaceSwitchForm.all.map { form in
            Form(
                name: .workspaceSwitch(form.name), commandWords: form.commandWords,
                arguments: form.argumentKind.map { [$0] } ?? [],
                sortKey: form.commandWords.joined(separator: " ")
            )
        }
        var grouped = [switchWord: switches]
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.commandWords[0] != switchWord {
            grouped[descriptor.commandWords[0], default: []].append(Form(
                name: .ipc(descriptor.name), commandWords: descriptor.commandWords,
                arguments: descriptor.arguments.map(\.kind), sortKey: descriptor.path
            ))
        }
        return grouped.keys.sorted().map { word in
            let parts = word.split(separator: "-")
            let member = String(parts.first ?? "") + parts.dropFirst().map {
                $0.prefix(1).uppercased() + $0.dropFirst()
            }.joined()
            let forms = grouped[word, default: []].sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.sortKey < $1.sortKey
            }
            return Group(word: word, member: member, forms: forms)
        }
    }

    static var maximumArgumentCount: Int {
        table.maximumArgumentCount
    }

    private struct Entry {
        let name: FormName
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
        let maximumArgumentCount: Int

        init() {
            let inventory = ConfigScriptCommandParser.inventory()
            var bytes: [UInt8] = []
            var words: [Range<Int>] = []
            var kinds: [IPCCommandArgumentKind] = []
            var entries: [Entry] = []
            var groupEntries: [Range<Int>] = []
            var maximumArgumentCount = 0
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
                    kinds.append(contentsOf: descriptor.arguments)
                    maximumArgumentCount = max(
                        maximumArgumentCount, descriptor.commandWords.count - 1 + descriptor.arguments.count
                    )
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
            self.maximumArgumentCount = maximumArgumentCount
        }

        func matches(_ index: Int, _ word: omni_config_word) -> Bool {
            word.selector == 0 && bytes[words[index]].elementsEqual(ConfigScriptCommandParser.bytes(word.text))
        }
    }

    private static let table = Table()

    static func request(group: Int, _ words: UnsafeBufferPointer<omni_config_word>) -> Request? {
        guard table.groupEntries.indices.contains(group) else { return nil }
        candidates: for index in table.groupEntries[group] {
            let entry = table.entries[index]
            let wordCount = entry.words.count
            guard words.count == wordCount + entry.arguments.count else { continue }
            for offset in 0 ..< wordCount where !table.matches(entry.words.lowerBound + offset, words[offset]) {
                continue candidates
            }
            var values: [IPCCommandArgumentValue] = []
            if !entry.arguments.isEmpty { values.reserveCapacity(entry.arguments.count) }
            for (offset, kind) in table.kinds[entry.arguments].enumerated() {
                guard let value = argument(words[wordCount + offset], kind: kind) else { continue candidates }
                values.append(value)
            }
            switch entry.name {
            case let .workspaceSwitch(name):
                if let command = try? IPCWorkspaceCommand(switchName: name, argumentValues: values) {
                    return .workspaceSwitch(command)
                }
            case let .ipc(name):
                if let request = try? IPCCommandRequest(name: name, argumentValues: values) {
                    return .ipc(request)
                }
            }
        }
        return nil
    }

    private static func argument(_ word: omni_config_word, kind: IPCCommandArgumentKind) -> IPCCommandArgumentValue? {
        guard word.selector != 0 else {
            return String(validating: bytes(word.text), as: UTF8.self).flatMap {
                IPCCommandArgumentValue(token: $0, kind: kind)
            }
        }
        guard kind.acceptsConfigInteger, let index = Int(exactly: word.selector) else { return nil }
        guard kind != .scratchpadIndex || IPCScratchpadSlots.range.contains(index) else { return nil }
        return .integer(index)
    }

    static func word(group: Int) -> String? {
        guard table.groupWords.indices.contains(group) else { return nil }
        return table.groupWords[group]
    }

    static func text(group: Int, _ words: UnsafeBufferPointer<omni_config_word>) -> String {
        let firstWord = table.groupWords[group]
        guard !words.isEmpty else { return firstWord }
        var text = Array(firstWord.utf8)
        for word in words {
            text.append(UInt8(ascii: " "))
            if word.selector == 0 {
                text.append(contentsOf: bytes(word.text))
            } else {
                text.append(contentsOf: String(word.selector).utf8)
            }
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func bytes(_ span: omni_config_span) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: span.data, count: span.length)
    }
}

extension IPCCommandArgumentKind {
    var acceptsConfigInteger: Bool {
        switch self {
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .scratchpadIndex: true
        default: false
        }
    }
}
