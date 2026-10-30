// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testTheGalleryReplacesUsesAndRemovesAStyleWhileTheEditorFollows() async throws {
        let fixture = try await fixture()
        let gallery = ShellStyleGallery(
            editor: fixture.editor, source: ShellStyleRepository(folder: ShellStyleFixture.directory)
        )
        await gallery.load()
        XCTAssertNil(gallery.problem)
        let style = try XCTUnwrap(gallery.listings.first { $0.name == fixture.editor.selectedStyle })
        XCTAssertEqual(gallery.status(of: style.name), .otherCopy)

        await gallery.install(style, replacing: true)
        XCTAssertNil(gallery.problem)
        XCTAssertEqual(gallery.status(of: style.name), .installed)
        XCTAssertTrue(try XCTUnwrap(gallery.notice).contains(ShellStyleInstaller.backupsFolder))

        await gallery.use(style.name)
        XCTAssertTrue(gallery.isActive(style.name))
        await gallery.remove(style.name)
        XCTAssertNil(gallery.problem)
        XCTAssertEqual(fixture.configuration.config.profile, ShellDefaults.profile)
        XCTAssertEqual(fixture.editor.selectedStyle, ShellDefaults.profile)
        XCTAssertEqual(fixture.editor.snapshot?.config.profile, ShellDefaults.profile)
        XCTAssertEqual(gallery.status(of: style.name), .available)
        let settings = try String(contentsOf: fixture.shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        XCTAssertTrue(settings.contains("[profiles.\(style.name).workspaceBar]"), settings)
    }

    func testTheGalleryKeepsAStyleWhoseEditsAreUnsaved() async throws {
        let fixture = try await fixture()
        let gallery = ShellStyleGallery(
            editor: fixture.editor, source: ShellStyleRepository(folder: ShellStyleFixture.directory)
        )
        let style = fixture.editor.selectedStyle
        _ = await dirtyText(fixture.editor)
        await gallery.remove(style)
        XCTAssertNotNil(gallery.problem)
        XCTAssertEqual(fixture.editor.selectedStyle, style)
        XCTAssertEqual(fixture.editor.pendingTransition, .style(fixture.configuration.config.profile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.shell.appendingPathComponent(style).path))
    }
}
