// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCWindowStateCommand: String, CaseIterable, Hashable, Sendable {
    case toggleFloating = "toggle-focused-window-floating"
    case close = "close-focused-window"
}
