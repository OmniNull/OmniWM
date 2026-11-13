// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLIInvocationParsingTests: XCTestCase {
    func testRemoteFamiliesKeepRequestKindOutputFormatAndInvocationFlags() throws {
        let cases: [(arguments: [String], kind: IPCRequestKind)] = [
            (["ping"], .ping),
            (["version"], .version),
            (["--version"], .version),
            (["-V"], .version),
            (["command", "focus", "left"], .command),
            (["query", "windows"], .query),
            (["rule", "remove", "B9B137A2-9406-4D68-BD0E-8ED465450413"], .rule),
            (["capture", "status"], .capture),
            (["workspace", "focus-name", "1"], .workspace),
            (["window", "focus", "window-id"], .window),
            (["window", "mark", "list"], .windowMark)
        ]
        for testCase in cases {
            for formatArguments in [[], ["--format", "json"]] {
                let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + formatArguments + testCase.arguments)

                XCTAssertEqual(parsed.request.kind, testCase.kind)
                XCTAssertEqual(parsed.request.version, OmniWMIPCProtocol.version)
                XCTAssertNotNil(UUID(uuidString: parsed.request.id))
                XCTAssertEqual(parsed.outputFormat, !formatArguments.isEmpty || testCase.kind == .query ? .json : .text)
                XCTAssertFalse(parsed.expectsEventStream)
                XCTAssertNil(parsed.watchConfiguration)
                XCTAssertFalse(parsed.reconnect)
            }
        }
    }

    func testLocalInvocationsKeepTextOutputWithExplicitJSONFlag() throws {
        for help in ["help", "--help", "-h"] {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "--format", "json", help])
            XCTAssertEqual(parsed.invocation, .local(.help))
            XCTAssertEqual(parsed.outputFormat, .text)
            XCTAssertFalse(parsed.expectsEventStream)
        }
        for shell in CLIShell.allCases {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "completion", shell.rawValue, "--json"])
            XCTAssertEqual(parsed.invocation, .local(.completion(shell)))
            XCTAssertEqual(parsed.outputFormat, .text)
            XCTAssertFalse(parsed.expectsEventStream)
        }
    }

    func testPayloadFreeAndUnknownCommandsKeepUsageFailures() {
        for arguments in [
            ["ping", "extra"],
            ["version", "extra"],
            ["--version", "extra"],
            ["-V", "extra"],
            ["unknown"],
            []
        ] {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + arguments)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testCommandPaletteModesParseThroughSharedCommandWords() throws {
        let toggle = try IPCCommandRequest(name: .openCommandPalette, argumentValues: [])
        XCTAssertEqual(IPCCommandRequest(commandWords: ["open-command-palette"]), toggle)
        XCTAssertEqual(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "open-command-palette"]).request.payload,
            .command(toggle)
        )
        for mode in IPCCommandPaletteMode.allCases {
            let expected = try IPCCommandRequest(name: .openCommandPaletteMode, argumentValues: [.paletteMode(mode)])
            XCTAssertEqual(IPCCommandRequest(commandWords: ["open-command-palette", mode.rawValue]), expected)
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "open-command-palette", mode.rawValue])
            XCTAssertEqual(parsed.request.payload, .command(expected))
        }
        for arguments in [["open-command-palette", "bogus"], ["open-command-palette", "windows", "extra"]] {
            XCTAssertNil(IPCCommandRequest(commandWords: arguments))
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "command"] + arguments)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testWindowSwitcherParsesDirectionAndOptionalScope() throws {
        let accepted: [([String], IPCCommandRequest)] = [
            (["next"], .windowSwitcher(direction: .next, scope: nil)),
            (["previous"], .windowSwitcher(direction: .previous, scope: nil)),
            (["next", "active-workspace"], .windowSwitcher(direction: .next, scope: .activeWorkspace)),
            (["previous", "visible-workspaces"], .windowSwitcher(direction: .previous, scope: .visibleWorkspaces)),
            (["next", "all-workspaces"], .windowSwitcher(direction: .next, scope: .allWorkspaces))
        ]
        for (words, expected) in accepted {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command", "window-switcher"] + words)
            XCTAssertEqual(parsed.request.payload, .command(expected), words.joined(separator: " "))
        }
        for words in [[], ["forward"], ["all-workspaces"], ["next", "bogus"], ["next", "all-workspaces", "extra"]] {
            XCTAssertNil(IPCCommandRequest(commandWords: ["window-switcher"] + words), words.joined(separator: " "))
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "command", "window-switcher"] + words)) {
                XCTAssertEqual($0 as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testPositiveIndexAndWorkspaceArgumentsKeepIdenticalBounds() throws {
        let commands = ["switch-workspace", "focus-column", "focus-window-in-column"]
        for command in commands {
            for value in ["1", "+1", String(Int.max)] {
                XCTAssertNoThrow(try CLIParser.parse(arguments: ["omniwmctl", "command", command, value]))
            }
            for value in ["0", "-1", "1.0", " 1", "1 ", String(Int.max) + "0"] {
                XCTAssertThrowsError(try CLIParser.parse(arguments: [
                    "omniwmctl",
                    "command",
                    command,
                    value
                ])) { error in
                    XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
                }
            }
        }
    }

    func testRuleApplyAcceptsOneExactTarget() throws {
        let cases: [(arguments: [String], target: IPCRuleApplyTarget)] = [
            ([], .focused),
            (["--focused"], .focused),
            (["--window", "window-id"], .window(windowId: "window-id")),
            (["--window", ""], .window(windowId: "")),
            (["--pid", "1"], .pid(1)),
            (["--pid", String(Int32.max)], .pid(Int32.max))
        ]
        for testCase in cases {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply"] + testCase.arguments)
            guard case let .rule(request) = parsed.request.payload else {
                return XCTFail("Expected a rule request")
            }
            XCTAssertEqual(request, .apply(target: testCase.target))
        }
    }

    func testRuleApplyRejectsDuplicateMissingAndUnexpectedTargetArguments() {
        let cases = [
            ["--focused", "--focused"], ["--focused", "extra"],
            ["--window"], ["--window", "--focused"], ["--window", "window-id", "--focused"],
            ["--pid"], ["--pid", "--focused"], ["--pid", "1", "extra"],
            ["--pid", "0"], ["--pid", "-1"], ["--pid", String(Int32.max) + "0"],
            ["window-id"], ["--unknown"]
        ]
        for arguments in cases {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "rule", "apply"] + arguments)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testRuleAddAndReplaceCarryScratchpadSlot() throws {
        let id = "B9B137A2-9406-4D68-BD0E-8ED465450413"
        let expected = IPCRuleDefinition(bundleId: "com.example.App", scratchpad: 2)
        let add = try CLIParser.parse(
            arguments: ["omniwmctl", "rule", "add", "--bundle-id", "com.example.App", "--scratchpad", "2"]
        )
        let replace = try CLIParser.parse(
            arguments: ["omniwmctl", "rule", "replace", id, "--bundle-id", "com.example.App", "--scratchpad", "2"]
        )

        guard case let .rule(addRequest) = add.request.payload,
              case let .rule(replaceRequest) = replace.request.payload
        else {
            return XCTFail("Expected rule requests")
        }
        XCTAssertEqual(addRequest, .add(rule: expected))
        XCTAssertEqual(replaceRequest, .replace(id: id, rule: expected))
    }

    func testRuleAddAndReplaceRejectInvalidOrConflictingScratchpad() {
        let slots = IPCScratchpadSlots.range
        let cases = [
            ["--scratchpad", String(slots.lowerBound - 1)],
            ["--scratchpad", String(slots.upperBound + 1)],
            ["--scratchpad", "abc"],
            ["--scratchpad", "2", "--assign-to-workspace", "3"],
            ["--scratchpad", "2", "--layout", "tile"]
        ]
        let prefixes = [
            ["rule", "add"],
            ["rule", "replace", "B9B137A2-9406-4D68-BD0E-8ED465450413"]
        ]
        for prefix in prefixes {
            for arguments in cases {
                let invocation = ["omniwmctl"] + prefix + ["--bundle-id", "com.example.App"] + arguments
                XCTAssertThrowsError(
                    try CLIParser.parse(arguments: invocation),
                    arguments.joined(separator: " ")
                ) { error in
                    XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
                }
            }
        }
    }
}
