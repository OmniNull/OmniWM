// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsConfigDiagnostics {
    static func issues(
        directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL,
        settingsFileURL: URL? = nil,
        notice: SettingsConfigNotice? = nil,
        scriptLoadError: String? = nil
    ) -> [DiagnosticsIssue] {
        var issues: [DiagnosticsIssue] = []
        if let notice {
            let kind: DiagnosticsIssue.Kind = switch notice {
            case let .persistenceWriteBlocked(reason): .settingsPersistenceBlocked(reason: reason)
            case let .invalidRejected(reason): .settingsInvalidRejected(reason: reason)
            }
            let url = settingsFileURL ?? SettingsFilePersistence.settingsURL(in: directoryURL)
            issues.append(DiagnosticsIssue(kind: kind, configFileURL: url))
        }
        if let scriptLoadError {
            let url = directoryURL.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false)
            issues.append(DiagnosticsIssue(kind: .configScriptFailed(message: scriptLoadError), configFileURL: url))
        }
        return issues
    }
}
