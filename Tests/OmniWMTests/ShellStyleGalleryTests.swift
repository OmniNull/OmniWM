// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
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

    func testGitHubBrowseWritesNothingUntilInstallAndUsesTheExistingInstaller() async throws {
        let fixture = try await fixture()
        let remote = try ShellGitHubStyleBrowseFixture()
        addTeardownBlock { remote.session.invalidateAndCancel() }
        let browser = ShellStyleGitHubBrowser(editor: fixture.editor)
        browser.address = remote.address
        browser.adding = true
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.shell.path).sorted()
        let settings = fixture.shell.appendingPathComponent("shell.toml")
        let savedSettings = try Data(contentsOf: settings)

        await browser.load(session: remote.session)
        XCTAssertFalse(browser.loading)
        XCTAssertFalse(browser.adding)
        XCTAssertNil(browser.problem)
        let gallery = try XCTUnwrap(browser.gallery)
        let listing = try XCTUnwrap(gallery.listings.first)
        XCTAssertEqual(listing.name, remote.name)
        XCTAssertEqual(gallery.repositoryName, "\(remote.owner)/\(remote.repository)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.shell.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: settings), savedSettings)

        await gallery.requestInstall(listing)
        XCTAssertEqual(gallery.confirming, listing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shell.appendingPathComponent(listing.name).path))
        await gallery.install(listing, replacing: false)
        XCTAssertNil(gallery.problem)
        XCTAssertEqual(gallery.status(of: listing), .installed)
        XCTAssertEqual(try Data(contentsOf: settings), savedSettings)
        let installed = fixture.shell.appendingPathComponent(listing.name)
        let source = try XCTUnwrap(gallery.source as? ShellGitHubStyleSource)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: installed)?.source, source.source)
        for file in remote.files {
            XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(file.path)), file.data, file.path)
        }
        await gallery.use(listing.name)
        XCTAssertNil(gallery.problem)
        XCTAssertTrue(gallery.isActive(listing.name))
        browser.back()
        XCTAssertNil(browser.gallery)
    }

    func testLeavingGitHubBrowseCancelsItsRequestAndCannotReopenThePage() async throws {
        let fixture = try await fixture()
        let browser = ShellStyleGitHubBrowser(editor: fixture.editor)
        let held = heldGitHub()
        browser.address = "https://github.com/author/held"
        browser.adding = true
        let load = Task { await browser.load(session: held.session) }
        await fulfillment(of: [held.started], timeout: Self.githubRequestDeadline)
        browser.back()
        await load.value
        await fulfillment(of: [held.stopped], timeout: Self.githubRequestDeadline)
        XCTAssertNil(browser.gallery)
        XCTAssertNil(browser.problem)
        XCTAssertFalse(browser.loading)
        XCTAssertFalse(browser.adding)
    }

    func testANewerGitHubLoadOwnsThePageAfterCancellingTheOldLoad() async throws {
        let fixture = try await fixture()
        let browser = ShellStyleGitHubBrowser(editor: fixture.editor)
        let held = heldGitHub()
        browser.address = "https://github.com/author/held"
        let old = Task { await browser.load(session: held.session) }
        await fulfillment(of: [held.started], timeout: Self.githubRequestDeadline)
        let remote = try ShellGitHubStyleBrowseFixture()
        addTeardownBlock { remote.session.invalidateAndCancel() }
        browser.address = remote.address
        await browser.load(session: remote.session)
        await old.value
        await fulfillment(of: [held.stopped], timeout: Self.githubRequestDeadline)
        XCTAssertEqual(browser.gallery?.repositoryName, "\(remote.owner)/\(remote.repository)")
        XCTAssertNil(browser.problem)
        XCTAssertFalse(browser.loading)
    }

    func testAnInvalidGitHubURLStaysInTheFormAndCanBeCorrected() async throws {
        let fixture = try await fixture()
        let browser = ShellStyleGitHubBrowser(editor: fixture.editor)
        let remote = try ShellGitHubStyleBrowseFixture()
        addTeardownBlock { remote.session.invalidateAndCancel() }
        browser.adding = true
        browser.address = "https://example.com/author/styles"
        await browser.load(session: remote.session)
        XCTAssertNotNil(browser.problem)
        XCTAssertNil(browser.gallery)
        XCTAssertTrue(browser.adding)
        XCTAssertFalse(browser.loading)
        browser.address = remote.address
        await browser.load(session: remote.session)
        XCTAssertNil(browser.problem)
        XCTAssertNotNil(browser.gallery)
        XCTAssertFalse(browser.adding)
    }

    private static let githubRequestDeadline: TimeInterval = 20

    private struct HeldGitHubRequest {
        let session: URLSession
        let started: XCTestExpectation
        let stopped: XCTestExpectation
    }

    private func heldGitHub() -> HeldGitHubRequest {
        let started = expectation(description: "GitHub metadata request started")
        let stopped = expectation(description: "GitHub metadata request cancelled")
        HeldStyleGitHub.callbacks
            .withLock { $0 = .init(started: { started.fulfill() }, stopped: { stopped.fulfill() }) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldStyleGitHub.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return HeldGitHubRequest(session: session, started: started, stopped: stopped)
    }
}

private final class HeldStyleGitHub: URLProtocol {
    struct Callbacks: Sendable {
        var started: @Sendable () -> Void = {}
        var stopped: @Sendable () -> Void = {}
    }

    static let callbacks = Mutex(Callbacks())
    private let active = Mutex(Callbacks())

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let callbacks = Self.callbacks.withLock { $0 }
        active.withLock { $0 = callbacks }
        callbacks.started()
    }

    override func stopLoading() {
        active.withLock { $0.stopped }()
    }
}
