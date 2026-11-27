// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCMediaCommand: String, CaseIterable, Hashable, Sendable {
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case volumeMute = "volume-mute"
    case playPause = "media-play-pause"
    case next = "media-next"
    case previous = "media-previous"
}
