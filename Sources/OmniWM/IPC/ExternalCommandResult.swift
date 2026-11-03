// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ExternalCommandResult: Equatable, Sendable, Error {
    case executed
    case ignoredDisabled
    case ignoredOverview
    case ignoredLayoutMismatch
    case staleWindowId
    case workspaceAssignmentConflict
    case workspaceStateConflict
    case notFound
    case noChange
    case attachedWindow
    case windowActionFailed
    case invalidArguments
}
