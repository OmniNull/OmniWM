// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
import Foundation

enum SettingsConfigDiagnostics {
    static func issues(
        directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL,
        notice: SettingsConfigNotice? = nil
    ) -> [DiagnosticsIssue] {
        guard let notice, let kind = issue(for: notice) else { return [] }
        let url = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        return [DiagnosticsIssue(kind: kind, configFileURL: url)]
    }

    private static func issue(for notice: SettingsConfigNotice) -> DiagnosticsIssue.Kind? {
        switch notice {
        case let .migrated(report, backupURL):
            guard pathEntryExists(at: backupURL) else { return nil }
            return .settingsMigrated(report: report, backupURL: backupURL)
        case let .migrationWriteBlocked(report, backupURL, reason):
            let existing = backupURL.flatMap { pathEntryExists(at: $0) ? $0 : nil }
            return .settingsPersistenceBlocked(
                reason: ([reason] + report.messages).joined(separator: " "),
                backupURL: existing
            )
        case let .unsupportedVersion(found, supported):
            return .settingsPersistenceBlocked(
                reason: "schemaVersion \(found) is newer than supported version \(supported).",
                backupURL: nil
            )
        case let .recoveredInvalid(backupURL, reason):
            guard pathEntryExists(at: backupURL) else { return nil }
            return .settingsRecovered(reason: reason, backupURL: backupURL)
        case let .persistenceWriteBlocked(reason):
            return .settingsPersistenceBlocked(reason: reason, backupURL: nil)
        case let .invalidRejected(reason):
            return .settingsInvalidRejected(reason: reason)
        }
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        var fileStatus = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &fileStatus) == 0
        }
    }
}
