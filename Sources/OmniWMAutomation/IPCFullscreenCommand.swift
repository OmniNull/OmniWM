// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCFullscreenCommand: String, CaseIterable, Hashable, Sendable {
    case managed = "toggle-fullscreen"
    case native = "toggle-native-fullscreen"
}
