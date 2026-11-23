// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsConfigDiagnostics {
    static func issues(
        directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL,
        notice: SettingsConfigNotice? = nil
    ) -> [DiagnosticsIssue] {
        guard let notice else { return [] }
        let kind: DiagnosticsIssue.Kind = switch notice {
        case let .persistenceWriteBlocked(reason): .settingsPersistenceBlocked(reason: reason)
        case let .invalidRejected(reason): .settingsInvalidRejected(reason: reason)
        }
        let url = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
        return [DiagnosticsIssue(kind: kind, configFileURL: url)]
    }
}
