// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellWidgetOptionDeclarationTests: XCTestCase {
    private static let undeclaredReads: Set<String> = ["world-clock:zones", "lake:render"]
    private static let libraryOwners = [
        "lib/audio.luau": ["volume"],
        "lib/battery.luau": ["battery-details"],
        "lib/calendar.luau": ["calendar"],
        "lib/look.luau": ["workspaces"],
        "lib/stats.luau": ["stats"],
        "lib/weather.luau": ["weather"],
        "lib/world-clock.luau": ["world-clock"],
        "lib/lake/intent.luau": ["lake"],
        "lib/lake/preferences.luau": ["lake"],
        "lib/lake/services/battery.luau": ["battery"],
        "lib/lake/services/calendar.luau": ["calendar"],
        "lib/lake/services/convert.luau": ["converter"],
        "lib/lake/services/devices.luau": ["devices"],
        "lib/lake/services/notice.luau": ["battery", "devices"],
        "lib/lake/services/timer.luau": ["timer"],
        "lib/vitreus/bar.luau": ["vitreus"],
        "lib/vitreus/bar/marks.luau": ["vitreus"],
        "lib/vitreus/frame.luau": ["vitreus"],
        "lib/vitreus/media.luau": ["vitreus"],
        "lib/vitreus/visualiser.luau": ["vitreus"]
    ]
    private static let literalAccessors = [
        "lib/lake/preferences.luau": ["value"],
        "lib/lake/intent.luau": ["preferences.value"],
        "widgets/lake/init.luau": ["preferences.value", "preferences.color"]
    ]

    private func layers(
        bundled: URL? = ShellDefaults.bundled, styles: URL = ShellStyleFixture.directory
    ) throws -> [URL] {
        try [XCTUnwrap(bundled)] + ShellStyleFixture.names(in: styles).map {
            try ShellStyleFixture.source($0, in: styles)
        }
    }

    private func widgetNames(in layer: URL) throws -> [String] {
        let widgets = layer.appendingPathComponent("widgets")
        guard FileManager.default.fileExists(atPath: widgets.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: widgets.path)
    }

    private func declaredOptions(_ widget: String, in layer: URL) throws -> [String: ShellComponentOption] {
        var options = try ShellRootSettings.load(widget, directories: [layer])?.options ?? [:]
        let component = layer.appendingPathComponent("widgets/\(widget)/component.toml")
        if FileManager.default.fileExists(atPath: component.path) {
            options.merge(try ShellComponentCatalog.load(widget, directories: [layer]).options) { first, _ in first }
        }
        return options
    }

    private func captures(_ pattern: String, in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = []
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            for group in 1 ..< match.numberOfRanges {
                if let range = Range(match.range(at: group), in: source) { keys.insert(String(source[range])) }
            }
        }
        return keys
    }

    private func files(in folder: URL) -> [URL] {
        FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "luau" } ?? []
    }

    private func optionReads(in folder: URL) throws -> Set<String> {
        var keys: Set<String> = []
        for file in files(in: folder) {
            let source = try String(contentsOf: file, encoding: .utf8)
            try keys.formUnion(captures(
                #"\b(?:settings|options)(?: or \{\}\))?\.([A-Za-z_][A-Za-z0-9_]*)|select\("settings",\s*"([A-Za-z_][A-Za-z0-9_]*)""#,
                in: source
            ))
            try keys.formUnion(literalAccessorReads(in: source, file: file))
        }
        return keys
    }

    private func literalAccessorReads(in source: String, file: URL) throws -> Set<String> {
        let accessors = Self.literalAccessors.first { file.path.hasSuffix("/" + $0.key) }?.value ?? []
        return try accessors.reduce(into: Set<String>()) { keys, accessor in
            try keys.formUnion(captures(
                #"\b"# + NSRegularExpression.escapedPattern(for: accessor)
                    + #"\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)""#,
                in: source
            ))
        }
    }

    private func libraryReads(in file: URL) throws -> Set<String> {
        let source = try String(contentsOf: file, encoding: .utf8)
        var patterns = [
            #"\b(?:ctx\.)?data\.settings(?: or \{\}\))?\.([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\b(?:ctx\.)?instance\.options\.([A-Za-z_][A-Za-z0-9_]*)"#,
            #"select\("settings",\s*"([A-Za-z_][A-Za-z0-9_]*)""#
        ]
        for alias in try captures(
            #"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:ctx\.)?(?:data\.settings|instance\.options)\b"#,
            in: source
        ) {
            patterns.append(#"\b"# + NSRegularExpression.escapedPattern(for: alias)
                + #"(?: or \{\}\))?\.([A-Za-z_][A-Za-z0-9_]*)"#)
        }
        var keys = try patterns.reduce(into: Set<String>()) { try $0.formUnion(captures($1, in: source)) }
        try keys.formUnion(literalAccessorReads(in: source, file: file))
        return keys
    }

    private func libraryOptions(
        _ widget: String, in layer: URL, fallback: URL?
    ) throws -> [String: ShellComponentOption] {
        let folder = layer.appendingPathComponent("widgets/\(widget)")
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("component.luau").path) {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("component.toml").path)
            else { return [:] }
            return try ShellComponentCatalog.load(widget, directories: [layer]).options
        }
        return try ShellRootSettings.load(widget, directories: [layer] + (fallback.map { [$0] } ?? []))?.options ?? [:]
    }

    private func undeclaredOptions(in layer: URL, fallback: URL? = nil) throws -> Set<String> {
        var missing: Set<String> = []
        let widgets = layer.appendingPathComponent("widgets")
        for name in try widgetNames(in: layer) {
            let declared = try declaredOptions(name, in: layer)
            for key in try optionReads(in: widgets.appendingPathComponent(name))
                where declared[key] == nil && !Self.undeclaredReads.contains("\(name):\(key)")
            {
                missing.insert("\(name):\(key)")
            }
        }
        for file in files(in: layer.appendingPathComponent("lib")) {
            let reads = try libraryReads(in: file)
            guard !reads.isEmpty else { continue }
            let path = String(file.resolvingSymlinksInPath().path
                .dropFirst(layer.resolvingSymlinksInPath().path.count + 1))
            guard let owners = Self.libraryOwners[path], !owners.isEmpty else {
                missing.insert("Missing owner mapping for library \(path)")
                continue
            }
            for name in owners {
                let declared = try libraryOptions(name, in: layer, fallback: fallback)
                for key in reads where declared[key] == nil && !Self.undeclaredReads.contains("\(name):\(key)") {
                    missing.insert("\(name):\(key)")
                }
            }
        }
        return missing
    }

    func testBundledWidgetsDeclareEveryOptionTheyRead() throws {
        let bundled = try XCTUnwrap(ShellDefaults.bundled)
        for layer in try layers() {
            XCTAssertEqual(
                try undeclaredOptions(in: layer, fallback: layer == bundled ? nil : bundled), [],
                layer.lastPathComponent
            )
        }
    }

    func testSharedLibraryReadsRequireTheirRootWidgetSchemas() throws {
        let source = try XCTUnwrap(ShellDefaults.bundled)
        let layer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: layer)
        defer { try? FileManager.default.removeItem(at: layer) }
        let options = [
            "calendar": "agendaEvents", "weather": "forecastHours", "battery-details": "percent",
            "world-clock": "bar", "volume": "step", "stats": "variant"
        ]
        for widget in options.keys {
            try FileManager.default.removeItem(at: layer.appendingPathComponent("widgets/\(widget)/settings.toml"))
        }
        XCTAssertEqual(try undeclaredOptions(in: layer), Set(options.map { "\($0.key):\($0.value)" }))
    }

    func testSharedLibraryReadsRequireTheirComponentSchemas() throws {
        let source = ShellStyleFixture.directory.appendingPathComponent("lake")
        let layer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: layer)
        defer { try? FileManager.default.removeItem(at: layer) }
        let options = [
            "battery": ["lowThreshold", "alerts", "alertSeconds"], "devices": ["alerts", "alertSeconds"],
            "calendar": ["leadMinutes", "alerts", "alertSeconds"], "timer": ["duration", "label"],
            "converter": ["format"]
        ]
        for widget in options.keys {
            try FileManager.default.removeItem(at: layer.appendingPathComponent("widgets/\(widget)/component.toml"))
        }
        XCTAssertEqual(try undeclaredOptions(in: layer), Set(options.flatMap { widget, keys in
            keys.map { "\(widget):\($0)" }
        }))
    }

    func testLibraryOnlyStylesCheckTheirInheritedRootSchemas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("default")
        let styles = directory.appendingPathComponent("styles")
        let layer = styles.appendingPathComponent("celestial")
        try FileManager.default.createDirectory(
            at: layer.appendingPathComponent("lib"),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: XCTUnwrap(ShellDefaults.bundled), to: bundled)
        let source = ShellStyleFixture.directory.appendingPathComponent("celestial/lib/look.luau")
        try FileManager.default.copyItem(at: source, to: layer.appendingPathComponent("lib/look.luau"))
        XCTAssertEqual(
            try layers(bundled: bundled, styles: styles).map { $0.resolvingSymlinksInPath().path },
            [bundled, layer].map { $0.resolvingSymlinksInPath().path }
        )
        XCTAssertEqual(try undeclaredOptions(in: layer, fallback: bundled), [])
        try FileManager.default.removeItem(at: bundled.appendingPathComponent("widgets/workspaces/settings.toml"))
        XCTAssertEqual(try undeclaredOptions(in: layer, fallback: bundled), ["workspaces:occupiedBackground"])
    }

    func testUnmappedLibraryCannotBorrowAnotherWidgetsSchemaByItsBasename() throws {
        let layer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: layer) }
        let folder = layer.appendingPathComponent("widgets/format")
        let library = layer.appendingPathComponent("lib/calendar/format.luau")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = try XCTUnwrap(ShellDefaults.bundled).appendingPathComponent("widgets/calendar/settings.toml")
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("settings.toml"))
        try "return function(ctx) return ctx.data.settings.agendaEvents end"
            .write(to: library, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try undeclaredOptions(in: layer), ["Missing owner mapping for library lib/calendar/format.luau"]
        )
    }

    func testLakeAccessorReadsRequireTheirRootSchema() throws {
        let source = ShellStyleFixture.directory.appendingPathComponent("lake")
        let layer = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: layer)
        defer { try? FileManager.default.removeItem(at: layer) }
        let manifest = layer.appendingPathComponent("widgets/lake/settings.toml")
        let original = try String(contentsOf: manifest, encoding: .utf8)
        let schema = try XCTUnwrap(ShellRootSettings.load("lake", directories: [layer]))
        for key in schema.options.keys.sorted() {
            let changed = original.replacingOccurrences(of: "[options.\(key)]", with: "[options.missing_\(key)]")
            XCTAssertNotEqual(changed, original, key)
            try changed.write(to: manifest, atomically: true, encoding: .utf8)
            XCTAssertEqual(try undeclaredOptions(in: layer), ["lake:\(key)"], key)
        }
    }

    func testBundledColorOptionDefaultsAreHexColors() throws {
        for layer in try layers() {
            for name in try widgetNames(in: layer) {
                for (key, option) in try declaredOptions(name, in: layer)
                    where option.kind == .string && key.lowercased().hasSuffix("color")
                {
                    guard case let .string(value)? = option.defaultValue else { continue }
                    XCTAssertNotNil(
                        ShellWidgetSettingsModel.rgba(value),
                        "\(layer.lastPathComponent)/\(name) \(key) default \(value) is not #rrggbb or #rrggbbaa"
                    )
                }
            }
        }
    }
}
