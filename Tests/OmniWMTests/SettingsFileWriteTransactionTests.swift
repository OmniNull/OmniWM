// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class SettingsFileWriteTransactionTests: XCTestCase {
    private struct Fixture {
        let directoryURL: URL
        let fileURL: URL

        @MainActor
        func transaction() -> SettingsFileWriteTransaction {
            SettingsFileWriteTransaction(directoryURL: directoryURL, fileURL: fileURL, targetURL: fileURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    @MainActor
    func testSuccessfulSaveCallsCommitSynchronouslyOnceWithPreservedBytes() throws {
        let original = try SettingsTOMLCodec.encode(.defaults())
        let fixture = try makeFixture(data: original)
        defer { fixture.remove() }
        var desired = SettingsExport.defaults()
        desired.gaps.size += 3
        let expected = try SettingsTOMLCodec.encode(desired, preservingUnknownKeysFrom: original)
        var commitCount = 0

        let outcome = fixture.transaction().perform(desired) { data in
            commitCount += 1
            XCTAssertEqual(data, expected)
        }

        guard case let .saved(notice) = outcome else { return XCTFail("Expected a successful save") }
        XCTAssertNil(notice)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    @MainActor
    func testUnsupportedInspectionReturnsItsNoticeWithoutCallingCommit() throws {
        let supported = SettingsTOMLCodec.currentSchemaVersion
        let found = supported + 1
        let original = Data("schemaVersion = \(found)".utf8)
        let fixture = try makeFixture(data: original)
        defer { fixture.remove() }
        var commitCount = 0

        let outcome = fixture.transaction().perform(.defaults()) { _ in commitCount += 1 }

        guard case let .failed(failure) = outcome else { return XCTFail("Expected unsupported settings to be refused") }
        let expected = SettingsTOMLCodecError.unsupportedSchemaVersion(found: found, supported: supported)
        XCTAssertEqual(failure.error as? SettingsTOMLCodecError, expected)
        XCTAssertEqual(failure.notice, .unsupportedVersion(found: found, supported: supported))
        XCTAssertEqual(
            failure.diagnostic,
            "Refusing to overwrite unsupported settings at \(fixture.fileURL.path): \(expected.localizedDescription)"
        )
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    @MainActor
    func testCommitFailureReturnsOriginalErrorWithoutAnInnerNotice() throws {
        let original = try SettingsTOMLCodec.encode(.defaults())
        let fixture = try makeFixture(data: original)
        defer { fixture.remove() }
        let expected = NSError(domain: "SettingsFileWriteTransactionTests", code: 7)
        var commitCount = 0

        let outcome = fixture.transaction().perform(.defaults()) { _ in
            commitCount += 1
            throw expected
        }

        guard case let .failed(failure) = outcome else { return XCTFail("Expected commit failure") }
        XCTAssertTrue(failure.error as NSError === expected)
        XCTAssertNil(failure.notice)
        XCTAssertNil(failure.diagnostic)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    @MainActor
    func testUnsupportedCommitErrorRetainsItsCommitPhaseClassification() throws {
        let original = try SettingsTOMLCodec.encode(.defaults())
        let fixture = try makeFixture(data: original)
        defer { fixture.remove() }
        let expected = SettingsTOMLCodecError.unsupportedSchemaVersion(found: 6, supported: 5)
        var commitCount = 0

        let outcome = fixture.transaction().perform(.defaults()) { _ in
            commitCount += 1
            throw expected
        }

        guard case let .failed(failure) = outcome else { return XCTFail("Expected commit failure") }
        XCTAssertEqual(failure.error as? SettingsTOMLCodecError, expected)
        XCTAssertNil(failure.notice)
        XCTAssertNil(failure.diagnostic)
        XCTAssertEqual(commitCount, 1)
    }

    @MainActor
    func testRecoverySecuresOriginalBytesBeforeCommitAndPreservesCommitError() throws {
        let original = Data([0xFF, 0x10, 0xFE])
        let fixture = try makeFixture(data: original)
        defer { fixture.remove() }
        let backupURL = fixture.directoryURL.appendingPathComponent(SettingsFilePersistence.corruptFileName)
        let expected = NSError(domain: "SettingsFileWriteTransactionTests", code: 8)
        let invalidReason: String
        do {
            _ = try SettingsTOMLCodec.decodeForLoad(original)
            return XCTFail("Expected invalid source bytes")
        } catch {
            invalidReason = SettingsTOMLCodec.diagnosticDescription(for: error)
        }
        var commitCount = 0

        let outcome = fixture.transaction().perform(.defaults()) { data in
            commitCount += 1
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertEqual(try SettingsTOMLCodec.decode(data), .defaults())
            throw expected
        }

        guard case let .failed(failure) = outcome else { return XCTFail("Expected recovery commit failure") }
        let combinedReason = "\(invalidReason) Recovery failed: \(expected.localizedDescription)"
        XCTAssertTrue(failure.error as NSError === expected)
        XCTAssertEqual(failure.notice, .persistenceWriteBlocked(reason: combinedReason))
        XCTAssertEqual(
            failure.diagnostic,
            "Failed to recover invalid settings at \(fixture.fileURL.path): \(combinedReason)"
        )
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
    }

    @MainActor
    func testMigrationBacksUpOriginalBytesBeforeExactlyOneCommit() throws {
        let fixture = try makeMigrationFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.fileURL)
        let decoded = try SettingsTOMLCodec.decodeForLoad(original)
        let migration = try XCTUnwrap(decoded.migration)
        let backupURL = fixture.directoryURL.appendingPathComponent(
            try XCTUnwrap(SettingsFilePersistence.migrationBackupFileNames(for: migration.toVersion).first)
        )
        var commitCount = 0

        let outcome = fixture.transaction().executeMigration(
            originalData: original, decoded: decoded, export: decoded.export, migration: migration
        ) { data in
            commitCount += 1
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            XCTAssertEqual(try SettingsTOMLCodec.decode(data), decoded.export)
        }

        guard case let .migrated(notice) = outcome else { return XCTFail("Expected migration success") }
        XCTAssertEqual(notice, .migrated(report: migration, backupURL: backupURL))
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
    }

    @MainActor
    func testMigrationCommitFailurePreservesOriginalErrorAndAssignedBackupURL() throws {
        let fixture = try makeMigrationFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.fileURL)
        let decoded = try SettingsTOMLCodec.decodeForLoad(original)
        let migration = try XCTUnwrap(decoded.migration)
        let backupURL = fixture.directoryURL.appendingPathComponent(
            try XCTUnwrap(SettingsFilePersistence.migrationBackupFileNames(for: migration.toVersion).first)
        )
        let expected = NSError(domain: "SettingsFileWriteTransactionTests", code: 9)
        var commitCount = 0

        let outcome = fixture.transaction().executeMigration(
            originalData: original, decoded: decoded, export: decoded.export, migration: migration
        ) { _ in
            commitCount += 1
            XCTAssertEqual(try Data(contentsOf: backupURL), original)
            throw expected
        }

        guard case let .blocked(failure) = outcome else { return XCTFail("Expected migration commit failure") }
        XCTAssertTrue(failure.error as NSError === expected)
        XCTAssertEqual(failure.backupURL, backupURL)
        XCTAssertEqual(failure.reason, expected.localizedDescription)
        XCTAssertEqual(
            failure.notice(for: migration),
            .migrationWriteBlocked(report: migration, backupURL: backupURL, reason: expected.localizedDescription)
        )
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    private func makeMigrationFixture() throws -> Fixture {
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Settings/v0.6.4-custom.toml")
        return try makeFixture(data: Data(contentsOf: sourceURL))
    }

    private func makeFixture(data: Data) throws -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWriteTransaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName)
        try data.write(to: fileURL)
        return Fixture(directoryURL: directoryURL, fileURL: fileURL)
    }
}
