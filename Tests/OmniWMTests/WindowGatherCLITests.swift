// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WindowGatherCLITests: XCTestCase {
    private enum TestFailure: Error {
        case unexpectedPayload
    }

    private let workspace = IPCWorkspaceRef(id: "workspace-3", rawName: "3", displayName: "Code", number: 3)

    func testParserDefaultsToWorkspaceReachAndKeepsIdOrder() throws {
        let cases: [(arguments: [String], request: IPCWindowGatherRequest)] = [
            (["ow_b", "ow_a"], .init(windowIds: ["ow_b", "ow_a"], from: .workspace)),
            (["--from", "monitor", "ow_a"], .init(windowIds: ["ow_a"], from: .monitor)),
            (["ow_a", "--from", "all", "ow_b"], .init(windowIds: ["ow_a", "ow_b"], from: .all)),
            (["ow_a", "--from", "workspace"], .init(windowIds: ["ow_a"], from: .workspace))
        ]
        for testCase in cases {
            XCTAssertEqual(try parseGather(testCase.arguments), testCase.request, "\(testCase.arguments)")
        }

        let text = try CLIParser.parse(arguments: ["omniwmctl", "window", "gather", "ow_a"])
        XCTAssertEqual(text.outputFormat, .text)
        XCTAssertEqual(text.request.kind, .windowGather)
        let json = try CLIParser.parse(arguments: ["omniwmctl", "window", "gather", "--json", "ow_a", "--from", "all"])
        XCTAssertEqual(json.outputFormat, .json)
        guard case let .windowGather(request) = json.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        XCTAssertEqual(request, .init(windowIds: ["ow_a"], from: .all))
    }

    func testParserRejectsMissingRepeatedAndUnknownOptions() {
        let invocations = [
            [],
            ["--from", "all"],
            ["ow_a", "--from"],
            ["--from", "ow_a"],
            ["--from", "everywhere", "ow_a"],
            ["--from", "all", "--from", "monitor", "ow_a"],
            ["--from", "all", "--from", "all", "ow_a"],
            ["--workspace", "3", "ow_a"],
            ["--mark", "editor"]
        ]
        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl", "window", "gather"] + invocation)) {
                XCTAssertEqual($0 as? CLIParseError, .usage(CLIParser.usageText), "\(invocation)")
            }
        }
    }

    func testHelpAndDiscoveryTablesShowTheGatherDescriptor() throws {
        let path = "window gather [--from workspace|monitor|all] <window-id>..."
        XCTAssertEqual(IPCAutomationManifest.windowGatherActionDescriptors.map(\.path), [path])
        XCTAssertTrue(CLIParser.usageText.contains("  omniwmctl \(path)"))

        let commands = IPCCommandsQueryResult(
            commands: [],
            workspaceActions: [],
            windowActions: [],
            windowMarkActions: [],
            windowGatherActions: IPCAutomationManifest.windowGatherActionDescriptors,
            dwindleActions: [],
            shellActions: []
        )
        let commandsText = try render(.success(id: "commands", kind: .query, result: IPCResult(commands: commands)))
        XCTAssertTrue(commandsText.contains(path), commandsText)
        XCTAssertTrue(commandsText.contains("window-gather"), commandsText)

        let capabilities = IPCCapabilitiesQueryResult(
            appVersion: "test",
            authorizationRequired: true,
            windowIdScope: "session",
            queries: [],
            commands: [],
            captureActions: [],
            ruleActions: [],
            workspaceActions: [],
            windowActions: [],
            windowMarkActions: [],
            windowGatherActions: IPCAutomationManifest.windowGatherActionDescriptors,
            dwindleActions: [],
            shellActions: [],
            subscriptions: []
        )
        let capabilitiesText = try render(
            .success(id: "capabilities", kind: .query, result: IPCResult(capabilities: capabilities)),
            format: .tsv
        )
        XCTAssertTrue(capabilitiesText.contains("window-gather-actions\t1"), capabilitiesText)
    }

    func testOutcomesRenderPerWindowStatusesAndUseTheResponseExitStatus() throws {
        let gathered = IPCResponse.success(id: "gather", kind: .windowGather, status: .executed, result: result(
            .gathered,
            windows: [.init(windowId: "ow_a", status: .unchanged), .init(windowId: "ow_b", status: .moved)]
        ))
        let unchanged = IPCResponse.failure(
            id: "gather",
            kind: .windowGather,
            status: .ignored,
            code: .noChange,
            result: result(.unchanged, windows: [.init(windowId: "ow_a", status: .unchanged)])
        )
        let refused = IPCResponse.failure(id: "gather", kind: .windowGather, code: .invalidArguments, result: result(
            .refused,
            reason: .windowRefused,
            windows: [
                .init(windowId: "ow_a", status: .blocked),
                .init(windowId: "garbage", status: .unresolved, reason: .invalidWindowId)
            ]
        ))

        let gatheredText = try render(gathered)
        XCTAssertTrue(gatheredText.hasPrefix("gathered on Code\nID"), gatheredText)
        XCTAssertTrue(gatheredText.contains("ow_b  moved"), gatheredText)
        XCTAssertTrue(try render(unchanged).hasPrefix("ignored: no_change\nunchanged on Code\nID"))
        let refusedText = try render(refused, format: .table)
        let refusedHeader = "error: invalid_arguments\nrefused on Code: window_refused\nID"
        XCTAssertTrue(refusedText.hasPrefix(refusedHeader), refusedText)
        XCTAssertTrue(refusedText.contains("garbage  unresolved  invalid_window_id"), refusedText)
        XCTAssertTrue(refusedText.contains("ow_a     blocked     -"), refusedText)
        XCTAssertEqual(
            try render(refused, format: .tsv),
            "error: invalid_arguments\nID\tSTATUS\tREASON\now_a\tblocked\t-\ngarbage\tunresolved\tinvalid_window_id\n"
        )

        for response in [gathered, unchanged, refused] {
            let output = try CLIRenderer.responseOutput(response, format: .json)
            XCTAssertEqual(output.data, try IPCWire.encodeResponseLine(response, prettyPrinted: true))
            XCTAssertEqual(try IPCWire.decodeResponse(from: output.data), response)
        }
        XCTAssertEqual(CLIRenderer.exitCode(for: gathered), .success)
        XCTAssertEqual(CLIRenderer.exitCode(for: unchanged), .rejected)
        XCTAssertEqual(CLIRenderer.exitCode(for: refused), .rejected)
        for code in [IPCErrorCode.ineligibleWindow, .doesNotFit] {
            let response = IPCResponse.failure(id: "gather", kind: .windowGather, code: code)
            XCTAssertEqual(CLIRenderer.exitCode(for: response), .rejected)
        }
    }

    private func result(
        _ outcome: IPCWindowGatherOutcome,
        reason: IPCWindowGatherReason? = nil,
        windows: [IPCWindowGatherWindowResult]
    ) -> IPCResult {
        IPCResult(windowGather: IPCWindowGatherResult(
            outcome: outcome,
            workspace: workspace,
            reason: reason,
            windows: windows
        ))
    }

    private func render(_ response: IPCResponse, format: CLIOutputFormat = .text) throws -> String {
        String(decoding: try CLIRenderer.responseOutput(response, format: format).data, as: UTF8.self)
    }

    private func parseGather(_ arguments: [String]) throws -> IPCWindowGatherRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "window", "gather"] + arguments)
        guard case let .windowGather(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }
}
