// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ActionCatalogLookupTests: XCTestCase {
    func testCommandLookupPreservesCatalogMetadata() {
        let specs = ActionCatalog.allSpecs()
        for spec in specs {
            let expected = specs.first { $0.command == spec.command }
            XCTAssertEqual(ActionCatalog.spec(for: spec.command), expected, spec.id)
            XCTAssertEqual(spec.command.displayName, expected?.title, spec.id)
            XCTAssertEqual(spec.command.layoutCompatibility, expected?.layoutCompatibility, spec.id)
        }
    }

    func testUncataloguedCommandsKeepDisplayFallbacks() {
        let commands: [HotkeyCommand] = [
            .workspace(.switchTo(9999)),
            .column(.moveToIndex(123)),
            .sizing(.setContainerPrimarySpan(.setFixed(3.14159)))
        ]
        for command in commands {
            XCTAssertNil(ActionCatalog.spec(for: command))
            XCTAssertEqual(command.displayName, String(describing: command))
            XCTAssertEqual(command.layoutCompatibility, .shared)
        }
    }

    func testNormalizedSearchMetadataIncludesIDsScopesKeywordsAndIPCWords() throws {
        let terms = try XCTUnwrap(ActionCatalog.normalizedSearchTerms(for: "moveWindowToMonitor.left"))

        for expected in [
            "movewindowtomonitor left",
            "move window to left monitor",
            "shared",
            "adjacent monitor",
            "send window",
            "command move to monitor <left|right|up|down>",
            "move to monitor"
        ] {
            XCTAssertTrue(terms.contains(expected), expected)
        }
        XCTAssertEqual(Set(terms).count, terms.count)
        XCTAssertNil(ActionCatalog.normalizedSearchTerms(for: "unknown-action"))
    }

    func testCanonicalEnglishTitlesStayIndependentOfCurrentCatalogLanguage() {
        XCTAssertEqual(ActionCatalog.spec(for: .focus(.left))?.title, "Focus Left")
        XCTAssertEqual(ActionCatalog.spec(for: .workspace(.switchTo(1)))?.title, "Switch to Workspace 2")
    }

    func testCanonicalSourceTitleIgnoresTranslatedCatalogValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localizationDirectory = directory.appendingPathComponent("fr.lproj")
        try FileManager.default.createDirectory(at: localizationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "\"command.focus.left\" = \"Focaliser gauche\";".write(
            to: localizationDirectory.appendingPathComponent("Commands.strings"),
            atomically: true,
            encoding: .utf8
        )
        let resource = LocalizedStringResource(
            "command.focus.left",
            defaultValue: "Focus Left",
            table: "Commands",
            locale: Locale(identifier: "fr"),
            bundle: .atURL(directory)
        )

        XCTAssertEqual(String(localized: resource), "Focaliser gauche")
        XCTAssertEqual(ActionCatalog.canonicalSourceTitle(for: resource), "Focus Left")
    }

    func testSearchNormalizationHandlesNativeCaseAndCombiningMarks() {
        XCTAssertEqual(ActionCatalog.normalizedSearchTerm("İşle"), ActionCatalog.normalizedSearchTerm("işle"))
        XCTAssertEqual(ActionCatalog.normalizedSearchTerm("cafe\u{301}"), ActionCatalog.normalizedSearchTerm("café"))
    }
}
