// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ShellStringsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellStringsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testTheLocaleOutranksTheLayerAndEveryLevelFallsBackToEnglish() throws {
        let region = "de-CH"
        let language = "de"
        XCTAssertEqual(ShellStrings.localizations(region), [region, language, ShellStrings.fallbackLocalization])
        XCTAssertEqual(
            ShellStrings.localizations(ShellStrings.fallbackLocalization),
            [ShellStrings.fallbackLocalization]
        )
        let top = layer("top")
        let style = layer("style")
        let base = layer("default")
        let exact = ["Greeting": "Grüezi"]
        let general = ["Greeting": "Hallo", "Farewell": "Tschüss"]
        let english = ["Greeting": "Hello", "Farewell": "Bye", "Thanks": "Thanks"]
        let overriddenEnglish = ["Thanks": "Thank you"]
        try write(exact, locale: region, in: style)
        try write(general, locale: language, in: top)
        try write(english, locale: ShellStrings.fallbackLocalization, in: base)
        try write(overriddenEnglish, locale: ShellStrings.fallbackLocalization, in: top)

        let strings = try ShellStrings.load([top, style, base], localization: region)
        XCTAssertEqual(strings["Greeting"], exact["Greeting"])
        XCTAssertEqual(strings["Farewell"], general["Farewell"])
        XCTAssertEqual(strings["Thanks"], overriddenEnglish["Thanks"])
        let speed = "5 km/h"
        XCTAssertEqual(
            ShellLocalizer.string("Wind %@", [.text(speed)], strings: strings),
            ShellLocalizer.string("Wind %@", [.text(speed)])
        )
        let unknown = "Not a %@ key"
        XCTAssertEqual(ShellLocalizer.string(unknown, [.text(speed)], strings: strings), unknown)
    }

    func testFoldersWithoutTablesShareTheEmptySnapshot() throws {
        XCTAssertTrue(try ShellStrings.load([layer("top"), layer("style")]) === ShellStrings.empty)
    }

    func testATableThatIsNotFlatTextNamesItsFile() throws {
        let style = layer("style")
        let folder = style.appendingPathComponent(ShellStrings.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(ShellStrings.fallbackLocalization).toml")
        for contents in ["Count = 3\n", "Greeting = \n"] {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ShellStrings.load([style])) { error in
                XCTAssertTrue(
                    error.localizedDescription.hasPrefix("\(ShellStrings.folder)/\(file.lastPathComponent):"),
                    error.localizedDescription
                )
            }
        }
    }

    func testWidgetSourcesCarryTheirStringsAndRefingerprintWhenATableChanges() throws {
        let shell = layer("shell")
        let widget = shell.appendingPathComponent("widgets/probe/init.luau")
        try FileManager.default.createDirectory(
            at: widget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "function render(ctx) return ui.text{ text = omniwm.l10n(\"Greeting\") } end"
            .write(to: widget, atomically: true, encoding: .utf8)
        let input = ShellWidgetSourceLoader.Input(
            name: "probe", shellDirectory: shell, sourceURL: widget, directories: [shell],
            profile: ShellDefaults.profile
        )
        let before = ShellWidgetSourceLoader.fingerprint(input)
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input).strings, ShellStrings.empty)
        let table = ["Greeting": "Hello"]
        try write(table, locale: ShellStrings.appLocalization, in: shell)
        XCTAssertNotEqual(ShellWidgetSourceLoader.fingerprint(input), before)
        XCTAssertEqual(try ShellWidgetSourceLoader.build(input).strings, ShellStrings(table))
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile])
    }

    private func layer(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func write(_ table: [String: String], locale: String, in layer: URL) throws {
        let folder = layer.appendingPathComponent(ShellStrings.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try table.sorted { $0.key < $1.key }.map { "\"\($0.key)\" = \"\($0.value)\"" }.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("\(locale).toml"), atomically: true, encoding: .utf8)
    }
}
