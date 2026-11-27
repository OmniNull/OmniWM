// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsConfigDiagnostics {
    static func issues(
        directoryURL: URL = SettingsFilePersistence.defaultDirectoryURL,
        notice: SettingsConfigNotice? = nil,
        scriptLoadError: String? = nil,
        scriptCallbackError: String? = nil,
        scriptShortcutConflict: String? = nil
    ) -> [DiagnosticsIssue] {
        var issues: [DiagnosticsIssue] = []
        if let notice {
            let kind: DiagnosticsIssue.Kind = switch notice {
            case let .persistenceWriteBlocked(reason): .settingsPersistenceBlocked(reason: reason)
            case let .invalidRejected(reason): .settingsInvalidRejected(reason: reason)
            }
            let url = directoryURL.appendingPathComponent(SettingsFilePersistence.fileName, isDirectory: false)
            issues.append(DiagnosticsIssue(kind: kind, configFileURL: url))
        }
        for case let message? in [scriptLoadError, scriptCallbackError] {
            let url = directoryURL.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false)
            issues.append(DiagnosticsIssue(kind: .configScriptFailed(message: message), configFileURL: url))
        }
        if let scriptShortcutConflict {
            let url = directoryURL.appendingPathComponent(ConfigScriptController.fileName, isDirectory: false)
            issues.append(DiagnosticsIssue(
                kind: .configScriptShortcutConflict(message: scriptShortcutConflict), configFileURL: url
            ))
        }
        return issues
    }
}
