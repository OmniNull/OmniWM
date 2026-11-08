// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class PaletteModifierTests: XCTestCase {
    func testConfigurationWithoutCommandPaletteSectionUsesCommand() throws {
        let encoded = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        var inPaletteSection = false
        let legacy = encoded.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("[") { inPaletteSection = line == "[commandPalette]" }
            return !inPaletteSection
        }.joined(separator: "\n")
        XCTAssertNotEqual(legacy, encoded)

        let decoded = try SettingsTOMLCodec.decode(Data(legacy.utf8))

        XCTAssertEqual(decoded.commandPalette.modifier.humanReadableString, "Command")
        XCTAssertEqual(decoded.commandPalette.modifier.symbolsString, "⌘")
    }

    func testModifierCombinationRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.commandPalette.modifier = try XCTUnwrap(
            PaletteModifier(carbonMask: UInt32(controlKey | optionKey))
        )

        let data = try SettingsTOMLCodec.encode(export)

        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("modifier = \"Control+Option\""))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).commandPalette, export.commandPalette)
    }

    func testTOMLRejectsEmptyShiftOnlyAndUnknownModifiers() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        XCTAssertTrue(canonical.contains("modifier = \"Command\""))
        for value in ["", "Shift", "Hyper", "Control+Banana", "Left Command"] {
            let corrupt = canonical.replacingOccurrences(
                of: "modifier = \"Command\"",
                with: "modifier = \"\(value)\""
            )
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(corrupt.utf8)), value) { error in
                guard case let DecodingError.dataCorrupted(context) = error else {
                    return XCTFail("\(value): expected dataCorrupted, got \(error)")
                }
                XCTAssertEqual(context.codingPath.map(\.stringValue), ["commandPalette", "modifier"], value)
            }
        }
    }

    func testTogglingRefusesEmptyAndShiftOnlyModifiers() throws {
        let command = PaletteModifier.default
        let shift = UInt32(shiftKey)
        let commandFlag = UInt32(cmdKey)

        let shiftCommand = try XCTUnwrap(command.setting(shift, included: true))
        XCTAssertEqual(shiftCommand.symbolsString, "⇧⌘")
        XCTAssertNil(command.setting(commandFlag, included: false))
        XCTAssertNil(shiftCommand.setting(commandFlag, included: false))
        XCTAssertEqual(shiftCommand.setting(shift, included: false), command)
    }

    func testOptionAloneIsAllowedAndFlaggedAsBlockingTypedCharacters() throws {
        let option = try XCTUnwrap(PaletteModifier(carbonMask: UInt32(optionKey)))
        XCTAssertTrue(option.mayBlockTypedCharacters)
        XCTAssertFalse(try XCTUnwrap(PaletteModifier(carbonMask: UInt32(optionKey | cmdKey))).mayBlockTypedCharacters)
        XCTAssertFalse(PaletteModifier.default.mayBlockTypedCharacters)
    }
}
