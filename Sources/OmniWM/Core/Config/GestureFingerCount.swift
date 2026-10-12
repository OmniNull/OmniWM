// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

enum GestureFingerCount: Int, CaseIterable, Codable {
    case two = 2
    case three = 3
    case four = 4

    var displayName: String {
        switch self {
        case .two: "2 Fingers"
        case .three: "3 Fingers"
        case .four: "4 Fingers"
        }
    }
}

enum ThreeOrFourFingerCount: Int, Codable {
    case three = 3
    case four = 4
}
