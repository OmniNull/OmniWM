// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class LauncherApplicationTests: XCTestCase {
    #if OMNIWM_LIVE_CHECKS
        func testRealNixBundleLayoutsAliasesAndCatalogRefresh() async throws {
            guard let appPath = ProcessInfo.processInfo.environment["OMNIWM_TEST_NIX_APP"] else {
                throw MissingTestPrerequisite("Set OMNIWM_TEST_NIX_APP to a real Nix app")
            }
            let app = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
            let identifier = try XCTUnwrap(Bundle(url: app)?.bundleIdentifier)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-apps-\(UUID())")
            let applications = root.appendingPathComponent("Applications/Nix Apps")
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let installed = applications.appendingPathComponent("Alacritty.app")
            try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: app)
            XCTAssertTrue(ApplicationCatalogFilter.scannedBundlePaths(home: root.path).contains(installed.path))
            XCTAssertEqual(ApplicationCatalogFilter.resolvedBundleURL(installed.path)?.path, app.path)
            let service = ApplicationCatalogService()
            let first = expectation(description: "Nix symlink catalog published")
            service.onCatalogChanged = { first.fulfill() }
            service.refreshIfNeeded(refreshMetadata: true, extraFolders: [applications.path])
            await fulfillment(of: [first], timeout: failureBound)
            let result = try XCTUnwrap(service.browse(chip: nil).flatMap(\.items)
                .first { $0.bundleIdentifier == identifier })
            XCTAssertEqual(result.id, installed.path)
            XCTAssertEqual(result.bundleURL.path, installed.path)

            try FileManager.default.removeItem(at: installed)
            let alias = applications.appendingPathComponent("Alacritty Alias.app")
            let bookmark = try app.bookmarkData(
                options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: alias)
            XCTAssertEqual(ApplicationCatalogFilter.resolvedBundleURL(alias.path)?.path, app.path)
            let second = expectation(description: "Alias refreshed independently of LS fingerprint")
            service.onCatalogChanged = { second.fulfill() }
            service.refreshIfNeeded(refreshMetadata: true, extraFolders: [applications.path])
            await fulfillment(of: [second], timeout: failureBound)
            let aliasResult = try XCTUnwrap(service.browse(chip: nil).flatMap(\.items)
                .first { $0.bundleIdentifier == identifier })
            XCTAssertEqual(aliasResult.id, alias.path)
            XCTAssertTrue(aliasResult.bundleURL.isFileURL)
            XCTAssertEqual(aliasResult.bundleURL.path, app.path)

            let linkedFolder = root.appendingPathComponent("Applications/Home Manager Apps")
            try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: applications)
            XCTAssertTrue(ApplicationCatalogFilter.scannedBundlePaths(home: root.path)
                .contains(linkedFolder.appendingPathComponent(alias.lastPathComponent).path))
            let customRoot = root.appendingPathComponent("Custom Apps")
            try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
            let customApp = customRoot.appendingPathComponent("Custom.app")
            try FileManager.default.createSymbolicLink(at: customApp, withDestinationURL: app)
            XCTAssertTrue(ApplicationCatalogFilter.scannedBundlePaths(home: root.path, extraFolders: [customRoot.path])
                .contains(customApp.path))
        }
    #endif

    func testFolderScanFindsFinderAliasesWithoutAnAppExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-alias-\(UUID())")
        let folder = root.appendingPathComponent("Apps")
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = ["CFBundleIdentifier": "com.omniwm.tests.fixture-\(UUID().uuidString)", "CFBundleName": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let alias = folder.appendingPathComponent("Fixture alias")
        try URL.writeBookmarkData(
            app.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
            to: alias
        )
        let note = folder.appendingPathComponent("notes")
        try Data("plain".utf8).write(to: note)
        let scanned = ApplicationCatalogFilter.scannedBundlePaths(home: root.path, extraFolders: [folder.path])
        XCTAssertTrue(scanned.contains(alias.path))
        XCTAssertFalse(scanned.contains(note.path))
        XCTAssertEqual(ApplicationCatalogFilter.resolvedBundleURL(alias.path)?.lastPathComponent, "Fixture.app")
    }

    #if OMNIWM_LIVE_CHECKS
        func testRealHomebrewCaskIsDiscoverable() throws {
            let app = "/Applications/Ghostty.app"
            XCTAssertNotNil(Bundle(path: app)?.bundleIdentifier)
            XCTAssertTrue(ApplicationCatalogFilter
                .scannedBundlePaths(home: FileManager.default.homeDirectoryForCurrentUser.path).contains(app))
        }
    #endif
}
