// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ConfigDiagnosticsTests: XCTestCase {
    func testRejectedEditDiagnosticUsesResolvedConfigAndExactDecodePaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMResolvedXDGConfig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
            .replacingOccurrences(of: "followsMouse = false", with: "followsMouse = \"false\"")
        let reason: String
        do {
            _ = try SettingsLuauDocument(Data(source.utf8))
            return XCTFail("Expected strict type rejection")
        } catch {
            reason = SettingsLuauError.diagnosticDescription(for: error)
        }

        let issues = SettingsConfigDiagnostics.issues(
            directoryURL: directory,
            notice: .invalidRejected(reason: reason)
        )
        let issue = try XCTUnwrap(issues.first)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issue.configFileURL, settingsURL)
        XCTAssertTrue(reason.contains("focus.followsMouse"))
        XCTAssertTrue(issue.message.contains(settingsURL.path))
        XCTAssertTrue(issue.message.contains("focus.followsMouse"))
        XCTAssertTrue(issue.remediation.contains(settingsURL.path))
    }

    func testUnknownKeysReportTheirLocationInSettings() {
        for (source, key) in [
            ("return { broken = true }", "broken"),
            ("return { general = { broken = false } }", "general.broken"),
            ("return { appRules = { { bundleId = 'org.example.App', broken = true } } }", "broken")
        ] {
            XCTAssertThrowsError(try SettingsLuauDocument(Data(source.utf8))) { error in
                XCTAssertTrue(error.localizedDescription.contains("settings.luau:1:"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(key), error.localizedDescription)
            }
        }
    }

    func testNoNoticeProducesNoIssueAndBlockedWritesPreserveTheirReason() throws {
        let directory = FileManager.default.temporaryDirectory
        XCTAssertTrue(SettingsConfigDiagnostics.issues(directoryURL: directory, notice: nil).isEmpty)
        let reason = "Read-only directory"
        let issue = try XCTUnwrap(SettingsConfigDiagnostics.issues(
            directoryURL: directory, notice: .persistenceWriteBlocked(reason: reason)
        ).first)
        XCTAssertEqual(issue.severity, .critical)
        XCTAssertTrue(issue.message.contains(reason))
        XCTAssertTrue(issue.revealsConfigFolder)
    }
}
