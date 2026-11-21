// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum CLICompletionInput {
    static func words(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String] {
        guard let name = arguments.first, let shell = CLIShell(rawValue: name) else {
            throw CLIParseError.usage("Invalid completion shell")
        }
        let input = Array(arguments.dropFirst())
        switch shell {
        case .bash:
            guard let line = environment["COMP_LINE"],
                  let point = environment["COMP_POINT"].flatMap(Int.init),
                  point >= 0, point <= line.utf8.count
            else { throw CLIParseError.usage("Missing completion cursor") }
            return bashWords(String(decoding: line.utf8.prefix(point), as: UTF8.self))
        case .zsh:
            guard let position = input.first.flatMap(Int.init), position > 0, position <= input.count else {
                throw CLIParseError.usage("Invalid completion cursor")
            }
            var words = Array(input.dropFirst().prefix(position))
            if words.count < position { words.append("") }
            return words
        case .fish:
            var words = input.first == "--" ? Array(input.dropFirst()) : input
            if let current = words.popLast() { words.append(bashWords(current).last ?? "") }
            return words
        case .nu:
            return input.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
    }

    static func bashWords(_ line: String) -> [String] {
        var parser = WordParser()
        for character in line { parser.append(character) }
        return parser.words + [parser.token]
    }

    private struct WordParser {
        var words: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var started = false

        mutating func append(_ character: Character) {
            if escaped {
                if quote == "\"", !"$`\"\\\n".contains(character) { token.append("\\") }
                if character != "\n" { token.append(character) }
                escaped = false
            } else if quote == "'" {
                if character == "'" { quote = nil }
                else { token.append(character) }
            } else if character == "\\" {
                escaped = true
                started = true
            } else if let quote {
                if character == quote { self.quote = nil }
                else { token.append(character) }
            } else {
                appendUnquoted(character)
            }
        }

        private mutating func appendUnquoted(_ character: Character) {
            if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if ";|&\n".contains(character) {
                words.removeAll(keepingCapacity: true)
                token = ""
                started = false
            } else if character.isWhitespace {
                if started { words.append(token) }
                token = ""
                started = false
            } else {
                token.append(character)
                started = true
            }
        }
    }
}
