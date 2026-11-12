// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLICompletionSelectorTests: XCTestCase {
    func testValueTakingFlagsAndQuotedArgumentsKeepTheCommandPosition() {
        assertSuggestions([
            (["omniwmctl", "--json", "command", "resize", "horizontal", ""], ["grow", "shrink"]),
            (["omniwmctl", "command", "--format", "json", "resize", "horizontal", "sh"], ["shrink"]),
            (["omniwmctl", "query", "windows", "--app", "Visual Studio Code", "--fields", "ti"], ["title"]),
            (["omniwmctl", "rule", "add", "--title-substring", ""], []),
            (["omniwmctl", "rule", "add", "--layout", "fl"], ["float"])
        ])
    }

    func testWorkspaceMovementCountsOnlyPositionalsAndExcludesUsedFlags() {
        let movement = ["omniwmctl", "workspace", CLICompletionCatalog.workspaceMoveActionName, "Design Space"]
        let directions = CLICompletionCatalog.workspaceMoveDirections
        let flags = CLICompletionCatalog.workspaceMoveOptionalFlags
        assertSuggestions([
            (movement + [""], directions + flags),
            (movement + flags + ["--format", "json", ""], directions),
            (movement + ["left", ""], flags),
            (movement + ["left", "extra", ""], [])
        ])
    }

    func testFieldsAndChannelListsPreservePrefixesWithoutRepeatingSelections() {
        let query = ["omniwmctl", "query", "windows", "--fields"]
        let remainingFields = IPCAutomationManifest.windowFieldCatalog.filter { $0 != "id" }.map { "id," + $0 }
        let channels = IPCSubscriptionChannel.allCases.filter { $0 != .focus }.map { "focus," + $0.rawValue }
        assertSuggestions([
            (query + ["id,ti"], ["id,title"]),
            (query + ["id,"], remainingFields),
            (["omniwmctl", "subscribe", "focus,work"], ["focus,workspace-bar"]),
            (["omniwmctl", "watch", "focus,"], channels)
        ])
    }

    func testGatherMarksAndNestedLiteralSlotsRemainSeparate() {
        let gather = ["omniwmctl", "window", "gather"]
        assertSuggestions([
            (gather + ["ow_a", ""], [CLICompletionCatalog.windowGatherReachFlag]),
            (gather + [CLICompletionCatalog.windowGatherReachFlag, ""], CLICompletionCatalog.windowGatherReaches),
            (gather + [CLICompletionCatalog.windowGatherReachFlag, "all", "ow_a", ""], []),
            (["omniwmctl", "window", "mark", "list", ""], CLICompletionCatalog.windowMarkListFlags),
            (["omniwmctl", "window", "mark", "set", "saved", ""], []),
            (["omniwmctl", "command", "scratchpad", "assign", ""], IPCScratchpadSlots.range.map(String.init)),
            (["omniwmctl", "command", "resize", "vertical", ""], ["grow", "shrink"])
        ])
    }

    func testGlobalFlagsAndTheirValuesComeFromTheCatalog() {
        let formats = CLICompletionCatalog.flagValuesByName["--format"] ?? []
        let sortValues = CLICompletionCatalog.flagValuesByName["--sort"] ?? []
        assertSuggestions([
            (["omniwmctl", "--for"], ["--format"]),
            (["omniwmctl", "query", "windows", "--format", ""], formats),
            (["omniwmctl", "query", "windows", "--sort", ""], sortValues),
            (["omniwmctl", "--json", "query", "windows", "--j"], []),
            (["omniwmctl", "completion", "n"], ["nu"])
        ])
    }

    func testWatchChildrenAndFreeArgumentsReceiveNoCandidates() {
        for words in [
            ["omniwmctl", "watch", "focus", "--exec", ""],
            ["omniwmctl", "watch", "focus", "--exec", "nu", "--format", ""],
            ["omniwmctl", "window", "focus", ""],
            ["omniwmctl", "workspace", "focus-name", ""],
            ["omniwmctl", "command", "focus-column", "3", ""]
        ] {
            XCTAssertEqual(CLICompletionSelector.suggestions(words: words), [], words.joined(separator: " "))
        }
    }

    func testFishAppliesItsOwnCaseInsensitiveAndSubstringMatching() throws {
        for prefix in ["uery", "QUE", "que"] {
            XCTAssertEqual(
                try CLICompletionTestSupport.complete(shell: .fish, words: ["omniwmctl", prefix]),
                ["query"], prefix
            )
        }
    }

    func testUnfilteredSelectionPreservesCommaListsAndUsedFlags() {
        XCTAssertEqual(
            CLICompletionSelector.suggestions(
                words: ["omniwmctl", "query", "windows", "--fields", "id,ti"], filterPrefix: false
            ),
            ["id,title"]
        )
        XCTAssertEqual(
            CLICompletionSelector.suggestions(
                words: ["omniwmctl", "subscribe", "focus,work"], filterPrefix: false
            ),
            ["focus,workspace-bar"]
        )
        let flags = CLICompletionSelector.suggestions(
            words: ["omniwmctl", "--json", "query", "windows", "--j"], filterPrefix: false
        )
        XCTAssertFalse(flags.contains("--json"))
        XCTAssertTrue(flags.contains("--format"))
        XCTAssertEqual(
            CLICompletionSelector.suggestions(
                words: ["omniwmctl", "watch", "focus", "--exec", "QUE"], filterPrefix: false
            ),
            []
        )
    }

    private func assertSuggestions(
        _ cases: [([String], [String])],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (words, expected) in cases {
            XCTAssertEqual(
                CLICompletionSelector.suggestions(words: words), expected.sorted(),
                words.joined(separator: " "), file: file, line: line
            )
        }
    }
}
