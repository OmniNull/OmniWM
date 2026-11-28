// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import XCTest

final class DwindleResizeCommandContractTests: XCTestCase {
    private struct ExpectedAction {
        let id: String
        let command: HotkeyCommand
        let title: String
        let ipcCommandName: IPCCommandName
    }

    func testResizeActionsExposeSixDistinctGUICommands() throws {
        let expected = [
            ExpectedAction(
                id: "resizeGrow.horizontal",
                command: .dwindle(.resizeAlongAxis(.horizontal, true)),
                title: "Grow Horizontally",
                ipcCommandName: .dwindle(.resize)
            ),
            ExpectedAction(
                id: "resizeGrow.vertical",
                command: .dwindle(.resizeAlongAxis(.vertical, true)),
                title: "Grow Vertically",
                ipcCommandName: .dwindle(.resize)
            ),
            ExpectedAction(
                id: "resizeShrink.horizontal",
                command: .dwindle(.resizeAlongAxis(.horizontal, false)),
                title: "Shrink Horizontally",
                ipcCommandName: .dwindle(.resize)
            ),
            ExpectedAction(
                id: "resizeShrink.vertical",
                command: .dwindle(.resizeAlongAxis(.vertical, false)),
                title: "Shrink Vertically",
                ipcCommandName: .dwindle(.resize)
            ),
            ExpectedAction(
                id: "resizeFocusedWindow.grow",
                command: .dwindle(.resizeFocusedWindow(true)),
                title: "Grow Focused Window",
                ipcCommandName: .dwindle(.resizeFocused)
            ),
            ExpectedAction(
                id: "resizeFocusedWindow.shrink",
                command: .dwindle(.resizeFocusedWindow(false)),
                title: "Shrink Focused Window",
                ipcCommandName: .dwindle(.resizeFocused)
            )
        ]

        XCTAssertEqual(Set(expected.map(\.command)).count, expected.count)
        for action in expected {
            let spec = try XCTUnwrap(ActionCatalog.spec(for: action.id))
            XCTAssertEqual(spec.command, action.command)
            XCTAssertEqual(spec.title, action.title)
            XCTAssertEqual(spec.category, .layout)
            XCTAssertEqual(spec.visibility, .advanced)
            XCTAssertEqual(spec.layoutCompatibility, .dwindle)
            XCTAssertEqual(spec.defaultBinding, .unassigned)
            XCTAssertEqual(spec.ipcCommandName, action.ipcCommandName)
        }
    }

    func testDirectionalResizeActionIDsAreAbsent() {
        let oldIds = [
            "resizeGrow.left",
            "resizeGrow.right",
            "resizeGrow.up",
            "resizeGrow.down",
            "resizeShrink.left",
            "resizeShrink.right",
            "resizeShrink.up",
            "resizeShrink.down"
        ]

        for id in oldIds {
            XCTAssertNil(ActionCatalog.spec(for: id))
        }
    }
}
