// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

final class ConfigScriptCommandParserTests: XCTestCase {
    private static let openTokens: [IPCCommandArgumentKind: [String]] = [
        .appID: ["test.app", ""],
        .workspaceNumber: ["1", "3", "0", "-1", "x"],
        .columnIndex: ["1", "2", "0", "x"],
        .windowIndex: ["1", "2", "0", "x"],
        .sizeChange: ["+10%", "50%", "-5", "x", ""]
    ]

    private static let groupsByWord = Dictionary(uniqueKeysWithValues:
        ConfigScriptCommandParser.inventory().enumerated().map { index, group in (group.word, index) }
    )

    func testEveryManifestCommandAndArgumentParsesLikeTheCLIParser() throws {
        var checked = 0
        for descriptor in IPCAutomationManifest.commandDescriptors {
            let choices = try descriptor.arguments.map { argument in
                try argument.kind.literalValues.map { $0 + ["not-a-value"] }
                    ?? XCTUnwrap(Self.openTokens[argument.kind], argument.kind.rawValue)
            }
            for arguments in Self.product(choices) {
                assertSameRequest(descriptor.commandWords + arguments)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, IPCAutomationManifest.commandDescriptors.count)
    }

    func testWrongArityAndBadTextAreRejected() throws {
        for descriptor in IPCAutomationManifest.commandDescriptors {
            assertSameRequest(descriptor.commandWords + descriptor.arguments.map { _ in "1" } + ["extra"])
            if !descriptor.arguments.isEmpty { assertSameRequest(descriptor.commandWords) }
        }
        for words in [["focus-monitor", "sideways"], ["switch-workspace"], ["focus", "left", "up"]] {
            assertSameRequest(words)
        }
        let group = try XCTUnwrap(Self.groupsByWord[IPCCommandName.shellAppOpen.rawValue])
        withWords([[0xFF]]) { words in
            XCTAssertNil(ConfigScriptCommandParser.request(group: group, words))
        }
        withWords([]) { words in
            XCTAssertNil(ConfigScriptCommandParser.request(group: Self.groupsByWord.count, words))
        }
    }

    private func assertSameRequest(_ words: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let word = words.first, let group = Self.groupsByWord[word] else {
            return XCTFail("Expected a command group for \(words)", file: file, line: line)
        }
        let arguments = words.dropFirst().map { Array($0.utf8) }
        XCTAssertEqual(
            withWords(arguments) { ConfigScriptCommandParser.request(group: group, $0) },
            IPCCommandRequest(commandWords: words),
            words.joined(separator: " "),
            file: file,
            line: line
        )
    }

    private func withWords<Result>(
        _ words: [[UInt8]],
        _ body: (UnsafeBufferPointer<omni_config_word>) -> Result
    ) -> Result {
        withConfigSpans(words) { spans in
            spans.map { omni_config_word(text: $0, selector: 0) }.withUnsafeBufferPointer(body)
        }
    }

    private static func product(_ choices: [[String]]) -> [[String]] {
        choices.reduce([[]]) { partial, options in partial.flatMap { prefix in options.map { prefix + [$0] } } }
    }
}
