// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class CLICompletionCatalogTests: XCTestCase {
    func testScratchpadActionsAndSlotsOccupySeparateArgumentPositions() {
        XCTAssertEqual(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["scratchpad"], ["assign", "toggle"])
        let slots = IPCScratchpadSlots.range.map(String.init).sorted()
        for action in ["assign", "toggle"] {
            XCTAssertEqual(CLICompletionCatalog.commandSlotFourSuggestionsByPath["scratchpad \(action)"], slots)
        }
    }

    func testFocusCombinesDirectArgumentsAndNestedCommands() {
        XCTAssertEqual(
            CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["focus"],
            ["left", "right", "up", "down", "previous", "down-or-left", "up-or-right"].sorted()
        )
    }

    func testWindowGatherOffersItsReachFlagAndValues() {
        XCTAssertTrue(CLICompletionCatalog.windowActionNames.contains("gather"))
        XCTAssertEqual(CLICompletionCatalog.windowGatherReachFlag, "--from")
        XCTAssertEqual(CLICompletionCatalog.windowGatherReaches, ["workspace", "monitor", "all"])
        XCTAssertTrue(CLICompletionCatalog.valueFlags.contains("--from"))
        XCTAssertEqual(CLICompletionCatalog.flagValuesByName["--from"], ["workspace", "monitor", "all"])
    }

    func testResizePreservesBothLiteralArgumentPositions() {
        XCTAssertEqual(CLICompletionCatalog.commandSlotThreeSuggestionsByFirst["resize"], ["horizontal", "vertical"])
        XCTAssertEqual(CLICompletionCatalog.commandSlotFourFallbackByFirst["resize"], ["grow", "shrink"])
    }
}
