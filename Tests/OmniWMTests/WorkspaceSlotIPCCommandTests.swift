// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class WorkspaceSlotIPCCommandTests: XCTestCase {
    func testSlotRequestsRoundTripThroughJSONAndManifest() throws {
        let cases: [(request: IPCCommandRequest, name: IPCCommandName, words: [String], slot: Int)] = [
            (.workspace(.switchSlot(slotNumber: 2)), .workspace(.switchSlot), ["switch-workspace", "slot"], 2),
            (.workspace(.moveToSlot(slotNumber: 3)), .workspace(.moveToSlot), ["move-to-workspace", "slot"], 3)
        ]

        for entry in cases {
            XCTAssertEqual(entry.request.name, entry.name)
            let data = try JSONEncoder().encode(entry.request)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), entry.request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((json["arguments"] as? [String: Any])?["slotNumber"] as? Int, entry.slot)

            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: entry.name))
            XCTAssertEqual(descriptor.commandWords, entry.words)
            XCTAssertEqual(descriptor.arguments.map(\.kind), [.workspaceNumber])
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertEqual(
                try IPCCommandRequest(name: entry.name, argumentValues: [.integer(entry.slot)]),
                entry.request
            )
        }
    }

    func testParserBuildsSlotRequestsAndKeepsNumericForms() throws {
        XCTAssertEqual(
            try commandPayload(["switch-workspace", "slot", "2"]),
            .workspace(.switchSlot(slotNumber: 2))
        )
        XCTAssertEqual(
            try commandPayload(["move-to-workspace", "slot", "3"]),
            .workspace(.moveToSlot(slotNumber: 3))
        )
        XCTAssertEqual(try commandPayload(["switch-workspace", "2"]), .workspace(.switchTo(workspaceNumber: 2)))
        XCTAssertEqual(try commandPayload(["move-to-workspace", "3"]), .workspace(.moveTo(workspaceNumber: 3)))

        for malformed in [
            ["switch-workspace", "slot"],
            ["switch-workspace", "slot", "0"],
            ["move-to-workspace", "slot", "x"],
            ["move-to-workspace", "slot", "2", "3"]
        ] {
            XCTAssertThrowsError(try commandPayload(malformed), malformed.joined(separator: " "))
        }
    }

    func testHelpAndCompletionsExposeSlotCommands() {
        XCTAssertTrue(CLIParser.usageText.contains("switch-workspace slot <number>"))
        XCTAssertTrue(CLIParser.usageText.contains("move-to-workspace slot <number>"))
        XCTAssertTrue(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["switch-workspace"]?
            .contains("slot") == true)
        XCTAssertTrue(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["move-to-workspace"]?
            .contains("slot") == true)
        for command in ["switch-workspace", "move-to-workspace"] {
            XCTAssertTrue(CLICompletionSelector.suggestions(words: ["omniwmctl", "command", command, ""])
                .contains("slot"))
        }
    }

    private func commandPayload(_ words: [String]) throws -> IPCCommandRequest {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command"] + words)
        guard case let .command(request) = parsed.request.payload else {
            throw CLIParseError.usage("expected a command payload")
        }
        return request
    }
}
