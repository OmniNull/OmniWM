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
        XCTAssertEqual(gallery.status(of: style), .otherCopy)

        await gallery.install(style, replacing: true)
        XCTAssertNil(gallery.problem)
        XCTAssertEqual(gallery.status(of: style), .installed)
        XCTAssertTrue(try XCTUnwrap(gallery.notice).contains(ShellStyleInstaller.backupsFolder))

        await gallery.use(style.name)
        XCTAssertTrue(gallery.isActive(style.name))
        await gallery.remove(style.name)
        XCTAssertNil(gallery.problem)
        XCTAssertEqual(fixture.configuration.config.profile, ShellDefaults.profile)
        XCTAssertEqual(fixture.editor.selectedStyle, ShellDefaults.profile)
        XCTAssertEqual(fixture.editor.snapshot?.config.profile, ShellDefaults.profile)
        XCTAssertEqual(gallery.status(of: style), .available)
        let settings = try String(contentsOf: fixture.shell.appendingPathComponent("shell.toml"), encoding: .utf8)
        XCTAssertTrue(settings.contains("[profiles.\(style.name).workspaceBar]"), settings)
    }

    func testTheGalleryUpdatesAnUnchangedStyleAndAsksBeforeReplacingChangedFiles() async throws {
        let fixture = try await fixture()
        let gallery = ShellStyleGallery(
            editor: fixture.editor, source: ShellStyleRepository(folder: ShellStyleFixture.directory)
        )
        await gallery.load()
        let style = try XCTUnwrap(gallery.listings.first { $0.name != fixture.editor.selectedStyle })
        await gallery.install(style, replacing: true)
        XCTAssertEqual(gallery.status(of: style), .installed)
        let newer = try newerListing(of: style)
        XCTAssertEqual(gallery.status(of: newer), .update)

        await gallery.update(newer)
        XCTAssertNil(gallery.confirming)
        XCTAssertNil(gallery.problem)
        XCTAssertTrue(try XCTUnwrap(gallery.notice).contains(ShellStyleInstaller.backupsFolder))

        let manifest = fixture.shell.appendingPathComponent(style.name)
            .appendingPathComponent(ShellStyleManifest.fileName)
        let edited = try Data(contentsOf: manifest) + Data("\n".utf8)
        try edited.write(to: manifest)
        await gallery.update(newer)
        XCTAssertEqual(gallery.confirming, newer)
        XCTAssertEqual(try Data(contentsOf: manifest), edited)
    }

    private func newerListing(of listing: ShellStyleListing) throws -> ShellStyleListing {
        let folder = ShellStyleFixture.directory.appendingPathComponent(listing.name, isDirectory: true)
        var components = listing.manifest.version.split(separator: ".").compactMap { Int($0) }
        components[components.count - 1] += 1
        let version = components.map(String.init).joined(separator: ".")
        let text = try String(contentsOf: folder.appendingPathComponent(ShellStyleManifest.fileName), encoding: .utf8)
            .replacingOccurrences(of: "version = \"\(listing.manifest.version)\"", with: "version = \"\(version)\"")
        return try ShellStyleListing(
            name: listing.name,
            manifest: ShellStyleManifest.parse(Data(text.utf8)),
            folder: folder
        )
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
