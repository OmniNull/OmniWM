// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

final class ConfigScriptCommandParserTests: XCTestCase {
    private static let openTokens: [IPCCommandArgumentKind: [String]] = [
        .appID: ["test.app", ""],
        .workspaceNumber: ["1", "3", "0", "-1", "x"],
        .columnIndex: ["1", "2", "0", "x"],
        .windowIndex: ["1", "2", "0", "x"],
        .sizeChange: ["+10%", "50%", "-5", "x", ""]
    ]

    private enum Classification: Equatable {
        case request(IPCCommandRequest)
        case unknown
        case invalidArguments
    }

    func testEveryManifestCommandAndArgumentParsesLikeTheCLIParser() throws {
        var checked = 0
        for descriptor in IPCAutomationManifest.commandDescriptors {
            let choices = try descriptor.arguments.map { argument in
                try argument.kind.literalValues.map { $0 + ["not-a-value"] }
                    ?? XCTUnwrap(Self.openTokens[argument.kind], argument.kind.rawValue)
            }
            for arguments in Self.product(choices) {
                assertSameClassification(descriptor.commandWords + arguments)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, IPCAutomationManifest.commandDescriptors.count)
    }

    func testWrongArityUnknownNamesAndBadTextClassifyLikeTheCLIParser() {
        for descriptor in IPCAutomationManifest.commandDescriptors {
            assertSameClassification(descriptor.commandWords + descriptor.arguments.map { _ in "1" } + ["extra"])
            if !descriptor.arguments.isEmpty { assertSameClassification(descriptor.commandWords) }
        }
        for words in [["not-a-command"], ["focus-monitor", "sideways"], ["switch-workspace"], ["focus", "left", "up"]] {
            assertSameClassification(words)
        }
        let appOpen = Array(IPCCommandName.shellAppOpen.rawValue.utf8)
        XCTAssertEqual(classify([appOpen, [0xFF]]), .invalidArguments)
        XCTAssertEqual(classify([[0xFF]]), .unknown)
    }

    private func assertSameClassification(_ words: [String], file: StaticString = #filePath, line: UInt = #line) {
        let expected: Classification = if let request = IPCCommandRequest(commandWords: words) {
            .request(request)
        } else if IPCAutomationManifest.commandDescriptors(matching: words).isEmpty {
            .unknown
        } else {
            .invalidArguments
        }
        XCTAssertEqual(
            classify(words.map { Array($0.utf8) }),
            expected,
            words.joined(separator: " "),
            file: file,
            line: line
        )
    }

    private func classify(_ words: [[UInt8]]) -> Classification {
        withConfigSpans(words) { spans in
            switch ConfigScriptCommandParser.request(spans) {
            case let .request(request): .request(request)
            case .unknown: .unknown
            case .invalidArguments: .invalidArguments
            }
        }
    }

    private static func product(_ choices: [[String]]) -> [[String]] {
        choices.reduce([[]]) { partial, options in partial.flatMap { prefix in options.map { prefix + [$0] } } }
    }
}
