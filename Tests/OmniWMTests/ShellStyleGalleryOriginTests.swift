// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testTheAddedGitHubLinksExcludeTheOfficialRepositoryAndKeepOtherReceipts() async throws {
        let context = try await originContext()
        await context.gallery.install(context.listing, replacing: false)
        XCTAssertNil(context.gallery.problem)
        let repository = try XCTUnwrap(ShellGitHubStyleSource.Repository(source: context.gallery.source.source))
        let name = context.listing.name + "-official"
        let source = "github:\(ShellGitHubStyleSource.officialRepositoryName.uppercased())@v\(context.listing.manifest.version)"
        var files = context.remote.files.filter { $0.path != ShellStyleManifest.fileName }
        files.append(ShellStyleFile(
            path: ShellStyleManifest.fileName,
            data: ShellGitHubStyleBrowseFixture.manifest(name: name), executable: false
        ))
        let previous = try await context.local.configuration.installStyle(
            ShellStylePayload(name: name, source: source, files: files), replacing: false
        )
        XCTAssertNil(previous)
        XCTAssertEqual(context.local.configuration.style(name).receipt?.source, source)
        XCTAssertEqual(context.gallery.addedRepositories, [repository])
        XCTAssertEqual(
            try ShellGitHubStyleSource
                .Repository("https://github.com/\(ShellGitHubStyleSource.officialRepositoryName)"),
            ShellGitHubStyleSource.Repository(source: source)
        )
    }

    func testTheGitHubReceiptOriginsRestoreDeduplicateAndDisappearWithTheirLastStyle() async throws {
        let context = try await originContext()
        let source = context.gallery.source.source
        let repository = try XCTUnwrap(ShellGitHubStyleSource.Repository(source: source))
        XCTAssertEqual(repository.id, "\(context.remote.owner)/\(context.remote.repository)")
        XCTAssertEqual(repository.url.absoluteString, context.remote.address)
        XCTAssertEqual(
            ShellGitHubStyleSource.Repository(source: "github:STUDIO/GLASS@another@branch"), repository
        )
        XCTAssertNil(ShellGitHubStyleSource.Repository(source: "checkout:/styles"))
        XCTAssertNil(ShellGitHubStyleSource.Repository(source: "github:not-a-repository@main"))
        XCTAssertTrue(context.gallery.addedRepositories.isEmpty)

        let sibling = context.remote.name + "-sibling"
        let payload = ShellStylePayload(name: context.listing.name, source: source, files: context.remote.files)
        let previous = try await context.local.configuration.installStyle(payload, replacing: false)
        XCTAssertNil(previous)
        var siblingFiles = payload.files.filter { $0.path != ShellStyleManifest.fileName }
        siblingFiles.append(ShellStyleFile(
            path: ShellStyleManifest.fileName,
            data: ShellGitHubStyleBrowseFixture.manifest(name: sibling), executable: false
        ))
        let siblingPrevious = try await context.local.configuration.installStyle(
            ShellStylePayload(name: sibling, source: source, files: siblingFiles), replacing: false
        )
        XCTAssertNil(siblingPrevious)
        XCTAssertEqual(context.gallery.addedRepositories, [repository])

        let configuration = ShellConfigurationCoordinator(shellDirectory: context.local.shell)
        try await configuration.ensureLoaded()
        let editor = ShellDesktopEditor(
            configuration: configuration, settings: context.local.editor.settings,
            controller: context.local.editor.controller
        )
        let reopened = ShellStyleGallery(editor: editor, source: context.gallery.source)
        XCTAssertEqual(reopened.addedRepositories, [repository])
        let newer = try await offer(context, version: nextVersion(context.listing.manifest.version))
        let browser = ShellStyleGitHubBrowser(editor: editor)
        await browser.open(repository, session: context.remote.session)
        XCTAssertNil(browser.problem)
        XCTAssertEqual(browser.gallery?.listings.first?.manifest.version, newer.listing.manifest.version)
        let reopenedSource = try XCTUnwrap(browser.gallery?.source as? ShellGitHubStyleSource)
        let expectedSource = try XCTUnwrap(newer.gallery.source as? ShellGitHubStyleSource)
        XCTAssertEqual(reopenedSource.ref, expectedSource.ref)
        await reopened.remove(context.listing.name)
        XCTAssertNil(reopened.problem)
        XCTAssertEqual(reopened.addedRepositories, [repository])
        await reopened.remove(sibling)
        XCTAssertNil(reopened.problem)
        XCTAssertTrue(reopened.addedRepositories.isEmpty)
    }

    func testTheGitHubGalleryRecognizesOneRepositoryAcrossRefsAndKeepsEqualVersionsInstalled() async throws {
        let context = try await originContext()
        let tracking = "github:\(context.remote.owner.uppercased())/\(context.remote.repository.uppercased())@older-ref"
        let previous = try await context.local.configuration.installStyle(
            ShellStylePayload(name: context.listing.name, source: tracking, files: context.remote.files),
            replacing: false
        )
        XCTAssertNil(previous)
        XCTAssertEqual(context.gallery.status(of: context.listing), .installed)
        let sameVersion = try await offer(context, version: context.listing.manifest.version, edited: true)
        XCTAssertEqual(sameVersion.gallery.status(of: sameVersion.listing), .installed)
        let requests = context.remote.requests
        await sameVersion.gallery.update(sameVersion.listing)
        XCTAssertEqual(context.remote.requests, requests)
        XCTAssertNil(sameVersion.gallery.confirming)
        let folder = context.local.shell.appendingPathComponent(context.listing.name)
        for file in context.remote.files {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(file.path)), file.data)
        }
    }

    func testTheGitHubGalleryRequiresReplacementForAnotherRepositoryAndKeepsItsBackup() async throws {
        let context = try await originContext()
        let oldSource = "github:another/collection@main"
        let marker = try XCTUnwrap(context.remote.files.first { $0.path == "lib/pieces.luau" })
        let oldData = marker.data + Data("\n".utf8)
        let oldFiles = context.remote.files.map {
            $0.path == marker.path ? ShellStyleFile(path: $0.path, data: oldData, executable: $0.executable) : $0
        }
        let previousCopy = try await context.local.configuration.installStyle(
            ShellStylePayload(name: context.listing.name, source: oldSource, files: oldFiles), replacing: false
        )
        XCTAssertNil(previousCopy)
        XCTAssertEqual(context.gallery.status(of: context.listing), .otherCopy)
        XCTAssertEqual(context.gallery.installedSource(of: context.listing.name), "another/collection")
        XCTAssertEqual(context.gallery.sourceName, "\(context.remote.owner)/\(context.remote.repository)")
        let message = context.gallery.confirmationMessage(for: context.listing)
        XCTAssertTrue(message.contains(context.gallery.installedSource(of: context.listing.name)))
        XCTAssertTrue(message.contains(context.gallery.sourceName))
        XCTAssertTrue(message.contains(ShellStyleInstaller.backupsFolder))
        let newer = try await offer(context, version: nextVersion(context.listing.manifest.version))
        XCTAssertEqual(newer.gallery.status(of: newer.listing), .otherCopy)
        let requests = context.remote.requests
        await newer.gallery.update(newer.listing)
        XCTAssertEqual(context.remote.requests, requests)
        XCTAssertNil(newer.gallery.confirming)

        await context.gallery.requestInstall(context.listing)
        XCTAssertEqual(context.gallery.confirming, context.listing)
        let folder = context.local.shell.appendingPathComponent(context.listing.name)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(marker.path)), oldData)
        await context.gallery.install(context.listing, replacing: true)
        XCTAssertNil(context.gallery.problem)
        XCTAssertEqual(context.gallery.status(of: context.listing), .installed)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(marker.path)), marker.data)
        let backups = try backupFolders(context.local.shell)
        let previous = try XCTUnwrap(backups.first)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: previous)?.source, oldSource)
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent(marker.path)), oldData)
        let expected = context.local.shell.appendingPathComponent(ShellStyleInstaller.backupsFolder, isDirectory: true)
            .appendingPathComponent(previous.lastPathComponent, isDirectory: true)
        XCTAssertEqual(expected.resolvingSymlinksInPath(), previous.resolvingSymlinksInPath())
        let notice = try XCTUnwrap(context.gallery.notice)
        XCTAssertEqual(notice, String(localized: "Your previous copy is in \(expected.path)."))
    }

    func testTheGitHubGalleryTreatsAnUnreceiptedFolderAsALocalReplacement() async throws {
        let context = try await originContext()
        await context.gallery.install(context.listing, replacing: false)
        let folder = context.local.shell.appendingPathComponent(context.listing.name)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(ShellStyleInstaller.receiptName))
        try await context.local.configuration.refresh()
        XCTAssertEqual(context.gallery.status(of: context.listing), .otherCopy)
        XCTAssertEqual(context.gallery.installedSource(of: context.listing.name), String(localized: "Local copy"))
        XCTAssertTrue(context.gallery.addedRepositories.isEmpty)
        await context.gallery.requestInstall(context.listing)
        XCTAssertEqual(context.gallery.confirming, context.listing)
        await context.gallery.install(context.listing, replacing: true)
        XCTAssertNil(context.gallery.problem)
        XCTAssertEqual(context.gallery.status(of: context.listing), .installed)
        XCTAssertNotNil(try ShellStyleInstaller.receipt(in: folder))
        XCTAssertNil(try ShellStyleInstaller.receipt(in: XCTUnwrap(backupFolders(context.local.shell).first)))
    }

    func testTheGitHubGalleryUpdatesItsOwnCopyAndAsksBeforeBackingUpLocalEdits() async throws {
        let context = try await originContext()
        await context.gallery.install(context.listing, replacing: false)
        let newer = try await offer(context, version: nextVersion(context.listing.manifest.version))
        XCTAssertEqual(newer.gallery.status(of: newer.listing), .update)
        await newer.gallery.update(newer.listing)
        XCTAssertNil(newer.gallery.problem)
        XCTAssertNil(newer.gallery.confirming)
        XCTAssertEqual(newer.gallery.status(of: newer.listing), .installed)
        let folder = context.local.shell.appendingPathComponent(context.listing.name)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: folder)?.version, newer.listing.manifest.version)

        let marker = try XCTUnwrap(context.remote.files.first { $0.path == "lib/pieces.luau" })
        let localData = marker.data + Data("\n".utf8)
        try localData.write(to: folder.appendingPathComponent(marker.path))
        let newest = try await offer(context, version: nextVersion(newer.listing.manifest.version))
        let backupsBefore = try backupFolders(context.local.shell)
        await newest.gallery.update(newest.listing)
        XCTAssertEqual(newest.gallery.confirming, newest.listing)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(marker.path)), localData)
        XCTAssertEqual(try backupFolders(context.local.shell), backupsBefore)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: folder)?.version, newer.listing.manifest.version)
        await newest.gallery.install(newest.listing, replacing: true)
        XCTAssertNil(newest.gallery.problem)
        XCTAssertEqual(newest.gallery.status(of: newest.listing), .installed)
        let newBackups = try backupFolders(context.local.shell).filter { !backupsBefore.contains($0) }
        let previous = try XCTUnwrap(newBackups.first)
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent(marker.path)), localData)
    }

    func testAFailedGitHubDownloadKeepsTheInstalledCopyAndReceiptUntouched() async throws {
        let context = try await originContext()
        await context.gallery.install(context.listing, replacing: false)
        let folder = context.local.shell.appendingPathComponent(context.listing.name)
        let receipt = try ShellStyleInstaller.receipt(in: folder)
        let newer = try await offer(context, version: nextVersion(context.listing.manifest.version))
        let missing = try XCTUnwrap(context.remote.files.last)
        context.remote.reply(Data(), at: "\(newer.raw)/\(missing.path)", status: 404)
        await newer.gallery.update(newer.listing)
        XCTAssertNotNil(newer.gallery.problem)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: folder), receipt)
        for file in context.remote.files {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(file.path)), file.data)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.local.shell.appendingPathComponent(ShellStyleInstaller.backupsFolder).path
        ))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: context.local.shell.path)
            .contains { $0.hasPrefix(".install-") })
    }

    func testAnActiveGitHubReplacementKeepsProfileSettingsAndUnsavedEditorText() async throws {
        let context = try await originContext()
        await context.gallery.install(context.listing, replacing: false)
        await context.gallery.use(context.listing.name)
        let selected = await context.local.editor.selectStyle(context.listing.name)
        XCTAssertTrue(selected)
        let color = "#123456FF"
        try await context.local.configuration.setWidgetValue(
            .string(color), widget: "omniwm", key: "iconColor", profile: context.listing.name
        )
        await context.local.editor.reload()
        let draft = await dirtyText(context.local.editor, value: "#654321FF")
        let draftBefore = context.local.editor.draft(draft)
        XCTAssertTrue(context.local.editor.hasUnsavedChanges)
        let settings = context.local.shell.appendingPathComponent("shell.toml")
        let saved = try Data(contentsOf: settings)
        let newer = try await offer(context, version: nextVersion(context.listing.manifest.version))
        await newer.gallery.update(newer.listing)
        XCTAssertNil(newer.gallery.problem)
        await context.local.editor.reload()
        XCTAssertEqual(context.local.configuration.config.profile, context.listing.name)
        XCTAssertEqual(context.local.editor.snapshot?.style.manifest?.version, newer.listing.manifest.version)
        XCTAssertEqual(context.local.editor.draft(draft), draftBefore)
        XCTAssertTrue(context.local.editor.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: settings), saved)
        await newer.gallery.remove(context.listing.name)
        XCTAssertNotNil(newer.gallery.problem)
        XCTAssertEqual(context.local.editor.pendingTransition, .style(ShellDefaults.profile))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: context.local.shell.appendingPathComponent(context.listing.name).path))
    }

    private struct OriginContext {
        let local: Fixture
        let remote: ShellGitHubStyleBrowseFixture
        let gallery: ShellStyleGallery
        let listing: ShellStyleListing
    }

    private struct OriginOffer {
        let gallery: ShellStyleGallery
        let listing: ShellStyleListing
        let raw: String
    }

    private func originContext() async throws -> OriginContext {
        let local = try await fixture()
        let remote = try ShellGitHubStyleBrowseFixture()
        addTeardownBlock { remote.session.invalidateAndCancel() }
        let browse = try await ShellGitHubStyleSource.browse(remote.address, session: remote.session)
        return try OriginContext(
            local: local, remote: remote, gallery: ShellStyleGallery(editor: local.editor, browse: browse),
            listing: XCTUnwrap(browse.listings.first)
        )
    }

    private func nextVersion(_ version: String) throws -> String {
        var components = version.split(separator: ".").compactMap { Int($0) }
        let last = try XCTUnwrap(components.indices.last)
        components[last] += 1
        return components.map(String.init).joined(separator: ".")
    }

    private func offer(_ context: OriginContext, version: String, edited: Bool = false) async throws -> OriginOffer {
        let remote = context.remote
        let commit = remote.commit + "-" + version
        let tree = remote.rootTree + "-" + version
        let raw = remote.raw.replacingOccurrences(of: remote.commit, with: commit)
        try remote.reply(["sha": commit, "commit": ["tree": ["sha": tree]]], at: remote.commitURL)
        for file in remote.files {
            var data = file.data
            if file.path == ShellStyleManifest.fileName {
                data = Data(String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: context.listing.manifest.version, with: version).utf8)
            } else if edited {
                data += Data("\n".utf8)
            }
            remote.reply(data, at: "\(raw)/\(file.path)")
        }
        let items = remote.files.map {
            remote.item(path: $0.path, mode: $0.executable ? "100755" : "100644")
        }
        try remote.reply(["tree": items, "truncated": false], at: "\(remote.api)/git/trees/\(tree)?recursive=1")
        let browse = try await ShellGitHubStyleSource.browse(remote.address, session: remote.session)
        return try OriginOffer(
            gallery: ShellStyleGallery(editor: context.local.editor, browse: browse),
            listing: XCTUnwrap(browse.listings.first), raw: raw
        )
    }

    private func backupFolders(_ shell: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: shell.appendingPathComponent(ShellStyleInstaller.backupsFolder),
            includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
    }
}
