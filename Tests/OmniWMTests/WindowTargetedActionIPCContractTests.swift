// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WindowTargetedActionIPCContractTests: XCTestCase {
    private enum TestFailure: Error {
        case unexpectedPayload
    }

    private func parseCases() throws -> [([String], IPCWindowRequest)] {
        let half = try CLIArgumentParser.parseSizeChange("50%")
        let delta = try CLIArgumentParser.parseSizeChange("+10")
        return [
            (["move-column-to-first"], .init(name: .moveColumnToFirst, windowId: "ow_x")),
            (["move-column-to-last"], .init(name: .moveColumnToLast, windowId: "ow_x")),
            (["move-column-to-index", "3"], .init(name: .moveColumnToIndex, windowId: "ow_x", columnIndex: 3)),
            (["move-column", "left"], .init(name: .moveColumn, windowId: "ow_x", direction: .left)),
            (["toggle-container-full-primary-span"], .init(name: .toggleContainerFullPrimarySpan, windowId: "ow_x")),
            (
                ["set-container-primary-span", "50%"],
                .init(name: .setContainerPrimarySpan, windowId: "ow_x", change: half)
            ),
            (["set-window-primary-span", "+10"], .init(name: .setWindowPrimarySpan, windowId: "ow_x", change: delta)),
            (
                ["cycle-window-primary-span", "forward"],
                .init(name: .cycleWindowPrimarySpan, windowId: "ow_x", cycle: .forward)
            ),
            (
                ["set-window-secondary-span", "50%"],
                .init(name: .setWindowSecondarySpan, windowId: "ow_x", change: half)
            ),
            (["reset-window-secondary-span"], .init(name: .resetWindowSecondarySpan, windowId: "ow_x")),
            (
                ["cycle-window-secondary-span", "backward"],
                .init(name: .cycleWindowSecondarySpan, windowId: "ow_x", cycle: .backward)
            ),
            (["toggle-column-tabbed"], .init(name: .toggleColumnTabbed, windowId: "ow_x")),
            (["toggle-floating"], .init(name: .toggleFloating, windowId: "ow_x")),
            (["assign-to-scratchpad", "2"], .init(name: .assignToScratchpad, windowId: "ow_x", scratchpadIndex: 2))
        ]
    }

    func testParserBuildsEveryTargetedAction() throws {
        for (tokens, expected) in try parseCases() {
            let arguments = ["window", tokens[0], "ow_x"] + tokens.dropFirst()
            XCTAssertEqual(try parseWindowRequest(arguments), expected, "\(arguments)")
        }
    }

    func testRoundTripKeepsFlatWireShape() throws {
        for (_, request) in try parseCases() {
            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let argumentKeys = Set(object.keys).subtracting(["name", "windowId"])

            XCTAssertEqual(object["name"] as? String, request.name.rawValue)
            XCTAssertLessThanOrEqual(argumentKeys.count, 1, "\(object)")
            XCTAssertEqual(try JSONDecoder().decode(IPCWindowRequest.self, from: data), request)
        }

        let index = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(IPCWindowRequest(name: .moveColumnToIndex, windowId: "ow_x", columnIndex: 4))
        ) as? [String: Any]
        XCTAssertEqual(index?["columnIndex"] as? Int, 4)

        let cycle = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(IPCWindowRequest(
                name: .cycleWindowPrimarySpan,
                windowId: "ow_x",
                cycle: .backward
            ))
        ) as? [String: Any]
        XCTAssertEqual(cycle?["cycle"] as? String, "backward")
    }

    func testExistingActionsKeepWireShape() throws {
        let data = try JSONEncoder().encode(IPCWindowRequest(name: .focus, windowId: "ow_x"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["name", "windowId"])
    }

    func testDecodeRejectsMissingRequiredKey() {
        let payloads = [
            #"{"name":"move-column-to-index","windowId":"ow_x"}"#,
            #"{"name":"move-column","windowId":"ow_x"}"#,
            #"{"name":"set-window-primary-span","windowId":"ow_x"}"#,
            #"{"name":"cycle-window-secondary-span","windowId":"ow_x"}"#,
            #"{"name":"assign-to-scratchpad","windowId":"ow_x"}"#
        ]
        for payload in payloads {
            XCTAssertThrowsError(try JSONDecoder().decode(IPCWindowRequest.self, from: Data(payload.utf8)), payload)
        }
    }

    func testDecodeRejectsExtraOrWrongKey() {
        let payloads = [
            #"{"name":"toggle-floating","windowId":"ow_x","cycle":"forward"}"#,
            #"{"name":"move-column","windowId":"ow_x","direction":"left","columnIndex":2}"#,
            #"{"name":"move-column-to-index","windowId":"ow_x","scratchpadIndex":2}"#,
            #"{"name":"focus","windowId":"ow_x","direction":"left"}"#,
            #"{"name":"move-to-workspace","windowId":"ow_x","workspaceTarget":{"kind":"raw-id","value":"3"},"cycle":"forward"}"#,
            #"{"name":"move-column-to-index","windowId":"ow_x","columnIndex":0}"#,
            #"{"name":"assign-to-scratchpad","windowId":"ow_x","scratchpadIndex":11}"#
        ]
        for payload in payloads {
            XCTAssertThrowsError(try JSONDecoder().decode(IPCWindowRequest.self, from: Data(payload.utf8)), payload)
        }
    }

    func testParserRejectsBadArityAndBadValues() {
        let invocations = [
            ["window", "move-column-to-first", "ow_x", "1"],
            ["window", "move-column-to-index", "ow_x"],
            ["window", "move-column-to-index", "ow_x", "0"],
            ["window", "move-column-to-index", "ow_x", "two"],
            ["window", "move-column", "ow_x", "sideways"],
            ["window", "set-window-primary-span", "ow_x", "wide"],
            ["window", "cycle-window-primary-span", "ow_x", "up"],
            ["window", "cycle-window-secondary-span", "ow_x"],
            ["window", "assign-to-scratchpad", "ow_x", "0"],
            ["window", "assign-to-scratchpad", "ow_x", "11"],
            ["window", "toggle-floating"]
        ]
        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation), "\(invocation)") { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testHelpAndCompletionsExposeTargetedActions() throws {
        XCTAssertTrue(CLIParser.usageText.contains("omniwmctl window move-column <opaque-id> <left|right|up|down>"))
        XCTAssertTrue(CLIParser.usageText
            .contains("omniwmctl window cycle-window-primary-span <opaque-id> <forward|backward>"))

        let names = try parseCases().map { $0.0[0] }
        for name in names {
            XCTAssertTrue(CLIParser.usageText.contains("omniwmctl window \(name) <opaque-id>"), name)
        }
        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            for name in names {
                XCTAssertTrue(script.contains(name), "\(shell) \(name)")
            }
        }
    }

    private func parseWindowRequest(_ arguments: [String]) throws -> IPCWindowRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + arguments)
        guard case let .window(request) = parsed.request.payload else {
            throw TestFailure.unexpectedPayload
        }
        return request
    }
}
