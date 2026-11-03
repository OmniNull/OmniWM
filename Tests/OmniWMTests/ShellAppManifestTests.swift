// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellAppManifestTests: XCTestCase {
    func testStrictDeclarationsPreserveComponentMetadataAndChildGeometry() throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        try fixture.write(manifest: fixture.manifest + """

        [options.greeting]
        type = "string"
        default = "Hello from the manifest"
        [capabilities]
        commands = ["focus-left"]
        files = true
        """)
        let app = try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder)
        let source = try app.source()
        XCTAssertEqual(app.title, fixture.title)
        XCTAssertEqual(app.view, fixture.view)
        XCTAssertEqual(app.contentSize, fixture.preferred)
        XCTAssertEqual(app.minimumContentSize, fixture.minimum)
        XCTAssertEqual(app.icon, "square.and.pencil")
        XCTAssertEqual(app.children["confirm"]?.kind, .sheet)
        XCTAssertEqual(app.children["preferences"]?.kind, .utility)
        for child in app.children.values {
            XCTAssertEqual(child.contentSize, fixture.childPreferred)
            XCTAssertEqual(child.minimumContentSize, fixture.childMinimum)
        }
        XCTAssertEqual(source.components.first?.options["greeting"], .string("Hello from the manifest"))
        XCTAssertEqual(source.componentDescriptors.first?.capabilities.commands, ["focus-left"])
        XCTAssertEqual(source.componentDescriptors.first?.capabilities.files, true)
        XCTAssertEqual(source.profile, "app.\(fixture.id)")
        XCTAssertEqual(source.principal?.source, ShellWidgetPrincipal.source(of: fixture.folder))
        XCTAssertTrue(source.modules.contains { $0.path == "widgets/\(fixture.id)/lib/label.luau" })
    }

    func testMainViewDefaultsToWindowAndBundledChildrenComeFromTheManifest() throws {
        let fixture = ShellAppAuthoringFixture(view: "window")
        defer { try? fixture.remove() }
        try fixture.write(manifest: fixture.manifest.replacingOccurrences(of: "view = \"window\"\n", with: ""))
        XCTAssertEqual(try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder).view, fixture.view)
        let example = try XCTUnwrap(ShellAppDefinition.example)
        let component = try ShellComponentCatalog.load(example.id, folder: example.folder, sourceFile: "init.luau")
        XCTAssertEqual(example.children, component.window?.children)
        XCTAssertEqual(example.contentSize, component.window?.contentSize)
        XCTAssertEqual(example.minimumContentSize, component.window?.minimumContentSize)
        XCTAssertEqual(Set(example.children.keys), ["confirm", "preferences"])
    }

    func testMainAndChildRejectWrongTypesUnknownKeysAndInvalidSizesWithNamedErrors() throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        let invalid: [(String, String)] = [
            (fixture.manifest.replacingOccurrences(of: "[window]", with: "[window]\nunknown = true"), "unknown"),
            (fixture.manifest.replacingOccurrences(of: "[window]", with: "[window]\nkind = 'utility'"), "kind"),
            (
                fixture.manifest.replacingOccurrences(of: "width = \(fixture.preferred.width)", with: "width = true"),
                "width"
            ),
            (
                fixture.manifest
                    .replacingOccurrences(of: "height = \(fixture.preferred.height)", with: "height = 'large'"),
                "height"
            ),
            (
                fixture.manifest.replacingOccurrences(of: "minWidth = \(fixture.minimum.width)", with: "minWidth = 0"),
                "minWidth"
            ),
            (
                fixture.manifest
                    .replacingOccurrences(of: "minHeight = \(fixture.minimum.height)", with: "minHeight = nan"),
                "minHeight"
            ),
            (
                fixture.manifest.replacingOccurrences(of: "width = \(fixture.preferred.width)", with: "width = inf"),
                "width"
            ),
            (
                fixture.manifest.replacingOccurrences(of: "height = \(fixture.preferred.height)", with: "height = -1"),
                "height"
            ),
            (
                fixture.manifest
                    .replacingOccurrences(
                        of: "width = \(fixture.preferred.width)",
                        with: "width = \(fixture.minimum.width / 2)"
                    ),
                "minWidth"
            ),
            (
                fixture.manifest
                    .replacingOccurrences(
                        of: "[window.children.confirm]",
                        with: "[window.children.confirm]\nunknown = true"
                    ),
                "confirm"
            ),
            (fixture.manifest.replacingOccurrences(of: "kind = \"sheet\"", with: "kind = 'detached'"), "confirm"),
            (
                fixture.manifest.replacingOccurrences(of: "title = \"Confirm fixture\"", with: "title = false"),
                "confirm"
            ),
            (fixture.manifest.replacingOccurrences(of: "view = \"confirm\"", with: "view = 'missing'"), "confirm"),
            (
                fixture.manifest
                    .replacingOccurrences(of: "minWidth = \(fixture.childMinimum.width)", with: "minWidth = inf"),
                "confirm"
            ),
            (
                fixture.manifest
                    .replacingOccurrences(of: "[window.children.confirm]", with: "[window.children.'bad/id']"),
                "bad/id"
            )
        ]
        for (manifest, field) in invalid {
            try fixture.write(manifest: manifest)
            XCTAssertThrowsError(try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder)) { error in
                XCTAssertTrue(error.localizedDescription.contains(fixture.id), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
            }
        }
    }

    func testMissingTablesFieldsAndSourceAreAuthoringFailures() throws {
        let fixture = ShellAppAuthoringFixture()
        defer { try? fixture.remove() }
        for (manifest, field) in [
            ("views = ['main']", "[window]"),
            ("views = ['main']\nwindow = false", "[window]"),
            ("views = ['main']\n[window]\nview = 'main'", "width"),
            (
                fixture.manifest
                    .replacingOccurrences(
                        of: "[window.children.confirm]",
                        with: "[window.children]\ninvalid = false\n[window.children.confirm]"
                    ),
                "invalid"
            ),
            (fixture.manifest.replacingOccurrences(of: "kind = \"sheet\"\n", with: ""), "kind"),
            (fixture.manifest.replacingOccurrences(of: "view = \"confirm\"\n", with: ""), "view"),
            (fixture.manifest.replacingOccurrences(of: "title = \"Confirm fixture\"\n", with: ""), "title")
        ] {
            try fixture.write(manifest: manifest)
            XCTAssertThrowsError(try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder)) { error in
                XCTAssertTrue(error.localizedDescription.contains(field), error.localizedDescription)
            }
        }
        try fixture.write()
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("init.luau"))
        XCTAssertThrowsError(try ShellAppDefinition.load(id: fixture.id, folder: fixture.folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\(fixture.id) has no init.luau"))
        }
    }
}
