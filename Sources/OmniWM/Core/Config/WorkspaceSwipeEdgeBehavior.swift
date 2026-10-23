// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum WorkspaceSwipeEdgeBehavior: String, CaseIterable, Codable, Identifiable {
    case cycle
    case none
    case onePast

    var id: String {
        rawValue
    }
}
