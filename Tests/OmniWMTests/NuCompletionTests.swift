// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class NuCompletionTests: XCTestCase {
    func testGenerationIsDeterministicAndRendersEveryPlaceholder() {
        let script = CLICompletionGenerator.script(for: .nu)
        XCTAssertFalse(script.contains("#{{"))
        XCTAssertTrue(script.contains("    windowMarkActionNames: ["))
        XCTAssertTrue(script.contains("    windowMarkListFlags: ["))
        XCTAssertTrue(script.contains("    windowGatherReachFlag: \"--from\""))
        XCTAssertEqual(script, CLICompletionGenerator.script(for: .nu))
    }

    func testMissingNushellIsAnExplicitSkip() {
        XCTAssertThrowsError(try NuCompletionTestSupport.nuExecutable(path: "")) { error in
            XCTAssertTrue(error is XCTSkip)
        }
    }

    func testNativeErrorsAreFailures() throws {
        for body in ["def broken [", "exit 7"] {
            do {
                _ = try NuCompletionTestSupport.run(body)
                XCTFail("Expected Nushell to fail: \(body)")
            } catch let skip as XCTSkip {
                throw skip
            } catch {
                XCTAssertFalse(error is XCTSkip)
            }
        }
    }

    func testModuleImportsOnlyTheExternalCommand() throws {
        let output = try NuCompletionTestSupport.run(
            "scope commands | where name =~ 'omniwmctl' | get name | to json"
        )
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: output), ["omniwmctl"])
    }

    func testGeneratedStringLiteralsPreserveSpecialCharacters() throws {
        let value = "A \"quote\", a \\ path,\n\t\r\u{0001} and $'literal' 🙂"
        let output = try NuCompletionTestSupport.run("\(CLICompletionGenerator.nushellString(value)) | encode base64")
        XCTAssertEqual(
            String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            Data(value.utf8).base64EncodedString()
        )
    }

    func testTopLevelAndActionFamiliesUseCatalogChoices() throws {
        let cases: [(String, [String])] = [
            ("omniwmctl ", CLICompletionCatalog.topLevelCommands),
            ("omniwmctl query ", CLICompletionCatalog.queryNames),
            ("omniwmctl command ", CLICompletionCatalog.commandFirstWords),
            ("omniwmctl rule ", CLICompletionCatalog.ruleActionNames),
            ("omniwmctl capture ", CLICompletionCatalog.captureActionNames),
            ("omniwmctl workspace ", CLICompletionCatalog.workspaceActionNames),
            ("omniwmctl window ", CLICompletionCatalog.windowActionNames),
            ("omniwmctl completion ", CLIShell.allCases.map(\.rawValue)),
            ("omniwmctl que", ["query"])
        ]
        try assertCompletions(cases)
    }

    func testWindowMarkActionAndListFlagCompletions() throws {
        try assertCompletions([
            ("omniwmctl window mark ", CLICompletionCatalog.windowMarkActionNames),
            ("omniwmctl window mark list ", CLICompletionCatalog.windowMarkListFlags),
            ("omniwmctl window mark set saved ", [])
        ])
    }

    func testWindowGatherReachFlagAndValueCompletions() throws {
        let cases: [(String, [String])] = [
            ("omniwmctl window gather ", ["--from"]),
            ("omniwmctl window gather ow_a ", ["--from"]),
            ("omniwmctl window gather --from ", CLICompletionCatalog.windowGatherReaches),
            ("omniwmctl window gather --from mo", ["monitor"]),
            ("omniwmctl window gather --from all ow_a ", [])
        ]
        try assertCompletions(cases)
    }

    func testNestedCommandsAndLiteralArguments() throws {
        let cases: [(String, [String])] = [
            ("omniwmctl command focus ", ["left", "right", "up", "down", "previous", "down-or-left", "up-or-right"]),
            ("omniwmctl command scratchpad ", ["assign", "toggle"]),
            ("omniwmctl command scratchpad assign ", (1 ... 10).map(String.init)),
            ("omniwmctl command scratchpad toggle ", (1 ... 10).map(String.init)),
            ("omniwmctl command move-to-monitor ", ["left", "right", "up", "down"]),
            ("omniwmctl command resize ", ["horizontal", "vertical"]),
            ("omniwmctl command resize horizontal ", ["grow", "shrink"]),
            ("omniwmctl capture start ", ["trace", "performance"]),
            ("omniwmctl command resize vertical sh", ["shrink"])
        ]
        let layout = try XCTUnwrap(IPCAutomationManifest.commandDescriptors.first {
            $0.arguments.first?.kind == .layout
        })
        try assertCompletions(cases + [(
            "omniwmctl command \(layout.commandWords.joined(separator: " ")) ",
            ["default", "niri", "dwindle"]
        )])
    }

    func testQuerySpecificFlagsAndFields() throws {
        let remaining = IPCAutomationManifest.windowFieldCatalog.filter { $0 != "id" }.map { "id,\($0)" }
        try assertCompletions([
            ("omniwmctl query windows ", CLICompletionCatalog.queryFlagsByName["windows"] ?? []),
            ("omniwmctl query displays --fields ", IPCAutomationManifest.displayFieldCatalog),
            ("omniwmctl query workspaces --fields display-n", ["display-name"]),
            ("omniwmctl query windows --fields id,ti", ["id,title"]),
            ("omniwmctl query windows --fields id,", remaining)
        ])
    }

    func testRulesAndSubscriptionChoices() throws {
        let channels = IPCSubscriptionChannel.allCases.filter { $0 != .focus }.map { "focus,\($0.rawValue)" }
        try assertCompletions([
            ("omniwmctl rule add ", CLICompletionCatalog.ruleDefinitionFlags),
            ("omniwmctl rule apply ", CLICompletionCatalog.ruleApplyFlags),
            ("omniwmctl subscribe ", CLICompletionCatalog.subscribeTokens),
            ("omniwmctl watch ", CLICompletionCatalog.watchTokens),
            ("omniwmctl subscribe focus,work", ["focus,workspace-bar"]),
            ("omniwmctl watch focus,", channels)
        ])
    }

    func testGlobalAndValueTakingFlagsPreserveArgumentPositions() throws {
        let cases: [(String, [String])] = [
            ("omniwmctl --json command resize horizontal ", ["grow", "shrink"]),
            ("omniwmctl command --format json resize horizontal ", ["grow", "shrink"]),
            ("omniwmctl command resize horizontal --format text ", ["grow", "shrink"]),
            ("omniwmctl query windows --format ", ["json", "ndjson", "table", "tsv", "text"]),
            ("omniwmctl --for", ["--format"]),
            ("omniwmctl query windows --app ", []),
            ("omniwmctl rule add --title-substring ", []),
            ("omniwmctl rule add --layout ", ["auto", "tile", "float"]),
            ("omniwmctl rule add --layout fl", ["float"]),
            ("omniwmctl rule apply --pid ", []),
            ("omniwmctl query windows --app 'Visual Studio Code' --fields ti", ["title"])
        ]
        try assertCompletions(cases)
    }

    func testQuotedWorkspaceTargetsCountAsOneArgument() throws {
        try assertCompletions([
            (
                "omniwmctl workspace move-to-monitor 'Design Space' ",
                ["left", "right", "up", "down", "--force"]
            ),
            (
                "omniwmctl workspace move-to-monitor \"Design Space\" --force --format json ",
                ["left", "right", "up", "down"]
            )
        ])
    }

    func testFreeArgumentsAndWatchChildrenDoNotGetOmniWMCompletions() throws {
        try assertCompletions([
            "omniwmctl window focus ",
            "omniwmctl workspace focus-name ",
            "omniwmctl command focus-column 3 ",
            "omniwmctl watch focus --exec ",
            "omniwmctl watch focus --exec nu --format ",
            "omniwmctl watch focus --exec nu --json "
        ].map { ($0, []) })
    }

    func testImportedCommandPreservesExternalArguments() throws {
        let cases: [(String, [String])] = [
            (
                "omniwmctl workspace rename 'Design Space' '' --format json",
                ["workspace", "rename", "Design Space", "", "--format", "json"]
            ),
            (
                "omniwmctl watch focus --exec nu -c 'print \"a b\"' --format json",
                ["watch", "focus", "--exec", "nu", "-c", "print \"a b\"", "--format", "json"]
            ),
            (
                "omniwmctl command set-window-primary-span '-10%' --json",
                ["command", "set-window-primary-span", "-10%", "--json"]
            )
        ]
        let marker = "@@@"
        let output = try NuCompletionTestSupport.run(
            cases.map(\.0).joined(separator: "; print -n \"\(marker)\"; ")
        )
        let text = String(decoding: output, as: UTF8.self)
        let invocations = text.components(separatedBy: marker)
        guard invocations.count == cases.count else {
            return XCTFail("expected \(cases.count) invocations, got \(invocations.count): \(text)")
        }
        for (invocation, (body, expected)) in zip(invocations, cases) {
            let arguments = invocation
                .split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
            XCTAssertEqual(arguments, expected, body)
        }
    }

    func testCompletionGenerationDoesNotOpenIPC() async {
        let environment = CLIRuntimeEnvironment(
            openConnection: {
                XCTFail("Completion generation must not open IPC")
                throw POSIXError(.ENOTCONN)
            },
            sleep: { _ in
                XCTFail("Completion generation must not wait for a connection")
            }
        )
        let result = await CLIRuntime.run(arguments: ["omniwmctl", "completion", "nu"], environment: environment)
        XCTAssertEqual(result, CLIExitCode.success.rawValue)
    }

    private func assertCompletions(
        _ cases: [(String, [String])],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let results = try NuCompletionTestSupport.completions(cases.map(\.0))
        for (completions, (input, expected)) in zip(results, cases) {
            XCTAssertEqual(Set(completions), Set(expected), input, file: file, line: line)
        }
    }
}
