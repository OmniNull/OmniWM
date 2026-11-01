// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WorkspaceMoveIPCContractTests: XCTestCase {
    func testFocusNameWireShapeIsPreserved() throws {
        let request = IPCWorkspaceRequest.focusName(target: .displayName("S"))
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "focus-name")
        XCTAssertEqual(target, ["kind": "display-name", "value": "S"])
        XCTAssertNil(object["direction"])
        XCTAssertNil(object["force"])
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testMoveWireShapeIncludesDirectionAndDefaultForce() throws {
        let request = IPCWorkspaceRequest.moveToMonitor(target: .displayName("S"), direction: .right)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "move-to-monitor")
        XCTAssertEqual(target, ["kind": "display-name", "value": "S"])
        XCTAssertEqual(object["direction"] as? String, "right")
        XCTAssertEqual(object["force"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testMoveDecodeDefaultsMissingForceToFalse() throws {
        let data = Data(
            """
            {
              "name": "move-to-monitor",
              "workspaceTarget": {"kind": "raw-id", "value": "12"},
              "direction": "left"
            }
            """.utf8
        )

        XCTAssertEqual(
            try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data),
            .moveToMonitor(target: .rawID("12"), direction: .left, force: false)
        )
    }

    func testMoveWireRoundTripPreservesExplicitForce() throws {
        let request = IPCWorkspaceRequest.moveToMonitor(
            target: .rawID("12"),
            direction: .up,
            force: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "move-to-monitor")
        XCTAssertEqual(target, ["kind": "raw-id", "value": "12"])
        XCTAssertEqual(object["direction"] as? String, "up")
        XCTAssertEqual(object["force"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testManifestDescribesWorkspaceMove() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.workspaceActionDescriptors.first { $0.name == .moveToMonitor }
        )

        XCTAssertEqual(descriptor.actionWords, ["move-to-monitor"])
        XCTAssertEqual(
            descriptor.path,
            "workspace move-to-monitor <workspace> <left|right|up|down> [--force]"
        )
        XCTAssertEqual(descriptor.arguments, ["workspace", "left|right|up|down"])
        XCTAssertEqual(descriptor.optionalFlags, ["--force"])
    }

    func testParserBuildsNamedWorkspaceMove() throws {
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "move-to-monitor", "S", "right"]),
            .moveToMonitor(target: .displayName("S"), direction: .right, force: false)
        )
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "move-to-monitor", "12", "left"]),
            .moveToMonitor(target: .rawID("12"), direction: .left, force: false)
        )
    }

    func testParserAcceptsForceAnywhereOnce() throws {
        let invocations = [
            ["workspace", "move-to-monitor", "--force", "S", "right"],
            ["workspace", "move-to-monitor", "S", "--force", "right"],
            ["workspace", "move-to-monitor", "S", "right", "--force"]
        ]

        for invocation in invocations {
            XCTAssertEqual(
                try parseWorkspaceRequest(invocation),
                .moveToMonitor(target: .displayName("S"), direction: .right, force: true)
            )
        }
    }

    func testParserRejectsMalformedWorkspaceMoves() {
        let invocations = [
            ["workspace", "move-to-monitor", "S"],
            ["workspace", "move-to-monitor", "S", "diagonal"],
            ["workspace", "move-to-monitor", "S", "right", "--force", "--force"],
            ["workspace", "move-to-monitor", "S", "right", "--unknown"],
            ["workspace", "move-to-monitor", "S", "right", "extra"]
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeWorkspaceMoveContract() {
        XCTAssertTrue(
            CLIParser.usageText.contains(
                "omniwmctl workspace move-to-monitor <workspace> <left|right|up|down> [--force]"
            )
        )

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            XCTAssertTrue(script.contains("move-to-monitor"))
            XCTAssertTrue(script.contains("--force"))
            XCTAssertTrue(script.contains("left"))
            XCTAssertTrue(script.contains("right"))
            XCTAssertTrue(script.contains("up"))
            XCTAssertTrue(script.contains("down"))
        }
    }

    func testRenameWireShapeIsPreserved() throws {
        let request = IPCWorkspaceRequest.rename(target: .rawID("3"), displayName: "🚨 Alerts")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(object["workspaceTarget"] as? [String: String])

        XCTAssertEqual(object["name"] as? String, "rename")
        XCTAssertEqual(target, ["kind": "raw-id", "value": "3"])
        XCTAssertEqual(object["displayName"] as? String, "🚨 Alerts")
        XCTAssertNil(object["direction"])
        XCTAssertNil(object["force"])
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testRenameWireRoundTripPreservesEmptyDisplayName() throws {
        let request = IPCWorkspaceRequest.rename(target: .displayName("Slack"), displayName: "")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["displayName"] as? String, "")
        XCTAssertEqual(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data), request)
    }

    func testRenameDecodeRequiresDisplayName() {
        let data = Data(
            """
            {
              "name": "rename",
              "workspaceTarget": {"kind": "raw-id", "value": "3"}
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(IPCWorkspaceRequest.self, from: data))
    }

    func testManifestDescribesWorkspaceRename() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.workspaceActionDescriptors.first { $0.name == .rename }
        )

        XCTAssertEqual(descriptor.actionWords, ["rename"])
        XCTAssertEqual(descriptor.path, "workspace rename <workspace> <display-name>")
        XCTAssertEqual(descriptor.arguments, ["workspace", "display-name"])
        XCTAssertTrue(descriptor.optionalFlags.isEmpty)
    }

    func testParserBuildsWorkspaceRename() throws {
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "rename", "3", "Mail"]),
            .rename(target: .rawID("3"), displayName: "Mail")
        )
        XCTAssertEqual(
            try parseWorkspaceRequest(["workspace", "rename", "Slack", ""]),
            .rename(target: .displayName("Slack"), displayName: "")
        )
    }

    func testParserRejectsMalformedWorkspaceRenames() {
        let invocations = [
            ["workspace", "rename", "3"],
            ["workspace", "rename", "3", "Mail", "extra"],
            ["workspace", "rename", "3", "--clear"],
            ["workspace", "rename", "--force", "3", "Mail"]
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeWorkspaceRenameContract() {
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl workspace rename <workspace> <display-name>"))

        for shell in CLIShell.allCases {
            XCTAssertTrue(CLICompletionGenerator.script(for: shell).contains("rename"))
        }
    }

    func testWorkspaceMoveCompletionsTrackNonFlagPositionals() throws {
        for shell in [CLIShell.zsh, .bash] {
            try assertWorkspaceMoveCompletions(shell: shell)
        }
    }

    func testNuWorkspaceMoveCompletionsTrackNonFlagPositionals() throws {
        try assertWorkspaceMoveCompletions(shell: .nu)
    }

    func testFishWorkspaceMoveCompletionsTrackNonFlagPositionals() throws {
        guard fishExecutablePath() != nil else {
            throw XCTSkip("Fish is not installed")
        }

        try assertWorkspaceMoveCompletions(shell: .fish)
    }

    func testBashAndZshScratchpadCompletionsSeparateActionsFromSlots() throws {
        let slots = Set((1 ... 10).map(String.init))
        for shell in [CLIShell.zsh, .bash] {
            let results = try shellCompletions(
                shell: shell,
                arguments: ["command scratchpad", "command scratchpad assign", "command scratchpad toggle"]
            )
            XCTAssertEqual(Set(results[0]), ["assign", "toggle"], shell.rawValue)
            XCTAssertEqual(Set(results[1]), slots, "\(shell.rawValue): assign")
            XCTAssertEqual(Set(results[2]), slots, "\(shell.rawValue): toggle")
        }
    }

    func testFishScratchpadCompletionsSeparateActionsFromSlots() throws {
        guard fishExecutablePath() != nil else {
            throw XCTSkip("Fish is not installed")
        }

        let slots = Set((1 ... 10).map(String.init))
        let results = try shellCompletions(
            shell: .fish,
            arguments: ["command scratchpad", "command scratchpad assign", "command scratchpad toggle"]
        )
        let root = Set(results[0])
        XCTAssertTrue(Set(["assign", "toggle"]).isSubset(of: root))
        XCTAssertTrue(root.isDisjoint(with: slots))
        XCTAssertTrue(slots.isSubset(of: Set(results[1])), "assign")
        XCTAssertTrue(slots.isSubset(of: Set(results[2])), "toggle")
    }

    func testNoChangeRendering() throws {
        let response = IPCResponse.failure(id: "switch", kind: .command, status: .ignored, code: .noChange)
        let output = try CLIRenderer.responseOutput(response, format: .text)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, .ignored)
        XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "ignored: no_change\n")
    }

    func testWorkspaceConflictRendering() throws {
        let cases: [(IPCErrorCode, String)] = [
            (.workspaceAssignmentConflict, "error: workspace_assignment_conflict\n"),
            (.workspaceStateConflict, "error: workspace_state_conflict\n")
        ]
        for (code, expected) in cases {
            let response = IPCResponse.failure(
                id: "move",
                kind: .workspace,
                code: code
            )
            let output = try CLIRenderer.responseOutput(response, format: .text)

            XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
            XCTAssertEqual(output.destination, .standardOutput)
            XCTAssertEqual(String(decoding: output.data, as: UTF8.self), expected)
        }
    }

    private func parseWorkspaceRequest(_ arguments: [String]) throws -> IPCWorkspaceRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
        guard case let .workspace(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }

    private func assertWorkspaceMoveCompletions(shell: CLIShell) throws {
        let cases = workspaceMoveCompletionCases
        let results = try shellCompletions(
            shell: shell,
            arguments: cases.map { "workspace move-to-monitor \($0.arguments)" }
        )
        for (completions, completionCase) in zip(results, cases) {
            XCTAssertEqual(Set(completions), completionCase.expected, "\(shell.rawValue): \(completionCase.arguments)")
        }
    }

    private func shellCompletions(shell: CLIShell, arguments: [String]) throws -> [[String]] {
        if shell == .nu {
            return try NuCompletionTestSupport.completions(arguments.map { "omniwmctl \($0) " })
        }
        let script = try completionScript(shell: shell, arguments: arguments)
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: script.executable)
        process.arguments = ["-c", script.script]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure.shellFailure(process.terminationStatus, String(decoding: error, as: UTF8.self))
        }

        var results: [[String]] = []
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            if line == Self.caseMarker {
                results.append([])
            } else if !results.isEmpty, let first = line.split(separator: "\t", maxSplits: 1).first {
                results[results.count - 1].append(String(first))
            }
        }
        guard results.count == arguments.count else {
            throw TestFailure.shellFailure(
                process.terminationStatus,
                "\(shell.rawValue): expected \(arguments.count) results, got \(results.count); stderr: "
                    + String(decoding: error, as: UTF8.self)
            )
        }
        return results
    }

    private static let caseMarker = "@@@"

    private func completionScript(shell: CLIShell, arguments: [String]) throws -> (executable: String, script: String) {
        let marker = Self.caseMarker
        let generatedScript = CLICompletionGenerator.script(for: shell)
        let cases = arguments.map { (words: "omniwmctl \($0) ''", count: $0.split(separator: " ").count) }

        switch shell {
        case .zsh:
            let invocations = cases.map {
                "words=(\($0.words))\nCURRENT=\($0.count + 2)\nprint -r -- \(marker)\n_omniwmctl"
            }
            return ("/bin/zsh", """
            function compadd {
              if [[ "$1" == "--" ]]; then
                shift
              fi
              print -rl -- "$@"
            }
            function compdef { :; }
            \(generatedScript)
            \(invocations.joined(separator: "\n"))
            true
            """)
        case .bash:
            let invocations = cases.map {
                """
                COMP_WORDS=(\($0.words))
                COMP_CWORD=\($0.count + 1)
                COMPREPLY=()
                echo \(marker)
                _omniwmctl
                printf '%s\\n' "${COMPREPLY[@]}"
                """
            }
            return ("/bin/bash", "\(generatedScript)\n\(invocations.joined(separator: "\n"))")
        case .fish:
            guard let fishExecutable = fishExecutablePath() else {
                throw XCTSkip("Fish is not installed")
            }
            let invocations = arguments.map { "echo \(marker)\ncomplete -C \"omniwmctl \($0) \"" }
            return (fishExecutable, "\(generatedScript)\n\(invocations.joined(separator: "\n"))")
        case .nu:
            preconditionFailure("nu completions run through NuCompletionTestSupport")
        }
    }

    private var workspaceMoveCompletionCases: [(arguments: String, expected: Set<String>)] {
        [
            ("", ["--force"]),
            ("S", ["left", "right", "up", "down", "--force"]),
            ("--format json", ["--force"]),
            ("--format json S", ["left", "right", "up", "down", "--force"]),
            ("S --format table", ["left", "right", "up", "down", "--force"]),
            ("S --format tsv right", ["--force"]),
            ("S right --format text", ["--force"]),
            ("--json S", ["left", "right", "up", "down", "--force"]),
            ("S --json", ["left", "right", "up", "down", "--force"]),
            ("S --json right", ["--force"]),
            ("S right --json", ["--force"]),
            ("--force S", ["left", "right", "up", "down"]),
            ("S --force", ["left", "right", "up", "down"]),
            ("S right --force", []),
            ("--force --format json S", ["left", "right", "up", "down"]),
            ("S --format json --force", ["left", "right", "up", "down"]),
            ("S right", ["--force"]),
            ("S --format json right --force", [])
        ]
    }

    private func fishExecutablePath() -> String? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) } ?? []
        return paths
            .map { URL(fileURLWithPath: $0).appendingPathComponent("fish").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private enum TestFailure: Error {
        case unexpectedPayload
        case shellFailure(Int32, String)
    }
}
