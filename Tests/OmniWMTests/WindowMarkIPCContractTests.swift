// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WindowMarkIPCContractTests: XCTestCase {
    private enum TestFailure: Error {
        case unexpectedPayload
    }

    func testTypedWindowMarkRequestsRoundTripThroughTheIPCEnvelope() throws {
        let requests: [IPCWindowMarkRequest] = [
            .set(name: "Alpha"),
            .list,
            .focus(name: "work"),
            .summon(name: "right"),
            .remove(name: "old")
        ]

        for (index, request) in requests.enumerated() {
            let envelope = IPCRequest(id: "mark-\(index)", windowMark: request)
            let data = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
            XCTAssertEqual(decoded, envelope)
            XCTAssertEqual(decoded.kind, .windowMark)
        }

        XCTAssertEqual(IPCRequestKind.windowMark.rawValue, "window-mark")
        XCTAssertEqual(IPCResponseKind(requestKind: .windowMark), .windowMark)
    }

    func testWindowMarkRequestWireShapeRequiresNamesExceptForList() throws {
        let setData = try JSONEncoder().encode(IPCWindowMarkRequest.set(name: "alpha"))
        let setObject = try XCTUnwrap(JSONSerialization.jsonObject(with: setData) as? [String: String])
        XCTAssertEqual(setObject, ["name": "set", "mark": "alpha"])

        let listData = try JSONEncoder().encode(IPCWindowMarkRequest.list)
        let listObject = try XCTUnwrap(JSONSerialization.jsonObject(with: listData) as? [String: String])
        XCTAssertEqual(listObject, ["name": "list"])

        let summonData = try JSONEncoder().encode(IPCWindowMarkRequest.summon(name: "right"))
        let summonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: summonData) as? [String: String])
        XCTAssertEqual(summonObject, ["name": "summon", "mark": "right"])
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCWindowMarkRequest.self, from: Data(#"{"name":"set"}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCWindowMarkRequest.self, from: Data(#"{"name":"list","mark":"x"}"#.utf8))
        )
    }

    func testParserBuildsMarkActionsAndListJsonFormat() throws {
        let cases: [(arguments: [String], request: IPCWindowMarkRequest)] = [
            (["window", "mark", "set", "  Alpha  "], .set(name: "  Alpha  ")),
            (["window", "mark", "list"], .list),
            (["window", "mark", "focus", "Alpha"], .focus(name: "Alpha")),
            (["window", "mark", "summon", "Alpha"], .summon(name: "Alpha")),
            (["window", "mark", "remove", "Alpha"], .remove(name: "Alpha")),
            (["window", "mark", "set", ""], .set(name: ""))
        ]

        for testCase in cases {
            XCTAssertEqual(try parseWindowMark(testCase.arguments), testCase.request)
        }

        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "window", "mark", "list", "--json"])
        XCTAssertEqual(parsed.outputFormat, .json)
        guard case .windowMark(.list) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
    }

    func testParserRejectsMalformedMarkActions() {
        let invocations = [
            ["window", "mark"],
            ["window", "mark", "set"],
            ["window", "mark", "list", "extra"],
            ["window", "mark", "unknown", "name"],
            ["window", "mark", "summon"],
            ["window", "mark", "remove", "name", "extra"]
        ]

        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testManifestHelpAndAllShellCompletionsExposeMarkActions() {
        XCTAssertEqual(
            IPCAutomationManifest.windowMarkActionDescriptors.map(\.path),
            [
                "window mark set <name>",
                "window mark list [--json]",
                "window mark focus <name>",
                "window mark summon <name>",
                "window mark remove <name>"
            ]
        )
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl window mark list [--json]"))

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            for token in ["mark", "set", "list", "focus", "summon", "remove", "--json"] {
                XCTAssertTrue(script.contains(token), "\(shell.rawValue) completion missing \(token)")
            }
        }
    }

    func testListResultRoundTripsAndRendersWindowContext() throws {
        let workspace = IPCWorkspaceRef(id: "workspace-1", rawName: "1", displayName: "Code", number: 1)
        let app = IPCAppRef(name: "Editor", bundleId: "com.example.editor")
        let marks = IPCWindowMarksResult(
            marks: [IPCWindowMarkEntry(name: "editor", workspace: workspace, app: app, title: "Project.swift")]
        )
        let response = IPCResponse.success(
            id: "list",
            kind: .windowMark,
            result: IPCResult(windowMarks: marks)
        )
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: JSONEncoder().encode(response))

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.result?.kind, .windowMarks)
        let output = try CLIRenderer.responseOutput(decoded, format: .table)
        let text = String(decoding: output.data, as: UTF8.self)
        XCTAssertTrue(text.contains("editor"))
        XCTAssertTrue(text.contains("Code"))
        XCTAssertTrue(text.contains("Editor"))
        XCTAssertTrue(text.contains("Project.swift"))
    }

    func testTypedMarkRefusalCodesAreStableOnTheWire() {
        XCTAssertEqual(IPCErrorCode.staleMark.rawValue, "stale_mark")
        XCTAssertEqual(IPCErrorCode.unknownMark.rawValue, "unknown_mark")
        XCTAssertEqual(IPCErrorCode.noFocusedWindow.rawValue, "no_focused_window")
        XCTAssertEqual(IPCErrorCode.selfSummon.rawValue, "self_summon")
        XCTAssertEqual(IPCErrorCode.hiddenWindow.rawValue, "hidden_window")
        XCTAssertEqual(IPCErrorCode.unsupportedLayout.rawValue, "unsupported_layout")
        XCTAssertEqual(IPCErrorCode.duplicateMark.rawValue, "duplicate_mark")
        XCTAssertEqual(IPCErrorCode.invalidMark.rawValue, "invalid_mark")
        XCTAssertEqual(IPCResultKind.windowMarks.rawValue, "window-marks")
    }

    private func parseWindowMark(_ arguments: [String]) throws -> IPCWindowMarkRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
        guard case let .windowMark(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }
}
