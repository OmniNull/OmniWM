// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCMediaCommand {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .volumeUp: LocalizedStringResource(
                "command.media.volumeUp", defaultValue: "Volume Up", table: "Commands", bundle: .omniWM
            )
        case .volumeDown: LocalizedStringResource(
                "command.media.volumeDown", defaultValue: "Volume Down", table: "Commands", bundle: .omniWM
            )
        case .volumeMute: LocalizedStringResource(
                "command.media.volumeMute", defaultValue: "Mute or Unmute Volume", table: "Commands", bundle: .omniWM
            )
        case .playPause: LocalizedStringResource(
                "command.media.playPause", defaultValue: "Play or Pause Media", table: "Commands", bundle: .omniWM
            )
        case .next: LocalizedStringResource(
                "command.media.next", defaultValue: "Next Track", table: "Commands", bundle: .omniWM
            )
        case .previous: LocalizedStringResource(
                "command.media.previous", defaultValue: "Previous Track", table: "Commands", bundle: .omniWM
            )
        }
    }

    func actionSpec() -> ActionSpec {
        let id: String
        let keywords: [String]
        switch self {
        case .volumeUp:
            id = "volumeUp"
            keywords = ["volume", "louder", "sound", "audio"]
        case .volumeDown:
            id = "volumeDown"
            keywords = ["volume", "quieter", "sound", "audio"]
        case .volumeMute:
            id = "volumeMute"
            keywords = ["volume", "mute", "sound", "audio"]
        case .playPause:
            id = "mediaPlayPause"
            keywords = ["media", "music", "play", "pause"]
        case .next:
            id = "mediaNext"
            keywords = ["media", "music", "next", "skip", "track"]
        case .previous:
            id = "mediaPrevious"
            keywords = ["media", "music", "previous", "back", "track"]
        }
        return ActionCatalog.action(
            id: id,
            command: .media(self),
            category: .focus,
            binding: .unassigned,
            keywords: keywords
        )
    }
}
