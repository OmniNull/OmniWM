// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum SettingsFileAction {
    case reveal
    case open
}

@MainActor
enum SettingsFileWorkflow {
    static func perform(
        _ action: SettingsFileAction,
        settings: SettingsStore,
        openFile: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        revealFile: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) throws -> SettingsFileStatus {
        try settings.ensureSettingsFileAvailable()
        let targetURL = settings.settingsFileURL

        switch action {
        case .reveal:
            revealFile([targetURL])
            return .revealed
        case .open:
            guard openFile(targetURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return .opened
        }
    }
}

enum SettingsFileStatus: Equatable {
    case revealed
    case opened
    case error(String)

    var message: String {
        switch self {
        case .revealed: String(localized: "Settings file revealed in Finder")
        case .opened: String(localized: "Settings file opened")
        case let .error(msg): String(localized: "Error: \(msg)")
        }
    }

    var icon: String {
        switch self {
        case .opened,
             .revealed: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .opened,
             .revealed: .green
        case .error: .red
        }
    }
}
