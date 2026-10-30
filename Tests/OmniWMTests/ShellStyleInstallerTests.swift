// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CryptoKit
@testable import OmniWM
import XCTest

final class ShellStyleInstallerTests: XCTestCase {
    private var root: URL!
    private let day = "2026-10-30"
    private let repository = ShellStyleRepository(folder: ShellStyleFixture.directory)

    private var shell: URL {
        root.appendingPathComponent("shell", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellStyleInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testEveryRepositoryStyleInstallsWithItsBytesModesAndReceipt() throws {
        let listings = try repository.styles()
        XCTAssertEqual(listings.map(\.name), try ShellStyleFixture.names())
        for listing in listings {
            let files = try repository.files(of: listing.name)
            try install(listing, files: files)
            let target = shell.appendingPathComponent(listing.name)
            for file in files {
                let url = target.appendingPathComponent(file.path)
                XCTAssertEqual(try Data(contentsOf: url), file.data, file.path)
                XCTAssertEqual(FileManager.default.isExecutableFile(atPath: url.path), file.executable, file.path)
            }
            let receipt = try XCTUnwrap(try ShellStyleInstaller.receipt(in: target))
            XCTAssertEqual(receipt.version, listing.manifest.version)
            XCTAssertEqual(receipt.source, repository.source)
            XCTAssertEqual(receipt.files, Dictionary(uniqueKeysWithValues: files.map {
                ($0.path, SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())
            }))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path)
                .contains(ShellStyleRepository.previewsFolder))
        }
        XCTAssertTrue(entries(in: shell).allSatisfy { !$0.hasPrefix(".install-") })
        XCTAssertTrue(entries(in: shell).allSatisfy { !$0.hasPrefix(ShellStyleInstaller.backupsFolder) })
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile] + listings.map(\.name))
    }

    func testAnExistingFolderIsReplacedOnlyOnRequestAndKeptAsABackup() throws {
        let listing = try XCTUnwrap(repository.styles().first)
        let files = try repository.files(of: listing.name)
        let mine = shell.appendingPathComponent("\(listing.name)/shell.toml")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let edits = "theme = \"mine\"\n"
        try edits.write(to: mine, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try install(listing, files: files))
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), edits)

        try install(listing, files: files, replacing: true)
        let backup = shell.appendingPathComponent("\(ShellStyleInstaller.backupsFolder)/\(listing.name)-\(day)")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("shell.toml"), encoding: .utf8), edits)
        XCTAssertNotNil(try ShellStyleInstaller.receipt(in: shell.appendingPathComponent(listing.name)))

        try install(listing, files: files, replacing: true)
        let second = shell.appendingPathComponent("\(ShellStyleInstaller.backupsFolder)/\(listing.name)-\(day)-2")
        XCTAssertNotNil(try ShellStyleInstaller.receipt(in: second))

        try ShellStyleInstaller.remove(listing.name, from: shell, day: day)
        XCTAssertEqual(ShellProfiles.names(in: shell), [ShellDefaults.profile])
        let third = shell.appendingPathComponent("\(ShellStyleInstaller.backupsFolder)/\(listing.name)-\(day)-3")
        XCTAssertNotNil(try ShellStyleInstaller.receipt(in: third))
        XCTAssertThrowsError(try ShellStyleInstaller.remove(listing.name, from: shell, day: day))
    }

    func testInvalidStylePayloadsAreRefusedBeforeAnythingIsWritten() throws {
        let manifest = probeManifest()
        XCTAssertNoThrow(try ShellStyleInstaller.validate(
            ShellStylePayload(name: "probe", source: repository.source, files: [manifest])
        ))
        func file(_ path: String) -> ShellStyleFile {
            ShellStyleFile(path: path, data: Data(), executable: false)
        }
        let cases: [(String, [ShellStyleFile])] = [
            ("parent", [manifest, file("../escape.luau")]),
            ("absolute", [manifest, file("/etc/escape.luau")]),
            ("empty component", [manifest, file("widgets//init.luau")]),
            ("hidden", [manifest, file(".hidden")]),
            ("receipt", [manifest, file(ShellStyleInstaller.receiptName)]),
            ("backslash", [manifest, file("widgets\\init.luau")]),
            ("case duplicate", [manifest, file("lib/Look.luau"), file("lib/look.luau")]),
            ("file and folder", [manifest, file("lib"), file("lib/look.luau")]),
            ("no manifest", [file("shell.toml")])
        ]
        for (label, files) in cases {
            XCTAssertThrowsError(
                try ShellStyleInstaller.install(
                    ShellStylePayload(name: "probe", source: repository.source, files: files),
                    into: shell, replacing: false, day: day
                ),
                label
            )
        }
        for name in ["", ".hidden", ShellDefaults.profile, ShellStrings.folder, "a/b"] {
            XCTAssertThrowsError(
                try ShellStyleInstaller.validate(ShellStylePayload(
                    name: name,
                    source: repository.source,
                    files: [manifest]
                )),
                name
            )
        }
        XCTAssertEqual(entries(in: shell), [])
    }

    func testTheCheckoutIsFoundOnlyFromABuildFolderNextToItsStyles() throws {
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let styles = checkout.appendingPathComponent("styles", isDirectory: true)
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try Data().write(to: checkout.appendingPathComponent("Package.swift"))
        let built = checkout.appendingPathComponent(".build/release/OmniWM")
        XCTAssertEqual(
            ShellStyleRepository.checkout(executable: built)?.folder.standardizedFileURL,
            styles.standardizedFileURL
        )
        XCTAssertNil(ShellStyleRepository
            .checkout(executable: checkout.appendingPathComponent("OmniWM.app/Contents/MacOS/OmniWM")))
        XCTAssertNil(ShellStyleRepository.checkout(executable: root.appendingPathComponent(".build/release/OmniWM")))
        XCTAssertNil(ShellStyleRepository.checkout(executable: nil))
    }

    func testRepositoryFilesSkipPreviewsAndRefuseLinks() throws {
        let styles = root.appendingPathComponent("styles", isDirectory: true)
        let style = styles.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(
            at: style.appendingPathComponent(ShellStyleRepository.previewsFolder), withIntermediateDirectories: true
        )
        let manifest = "format = \(ShellStyleManifest.format)\nname = \"probe\"\nversion = \"1.0.0\"\n"
            + "api = \(ShellStyleManifest.api)\ntitle = \"Probe\"\nsummary = \"A probe.\"\n"
        try manifest.write(
            to: style.appendingPathComponent(ShellStyleManifest.fileName),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: style.appendingPathComponent("\(ShellStyleRepository.previewsFolder)/bar.png"))
        try Data().write(to: style.appendingPathComponent(".DS_Store"))
        let probe = ShellStyleRepository(folder: styles)
        XCTAssertEqual(try probe.styles().map(\.name), ["probe"])
        XCTAssertEqual(try probe.files(of: "probe").map(\.path), [ShellStyleManifest.fileName])
        try FileManager.default.createSymbolicLink(
            at: style.appendingPathComponent("linked.luau"),
            withDestinationURL: style.appendingPathComponent("shell.toml")
        )
        XCTAssertThrowsError(try probe.files(of: "probe"))
    }

    func testABackupsFileStopsAReplacementBeforeAnythingIsPublished() throws {
        let listing = try XCTUnwrap(repository.styles().first)
        let files = try repository.files(of: listing.name)
        try install(listing, files: files)
        let installed = try XCTUnwrap(try ShellStyleInstaller.receipt(in: shell.appendingPathComponent(listing.name)))
        try Data().write(to: shell.appendingPathComponent(ShellStyleInstaller.backupsFolder))
        XCTAssertThrowsError(try install(listing, files: files, replacing: true))
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: shell.appendingPathComponent(listing.name)), installed)
        XCTAssertTrue(entries(in: shell).allSatisfy { !$0.hasPrefix(".install-") })
    }

    func testAPublishedReplacementReportsWhereThePreviousCopyStaysWhenItsBackupCannotMove() throws {
        let listing = try XCTUnwrap(repository.styles().first)
        let files = try repository.files(of: listing.name)
        let mine = shell.appendingPathComponent("\(listing.name)/shell.toml")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let edits = "theme = \"mine\"\n"
        try edits.write(to: mine, atomically: true, encoding: .utf8)
        let backups = shell.appendingPathComponent(ShellStyleInstaller.backupsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path) }

        let previous = try XCTUnwrap(try install(listing, files: files, replacing: true))
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("shell.toml"), encoding: .utf8), edits)
        XCTAssertNotEqual(previous.deletingLastPathComponent().standardizedFileURL, backups.standardizedFileURL)
        XCTAssertNotNil(try ShellStyleInstaller.receipt(in: shell.appendingPathComponent(listing.name)))
    }

    func testAnUnreadableFolderStopsThePayloadBeforeAnythingIsInstalled() throws {
        let listing = try XCTUnwrap(repository.styles().first)
        let styles = root.appendingPathComponent("styles", isDirectory: true)
        try FileManager.default.copyItem(at: repository.folder, to: styles)
        let library = styles.appendingPathComponent("\(listing.name)/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path) }
        XCTAssertThrowsError(try ShellStyleRepository(folder: styles).payload(for: listing))
        XCTAssertEqual(entries(in: shell), [])
    }

    func testThePayloadsOwnManifestDecidesItsNameVersionAndCompatibility() throws {
        let version = "2.3.4"
        func payload(_ changes: [String: String] = [:]) -> ShellStylePayload {
            ShellStylePayload(
                name: "probe",
                source: repository.source,
                files: [probeManifest(version: version, changes)]
            )
        }
        try ShellStyleInstaller.install(payload(), into: shell, replacing: false, day: day)
        XCTAssertEqual(try ShellStyleInstaller.receipt(in: shell.appendingPathComponent("probe"))?.version, version)
        for (key, value) in [("name", "\"other\""), ("api", "\(ShellStyleManifest.api + 1)")] {
            XCTAssertThrowsError(try ShellStyleInstaller.validate(payload([key: value])), key)
        }
    }

    @discardableResult
    private func install(
        _ listing: ShellStyleListing, files: [ShellStyleFile], replacing: Bool = false
    ) throws -> URL? {
        try ShellStyleInstaller.install(
            ShellStylePayload(name: listing.name, source: repository.source, files: files),
            into: shell, replacing: replacing, day: day
        )
    }

    private func probeManifest(version: String = "1.0.0", _ changes: [String: String] = [:]) -> ShellStyleFile {
        let entries = [
            "format": "\(ShellStyleManifest.format)", "name": "\"probe\"", "version": "\"\(version)\"",
            "api": "\(ShellStyleManifest.api)", "title": "\"Probe\"", "summary": "\"A probe.\""
        ].merging(changes) { $1 }
        let text = entries.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        return ShellStyleFile(path: ShellStyleManifest.fileName, data: Data(text.utf8), executable: false)
    }

    private func entries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            $0 != ShellDefaults.profile && $0 != "shell.toml"
        }.sorted()
    }
}
