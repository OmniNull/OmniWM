// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import TOML
import XCTest

final class ShellStyleManifestTests: XCTestCase {
    private var shell: URL!
    private let profile = "probe"
    private let version = "1.2.3"
    private let title = "Probe"
    private let summary = "A probe style."

    private var folder: URL {
        shell.appendingPathComponent(profile, isDirectory: true)
    }

    private var required: [String: String] {
        [
            "format": "\(ShellStyleManifest.format)", "name": "\"\(profile)\"", "version": "\"\(version)\"",
            "api": "\(ShellStyleManifest.api)", "title": "\"\(title)\"", "summary": "\"\(summary)\""
        ]
    }

    override func setUpWithError() throws {
        shell = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellStyleManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: shell)
    }

    func testAFolderWithoutAManifestIsAPlainProfile() throws {
        XCTAssertNil(try ShellStyleManifest.load(in: folder))
        XCTAssertNil(ShellStyleManifest.problem(in: folder))
    }

    func testAValidManifestKeepsItsDeclaredFields() throws {
        try write(required)
        let manifest = try XCTUnwrap(ShellStyleManifest.load(in: folder))
        XCTAssertEqual(manifest.name, profile)
        XCTAssertEqual(manifest.version, version)
        XCTAssertEqual(manifest.title, title)
        XCTAssertEqual(manifest.summary, summary)
        XCTAssertEqual(manifest.tags, [])
        XCTAssertEqual(manifest.previews, [])
        XCTAssertNil(manifest.author)
        XCTAssertNil(manifest.minimumOmniWM)
        XCTAssertNil(manifest.barEffect)
    }

    func testManifestsForAnotherFormatOrAPIAreRefused() throws {
        for (key, value) in [("format", ShellStyleManifest.format + 1), ("api", ShellStyleManifest.api + 1)] {
            try write(required.merging([key: "\(value)"]) { $1 })
            XCTAssertThrowsError(try ShellStyleManifest.load(in: folder), key)
            XCTAssertNotNil(ShellStyleManifest.problem(in: folder), key)
        }
    }

    func testTheMinimumOmniWMIsCheckedAgainstAKnownAppVersion() throws {
        let minimum = try XCTUnwrap(ReleaseVersion(version))
        try write(required.merging(["minOmniWM": "\"\(minimum.normalizedString)\""]) { $1 })
        let older = try XCTUnwrap(ReleaseVersion("\(minimum.components[0] - 1)"))
        XCTAssertThrowsError(try ShellStyleManifest.load(in: folder, appVersion: older))
        XCTAssertEqual(
            try ShellStyleManifest.load(in: folder, appVersion: minimum)?.minimumOmniWM,
            minimum.normalizedString
        )
        XCTAssertNotNil(try ShellStyleManifest.load(in: folder, appVersion: nil))
    }

    func testVersionsArePlainReleaseNumbers() throws {
        for accepted in ["0.0.1", version, "10.20.30"] {
            try write(required.merging(["version": "\"\(accepted)\""]) { $1 })
            XCTAssertNil(ShellStyleManifest.problem(in: folder), accepted)
        }
        for rejected in ["1..2", "1.2", "01.2.3", "1.2.3-beta.1", "v1.2.3", "1.2.\u{663}"] {
            for key in ["version", "minOmniWM"] {
                try write(required.merging([key: "\"\(rejected)\""]) { $1 })
                XCTAssertNotNil(ShellStyleManifest.problem(in: folder), "\(key) \(rejected)")
            }
        }
    }

    func testUnknownKeysWrongTypesAndMissingFieldsAreReported() throws {
        let cases: [(String, [String: String])] = [
            ("unknown key colour", required.merging(["colour": "\"red\""]) { $1 }),
            ("name", required.merging(["name": "3"]) { $1 }),
            ("version", required.merging(["version": "\"one\""]) { $1 }),
            ("title", required.filter { $0.key != "title" }),
            ("previews", required.merging(["previews": "[\"../escape.png\"]"]) { $1 })
        ]
        for (problem, entries) in cases {
            try write(entries)
            let message = try XCTUnwrap(ShellStyleManifest.problem(in: folder), problem)
            XCTAssertTrue(message.hasPrefix(ShellStyleManifest.fileName), message)
            XCTAssertTrue(message.contains(problem), message)
        }
    }

    func testBarEffectsDescribeAtMostOneNumberControlPerShaderValue() throws {
        let number = "{ type = \"number\", title = \"Value\", min = 0, max = 1 }"
        func effect(_ count: Int, option: String) -> String {
            "\n[barEffect]\ntitle = \"Effect\"\nvalues = [\(Array(repeating: option, count: count).joined(separator: ", "))]\n"
        }
        try write(required, extra: effect(ShellBarShader.valueCount, option: number))
        let barEffect = try XCTUnwrap(try ShellStyleManifest.load(in: folder)?.barEffect)
        XCTAssertEqual(barEffect.values.count, ShellBarShader.valueCount)
        XCTAssertTrue(barEffect.values.allSatisfy { $0.kind == .number && $0.minimum != nil && $0.maximum != nil })
        let toggle = "{ type = \"boolean\", title = \"Value\" }"
        for extra in [
            effect(ShellBarShader.valueCount + 1, option: number),
            effect(0, option: number),
            effect(1, option: toggle)
        ] {
            try write(required, extra: extra)
            XCTAssertNotNil(ShellStyleManifest.problem(in: folder), extra)
        }
    }

    func testAnIncompatibleStyleCannotBeChosenAndFallsBackToDefault() throws {
        XCTAssertEqual(ShellDefaults.sync(into: shell), [])
        try write(required.merging(["api": "\(ShellStyleManifest.api + 1)"]) { $1 })
        XCTAssertThrowsError(try ShellProfiles.select(profile, in: shell))
        try "profile = \"\(profile)\"\n".write(
            to: shell.appendingPathComponent("shell.toml"),
            atomically: true,
            encoding: .utf8
        )
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: shell, problems: &problems))
        XCTAssertEqual(config.profile, ShellDefaults.profile)
        XCTAssertTrue(problems.contains { $0.hasPrefix("\(profile)/\(ShellStyleManifest.fileName)") }, "\(problems)")
        try write(required)
        XCTAssertNoThrow(try ShellProfiles.select(profile, in: shell))
        XCTAssertEqual(ShellConfig.load(shellDirectory: shell)?.profile, profile)
    }

    func testEveryRepositoryStyleShipsAManifestAndTablesTheAppCanRead() throws {
        let names = try ShellStyleFixture.names()
        XCTAssertFalse(names.isEmpty)
        for style in names {
            let source = try ShellStyleFixture.source(style)
            let manifest = try XCTUnwrap(ShellStyleManifest.load(in: source), style)
            XCTAssertEqual(manifest.name, style)
            let declared = try TOMLDecoder().decode(
                [String: TOMLNode].self, from: Data(contentsOf: source.appendingPathComponent("shell.toml"))
            )
            XCTAssertEqual(manifest.barEffect != nil, declared["barShader"] != nil, style)
            let tables = (try? FileManager.default.contentsOfDirectory(
                at: source.appendingPathComponent(ShellStrings.folder), includingPropertiesForKeys: nil
            )) ?? []
            for table in tables {
                let strings = try ShellStrings.load(
                    [source],
                    localization: table.deletingPathExtension().lastPathComponent
                )
                XCTAssertFalse(strings.table.isEmpty, table.path)
            }
        }
    }

    @MainActor
    func testStyleCardsShowTheManifestTitleAndSummaryInEnglish() async throws {
        try write(required)
        let strings = folder.appendingPathComponent(ShellStrings.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: true)
        try "\"\(title)\" = \"Sonde\"\n\"\(summary)\" = \"Ein Probestil.\"\n".write(
            to: strings.appendingPathComponent("\(ShellStrings.appLocalization).toml"), atomically: true,
            encoding: .utf8
        )
        let plain = "handmade"
        try FileManager.default.createDirectory(
            at: shell.appendingPathComponent(plain),
            withIntermediateDirectories: true
        )
        let configuration = ShellConfigurationCoordinator(shellDirectory: shell)
        try await configuration.ensureLoaded()
        XCTAssertEqual(configuration.styleTitle(profile), title)
        XCTAssertEqual(configuration.styleSummary(profile), summary)
        XCTAssertEqual(configuration.styleTitle(plain), ShellStyleText.title(plain))
        XCTAssertEqual(configuration.styleSummary(plain), ShellStyleText.summary(plain))
        XCTAssertEqual(configuration.styleTitle(ShellDefaults.profile), ShellStyleText.title(ShellDefaults.profile))
    }

    private func write(_ entries: [String: String], extra: String = "") throws {
        try (entries.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n") + "\n" + extra)
            .write(to: folder.appendingPathComponent(ShellStyleManifest.fileName), atomically: true, encoding: .utf8)
    }
}
