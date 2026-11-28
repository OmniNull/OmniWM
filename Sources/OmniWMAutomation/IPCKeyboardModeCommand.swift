// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCKeyboardModeCommand: String, CaseIterable, Hashable, Sendable {
    case togglePause = "toggle-shortcut-pause"
    case beginPrefix = "begin-prefix"
    case toggleWindowMode = "toggle-window-mode"
    case exit = "exit-keyboard-mode"
}
