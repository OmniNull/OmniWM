// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsFilePersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let configDirectory: URL
        let dotfilesDirectory: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testPersistenceReleasesWithAndWithoutInitialWatchers() throws {
        for startWatching in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try SettingsLuauDocument.initialSource(.defaults()).write(to: settingsURL(in: fixture))
            weak var releasedPersistence: SettingsFilePersistence?

            do {
                let persistence = SettingsFilePersistence(
                    directory: fixture.configDirectory,
                    startWatching: startWatching,
                    deferSaves: false
                )
                releasedPersistence = persistence
                XCTAssertNotNil(releasedPersistence)
            }

            XCTAssertNil(releasedPersistence)
        }
    }

    @MainActor
    func testSaveThroughAbsoluteSymlinkPreservesLinkTargetAndPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("omniwm.luau", isDirectory: false)
        try SettingsLuauDocument.initialSource(SettingsExport.defaults()).write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: targetURL.path)

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        var export = persistence.load()
        export.gaps.size += 1
        try persistence.saveImmediately(export)

        try assertSymlink(at: linkURL, destination: targetURL.path)
        XCTAssertEqual(try SettingsLuauDocument(Data(contentsOf: targetURL)).export.gaps.size, export.gaps.size)
        let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    @MainActor
    func testSaveThroughRelativeSymlinkUsesFilesystemResolution() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let storeURL = fixture.root.appendingPathComponent("store", isDirectory: true)
        let nestedURL = storeURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let targetURL = storeURL.appendingPathComponent("omniwm.luau", isDirectory: false)
        try SettingsLuauDocument.initialSource(SettingsExport.defaults()).write(to: targetURL)

        let directoryLinkURL = fixture.root.appendingPathComponent("dotfiles-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: directoryLinkURL, withDestinationURL: nestedURL)

        let destination = "../dotfiles-link/../omniwm.luau"
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)

        let persistence = makePersistence(in: fixture)
        var export = persistence.load()
        export.gaps.size += 1
        try persistence.saveImmediately(export)

        try assertSymlink(at: linkURL, destination: destination)
        XCTAssertEqual(try SettingsLuauDocument(Data(contentsOf: targetURL)).export.gaps.size, export.gaps.size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("omniwm.luau").path))
    }

    @MainActor
    func testDanglingSettingsSymlinkBlocksUntilRestartAfterTargetAppears() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let targetURL = fixture.dotfilesDirectory.appendingPathComponent("missing.toml", isDirectory: false)
        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let persistence = makePersistence(in: fixture)
        let outcome = persistence.loadOutcome()
        guard let notice = outcome.notice, case let .persistenceWriteBlocked(reason) = notice else {
            return XCTFail("Expected dangling symlink to block settings writes")
        }
        XCTAssertEqual(
            reason,
            "The settings symlink at \(linkURL.path) points to a missing file; "
                + "create its target or replace the symlink, then restart OmniWM."
        )
        XCTAssertEqual(outcome.export, SettingsExport.defaults())
        XCTAssertTrue(persistence.settingsWritesBlocked)

        var appeared = SettingsExport.defaults()
        appeared.gaps.size = 37
        let appearedData = try SettingsLuauDocument.initialSource(appeared)
        try appearedData.write(to: targetURL)
        XCTAssertThrowsError(try persistence.saveImmediately(.defaults())) { error in
            guard let persistenceError = error as? SettingsFilePersistenceError,
                  case .writesBlocked = persistenceError
            else {
                return XCTFail("Expected writesBlocked, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), appearedData)

        let restarted = makePersistence(in: fixture)
        let restartedOutcome = restarted.loadOutcome()
        XCTAssertEqual(restartedOutcome.export, appeared)
        XCTAssertNil(restartedOutcome.notice)
        XCTAssertFalse(restarted.settingsWritesBlocked)

        try assertSymlink(at: linkURL, destination: targetURL.path)
    }

    @MainActor
    func testCrossDirectorySymlinkCycleThrowsELOOPAndPreservesLinks() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let otherDirectory = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        let settingsDestination = "../other/link2"
        let otherDestination = "../config/\(SettingsFilePersistence.fileName)"
        let linkURL = settingsURL(in: fixture)
        let otherLinkURL = otherDirectory.appendingPathComponent("link2", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: settingsDestination)
        try FileManager.default.createSymbolicLink(atPath: otherLinkURL.path, withDestinationPath: otherDestination)

        let persistence = makePersistence(in: fixture)
        assertPOSIXError(.ELOOP) {
            try persistence.saveImmediately(SettingsExport.defaults())
        }

        try assertSymlink(at: linkURL, destination: settingsDestination)
        try assertSymlink(at: otherLinkURL, destination: otherDestination)
    }

    @MainActor
    func testSymlinkToDirectoryThrowsEFTYPEAndPreservesLink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let linkURL = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fixture.dotfilesDirectory)

        let persistence = makePersistence(in: fixture)
        assertPOSIXError(.EFTYPE) {
            try persistence.saveImmediately(SettingsExport.defaults())
        }

        try assertSymlink(at: linkURL, destination: fixture.dotfilesDirectory.path)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dotfilesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testInvalidSymlinkTargetRemainsUnchangedThroughARejectedSave() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let target = fixture.dotfilesDirectory.appendingPathComponent("custom.luau")
        let invalid = Data("return { gaps = { size = false } }".utf8)
        try invalid.write(to: target)
        let link = settingsURL(in: fixture)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let persistence = makePersistence(in: fixture)
        let outcome = persistence.loadOutcome()
        XCTAssertNil(outcome.export)
        XCTAssertNotNil(outcome.notice)
        XCTAssertThrowsError(try persistence.saveImmediately(.defaults()))
        XCTAssertEqual(try Data(contentsOf: target), invalid)
        try assertSymlink(at: link, destination: target.path)
    }

    @MainActor
    func testDeferredSaveDoesNotOverwriteAcceptedExternalRestore() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let persistence = SettingsFilePersistence(
            directory: fixture.configDirectory,
            startWatching: false,
            deferSaves: true
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: fixture.root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )
        var restored = settings.toExport()
        restored.gaps.outer.top = 41

        settings.gaps.size = 20
        try SettingsLuauDocument.initialSource(restored).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.gaps.outerGapTop, 41)
        XCTAssertEqual(settings.gaps.size, restored.gaps.size)

        settings.flushNow()

        XCTAssertEqual(try SettingsLuauDocument(Data(contentsOf: persistence.fileURL)).export, restored)
        XCTAssertEqual(settings.toExport(), restored)
    }

    @MainActor
    func testStartupEmptyFileIsLeftUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        try Data().write(to: settingsURL(in: fixture))

        let loaded = makePersistence(in: fixture).load()

        XCTAssertEqual(loaded, SettingsExport.defaults())
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    @MainActor
    func testStartupStrictDecodeFailureIsLeftUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let invalidData = Data("return { focus = { raiseOnMouseFocus = 'sometimes' } }".utf8)
        try invalidData.write(to: settingsURL(in: fixture))

        let outcome = makePersistence(in: fixture).loadOutcome()

        XCTAssertNil(outcome.export)
        guard let notice = outcome.notice, case let .invalidRejected(reason) = notice else {
            return XCTFail("Expected the invalid startup file to be rejected without recovery")
        }
        XCTAssertTrue(reason.contains("raiseOnMouseFocus"))
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), invalidData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    @MainActor
    func testUnreadableLiveFileDoesNotFallBackToCanonicalRewrite() throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL(in: fixture).path
            )
            fixture.remove()
        }

        let originalData = try SettingsLuauDocument.initialSource(.defaults())
        try originalData.write(to: settingsURL(in: fixture))
        let persistence = makePersistence(in: fixture)
        var desired = persistence.load()
        desired.gaps.size += 3
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settingsURL(in: fixture).path)

        XCTAssertThrowsError(try persistence.saveImmediately(desired))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL(in: fixture).path)
        XCTAssertEqual(try Data(contentsOf: settingsURL(in: fixture)), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL(in: fixture).path))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSettingsSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let dotfilesDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
        return Fixture(root: root, configDirectory: configDirectory, dotfilesDirectory: dotfilesDirectory)
    }

    @MainActor
    private func makePersistence(in fixture: Fixture) -> SettingsFilePersistence {
        SettingsFilePersistence(directory: fixture.configDirectory, startWatching: false, deferSaves: false)
    }

    private func settingsURL(in fixture: Fixture) -> URL {
        fixture.configDirectory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
    }

    private func corruptURL(in fixture: Fixture, index: Int = 0) -> URL {
        fixture.configDirectory.appendingPathComponent(
            SettingsFilePersistence.corruptFileNames[index],
            isDirectory: false
        )
    }

    private func assertSymlink(
        at linkURL: URL,
        destination: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, file: file, line: line)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            destination,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertPOSIXError(
        _ expected: POSIXErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? POSIXError)?.code, expected, file: file, line: line)
        }
    }
}
