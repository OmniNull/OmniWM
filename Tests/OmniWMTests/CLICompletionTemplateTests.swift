// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import XCTest

final class CLICompletionTemplateTests: XCTestCase {
    func testRegistrationsHaveValidShellSyntax() throws {
        for (shell, executable) in [
            (CLIShell.bash, "/bin/bash"), (.zsh, "/bin/zsh"), (.fish, try CLICompletionTestSupport.fishExecutable())
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("registration")
            try CLICompletionGenerator.script(for: shell).write(to: file, atomically: true, encoding: .utf8)
            _ = try CLICompletionTestSupport.run(executable, arguments: ["-n", file.path])
        }
    }

    func testShellCompletionProtocolsReachNativeSelection() throws {
        let cases: [(words: [String], expected: [String])] = [
            (["window", "mark", ""], CLICompletionCatalog.windowMarkActionNames),
            (["window", "mark", "list", ""], CLICompletionCatalog.windowMarkListFlags),
            (["window", "gather", ""], [CLICompletionCatalog.windowGatherReachFlag]),
            (["window", "gather", "--from", "mo"], ["monitor"]),
            (["window", "gather", "--from", "all", "ow_a", ""], []),
            (["query", "windows", "--fields", "id,ti"], ["id,title"]),
            (["command", "resize", "horizontal", "--format", "text", ""], ["grow", "shrink"]),
            (
                ["workspace", "move-to-monitor", "Design Space", "--force", "--format", "json", ""],
                CLICompletionCatalog.workspaceMoveDirections
            ),
            (["watch", "focus", "--exec", "nu", "--format", ""], [])
        ]
        for shell in [CLIShell.zsh, .bash, .fish] {
            for fixture in cases {
                let words = ["omniwmctl"] + fixture.words
                let output = try CLICompletionTestSupport.complete(shell: shell, words: words)
                XCTAssertEqual(Set(output), Set(fixture.expected), "\(shell): \(words)")
            }
        }
    }

    func testBashCursorAndQuotedTokensReachTheSameNativeSlots() throws {
        let prefix = "omniwmctl workspace move-to-monitor 'Design Space' "
        let line = prefix + "right --force"
        let words = try CLICompletionInput.words(
            arguments: ["bash"],
            environment: ["COMP_LINE": line, "COMP_POINT": String(prefix.utf8.count)]
        )
        XCTAssertEqual(words, ["omniwmctl", "workspace", "move-to-monitor", "Design Space", ""])
        XCTAssertEqual(
            Set(CLICompletionSelector.suggestions(words: words)),
            Set(CLICompletionCatalog.workspaceMoveDirections + CLICompletionCatalog.workspaceMoveOptionalFlags)
        )
        XCTAssertEqual(
            CLICompletionInput.bashWords("echo ignored; omniwmctl command resize horizontal "),
            ["omniwmctl", "command", "resize", "horizontal", ""]
        )
        XCTAssertEqual(
            CLICompletionInput.bashWords(#"omniwmctl workspace rename "a\b" '' "#),
            ["omniwmctl", "workspace", "rename", #"a\b"#, "", ""]
        )
    }

    func testInvalidShellInputIsRejectedWithoutWaiting() {
        for arguments in [[], ["unknown"], ["zsh", "-1"], ["zsh", "2"], ["bash"]] {
            XCTAssertThrowsError(try CLICompletionInput.words(arguments: arguments, environment: [:]))
        }
    }

    func testHiddenCompletionDoesNotOpenIPCOrNormalizeItsPayloadFlags() async {
        let environment = CLIRuntimeEnvironment(
            openConnection: {
                XCTFail("Completion selection must not open IPC")
                throw POSIXError(.ENOTCONN)
            },
            sleep: { _ in XCTFail("Completion selection must not wait for IPC") }
        )
        let words = ["omniwmctl", "query", "windows", "--fields", "id,ti"]
        let result = await CLIRuntime.run(
            arguments: ["omniwmctl", "__complete", "zsh", String(words.count)] + words,
            environment: environment
        )
        XCTAssertEqual(result, CLIExitCode.success.rawValue)
    }
}
