// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class DwindleGroupCommandContractTests: XCTestCase {
    func testRemovedGroupCommandsAreAbsentFromCatalogAndIPC() {
        let removedActionIDs = [
            "groupWindow.left",
            "groupWindow.right",
            "groupWindow.up",
            "groupWindow.down",
            "ungroupWindow.left",
            "ungroupWindow.right",
            "ungroupWindow.up",
            "ungroupWindow.down",
            "focusGroupNext",
            "focusGroupPrevious",
            "moveGroupMemberNext",
            "moveGroupMemberPrevious"
        ]

        for id in removedActionIDs {
            XCTAssertNil(ActionCatalog.spec(for: id))
        }

        let removedIPCNames = [
            "group-window",
            "ungroup-window",
            "focus-group-next",
            "focus-group-previous",
            "move-group-member-next",
            "move-group-member-previous"
        ]

        for rawValue in removedIPCNames {
            XCTAssertNil(IPCCommandName(rawValue: rawValue))
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    IPCCommandRequest.self,
                    from: Data(#"{"name":"\#(rawValue)"}"#.utf8)
                )
            )
        }
    }

    func testFocusActionsExposeDwindleGroupNavigation() throws {
        let directionalCases: [(HotkeyCommand, String, UInt32)] = [
            (.focus(.down), "focus.down", UInt32(kVK_DownArrow)),
            (.focus(.up), "focus.up", UInt32(kVK_UpArrow))
        ]

        for (command, id, keyCode) in directionalCases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))

            XCTAssertEqual(spec.id, id)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(
                spec.defaultBinding,
                KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey))
            )
            assertSearchTerms(["group", "tab", "cycle"], in: spec)
        }

        let wrappingCases: [(HotkeyCommand, String, IPCCommandName)] = [
            (.focusNavigation(.windowDownOrTop), "focusWindowDownOrTop", .focus(.windowDownOrTop)),
            (.focusNavigation(.windowUpOrBottom), "focusWindowUpOrBottom", .focus(.windowUpOrBottom))
        ]

        for (command, id, ipcName) in wrappingCases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            let descriptor = try XCTUnwrap(spec.ipcDescriptor)

            XCTAssertEqual(spec.id, id)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.visibility, .advanced)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, ipcName)
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertTrue(descriptor.summary.localizedCaseInsensitiveContains("wrapping"))
            assertSearchTerms(["wrap", "group", "tab", "cycle"], in: spec)
        }
    }

    func testMoveActionsExposeDwindleJoinAndExtractBehavior() throws {
        let directionalCases: [(Direction, UInt32)] = [
            (.left, UInt32(kVK_LeftArrow)),
            (.right, UInt32(kVK_RightArrow)),
            (.up, UInt32(kVK_UpArrow)),
            (.down, UInt32(kVK_DownArrow))
        ]

        for (direction, keyCode) in directionalCases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: .move(direction)))

            XCTAssertEqual(spec.id, "move.\(direction.rawValue)")
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.visibility, .normal)
            XCTAssertEqual(
                spec.defaultBinding,
                KeyBinding(keyCode: keyCode, modifiers: UInt32(optionKey | shiftKey))
            )
            assertSearchTerms(["group", "tab", "join", "extract"], in: spec)
        }
    }

    func testWindowReorderActionsAreSharedAdvancedActions() throws {
        let cases: [(HotkeyCommand, String, String, IPCCommandName)] = [
            (.windowMovement(.down), "moveWindowDown", "Move Window to Next Position", .windowMovement(.down)),
            (.windowMovement(.up), "moveWindowUp", "Move Window to Previous Position", .windowMovement(.up))
        ]

        for (command, id, title, ipcName) in cases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: command))
            let descriptor = try XCTUnwrap(spec.ipcDescriptor)

            XCTAssertEqual(spec.id, id)
            XCTAssertEqual(spec.title, title)
            XCTAssertEqual(spec.layoutCompatibility, .shared)
            XCTAssertEqual(spec.visibility, .advanced)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, ipcName)
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)
            XCTAssertTrue(descriptor.summary.localizedCaseInsensitiveContains("reorder"))
            assertSearchTerms(["reorder", "group", "tab", "column"], in: spec)
        }
    }

    func testMoveContainerActionsHaveDirectionSpecificCompatibility() throws {
        let cases: [(Direction, LayoutCompatibility, KeyBinding)] = [
            (
                .left,
                .shared,
                KeyBinding(
                    keyCode: UInt32(kVK_LeftArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            (
                .right,
                .shared,
                KeyBinding(
                    keyCode: UInt32(kVK_RightArrow),
                    modifiers: UInt32(optionKey | controlKey | shiftKey)
                )
            ),
            (.up, .dwindle, .unassigned),
            (.down, .dwindle, .unassigned)
        ]

        for (direction, compatibility, binding) in cases {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: .moveColumn(direction)))

            XCTAssertEqual(spec.id, "moveColumn.\(direction.rawValue)")
            XCTAssertEqual(spec.title, "Move Container \(direction.displayName)")
            XCTAssertEqual(spec.layoutCompatibility, compatibility)
            XCTAssertEqual(spec.visibility, .advanced)
            XCTAssertEqual(spec.defaultBinding, binding)
            XCTAssertEqual(spec.ipcCommandName, .column(.move))
            assertSearchTerms(["container", "tile", "group"], in: spec)
        }

        let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: .column(.move)))

        XCTAssertEqual(descriptor.commandWords, ["move-column"])
        XCTAssertEqual(descriptor.path, "command move-column <left|right|up|down>")
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.direction])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertTrue(descriptor.summary.contains("Niri"))
        XCTAssertTrue(descriptor.summary.contains("Dwindle"))

        for id in ["moveColumn.left", "moveColumn.right"] {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: id))
            let matchingIDs = ActionCatalog.allSpecs()
                .filter { $0.defaultBinding == spec.defaultBinding }
                .map(\.id)

            XCTAssertEqual(matchingIDs, [id])
        }
    }

    func testReusedIPCRequestsRetainCanonicalWireShapes() throws {
        let requests: [IPCCommandRequest] = [
            .focus(.spatial(direction: .down)),
            .focus(.windowDownOrTop),
            .windowMovement(.spatial(direction: .left)),
            .windowMovement(.up),
            .column(.move(direction: .down))
        ]

        for request in requests {
            let data = try JSONEncoder().encode(request)

            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }

        XCTAssertEqual(
            try IPCCommandRequest(name: .column(.move), argumentValues: [.direction(.up)]),
            .column(.move(direction: .up))
        )

        let data = try JSONEncoder().encode(IPCCommandRequest.column(.move(direction: .down)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let arguments = try XCTUnwrap(object["arguments"] as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "move-column")
        XCTAssertEqual(arguments["direction"] as? String, "down")
    }

    private func assertSearchTerms(
        _ expectedTerms: [String],
        in spec: ActionSpec,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let terms = Set(spec.searchTerms.map(ActionCatalog.normalizedSearchTerm))

        for term in expectedTerms {
            XCTAssertTrue(terms.contains(term), "Missing search term \(term)", file: file, line: line)
        }
    }
}
