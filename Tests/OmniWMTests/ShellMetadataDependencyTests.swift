// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellMetadataDependencyTests: XCTestCase {
    func testWidgetLoadsFormAndStringsAsMetadataAndFingerprintsTheirChanges() async throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let widget = "probe"
        let package = "widgets/\(widget)"
        let main = "\(package)/init.luau"
        let settings = "\(package)/settings.luau"
        let strings = "strings/\(ShellStrings.fallbackLocalization).luau"
        let modules = ["\(package)/component.luau", "\(package)/helpers/colors.luau", "lib/settings.luau"]
        for path in [main] + modules { try fixture.writeFile("return {}", path: path) }
        for name in ["style.luau", "component.manifest.luau", "strings/en.luau", "widgets/child/settings.luau"] {
            try fixture.writeFile("return {}", path: "\(package)/\(name)")
        }
        func form(_ host: String) -> String {
            "return { capabilities = { network = { '\(host)' } } }"
        }
        func translation(_ title: String) -> String {
            "return { title = '\(title)' }"
        }
        let firstHost = "initial.example"
        let changedHost = "updated-host.example"
        let firstTitle = "Initial"
        let changedTitle = "Updated title"
        try fixture.writeFile(form(firstHost), path: settings)
        try fixture.writeFile(translation(firstTitle), path: strings)
        let input = ShellWidgetSourceLoader.Input(
            name: widget, shellDirectory: fixture.folder, sourceURL: fixture.folder.appendingPathComponent(main),
            directories: [fixture.folder], profile: ShellDefaults.profile
        )
        let loader = ShellWidgetSourceLoader()
        let initial = try await loader.prepare(input)
        XCTAssertEqual(Set(initial.source.modules.map(\.path)), Set(modules))
        XCTAssertEqual(initial.source.network, [firstHost])
        XCTAssertEqual(initial.source.strings["title"], firstTitle)
        try fixture.writeFile(form(changedHost), path: settings)
        let formChanged = try await loader.prepare(input)
        XCTAssertNotEqual(initial.fingerprint, formChanged.fingerprint)
        XCTAssertEqual(formChanged.source.network, [changedHost])
        try fixture.writeFile(translation(changedTitle), path: strings)
        let stringsChanged = try await loader.prepare(input)
        XCTAssertNotEqual(formChanged.fingerprint, stringsChanged.fingerprint)
        XCTAssertEqual(stringsChanged.source.strings["title"], changedTitle)
        XCTAssertEqual(Set(stringsChanged.source.modules.map(\.path)), Set(modules))
    }

    func testHostedAppKeepsItsEntryPointAndLibraryWhileExcludingMetadata() throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        try fixture.write()
        try fixture.writeFile("return 'local helper'", path: "lib/settings.luau")
        for path in [
            "settings.luau",
            "style.luau",
            "widgets/child/settings.luau",
            "widgets/child/component.manifest.luau"
        ] {
            try fixture.writeFile("return {}", path: path)
        }
        let title = "Hosted app title"
        try fixture.writeFile(
            "return { title = '\(title)' }",
            path: "strings/\(ShellStrings.fallbackLocalization).luau"
        )
        let source = try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder).source()
        XCTAssertEqual(source.strings["title"], title)
        let expected = ["component.luau", "lib/label.luau", "lib/settings.luau"].map { "widgets/\(fixture.id)/\($0)" }
        XCTAssertEqual(Set(source.modules.map(\.path)), Set(expected))
    }
}
