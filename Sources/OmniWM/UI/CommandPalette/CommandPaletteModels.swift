// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

struct CommandPaletteWindowItem: Identifiable {
    let id: WindowToken
    let handle: WindowHandle
    let title: String
    let appName: String
    let appIcon: NSImage?
    let workspaceName: String
    let isAppHidden: Bool
}

struct CommandPaletteCommandItem: Identifiable {
    let spec: ActionSpec
    let shortcut: String
    let hasShortcut: Bool
    let shortcutSearchTerms: [String]
    let isLayoutCompatible: Bool

    var id: String {
        spec.id
    }
}

struct CommandPaletteAppSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let isTerminated: Bool

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?,
        isTerminated: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isTerminated = isTerminated
    }

    init(app: NSRunningApplication) {
        processIdentifier = app.processIdentifier
        bundleIdentifier = app.bundleIdentifier
        localizedName = app.localizedName
        isTerminated = app.isTerminated
    }
}

struct CommandPaletteSummonAnchor: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
}

struct CommandPaletteFocusTarget {
    let app: CommandPaletteAppSnapshot
    let focusedWindow: AXUIElement?
    let focusedWindowID: CGWindowID?
}

enum CommandPaletteSelectionID: Hashable {
    case window(WindowToken)
    case menu(UUID)
    case clipboard(UUID)
    case command(String)
}

enum CommandPaletteSelectionTrigger {
    case primary
    case alternate
}

struct CommandPaletteClipboardPasteTarget {
    let focusTarget: CommandPaletteFocusTarget
    let expectedWindowId: CGWindowID
}
