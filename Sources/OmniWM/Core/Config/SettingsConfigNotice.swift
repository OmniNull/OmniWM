// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum SettingsFilePersistenceError: Error, Equatable, LocalizedError {
    case danglingSettingsSymlink(String)
    case writesBlocked(String)

    var errorDescription: String? {
        switch self {
        case let .danglingSettingsSymlink(path):
            "The settings symlink at \(path) points to a missing file; create its target or replace the symlink, then restart OmniWM."
        case let .writesBlocked(reason):
            "Settings writes are blocked: \(reason)"
        }
    }
}

enum SettingsConfigNotice: Equatable {
    case persistenceWriteBlocked(reason: String)
    case invalidRejected(reason: String)

    var blockingReason: String? {
        switch self {
        case let .persistenceWriteBlocked(reason): reason
        case .invalidRejected:
            nil
        }
    }
}

struct SettingsFileLoadOutcome: Equatable {
    let export: SettingsExport?
    let notice: SettingsConfigNotice?
}
