// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptWindowTitle: Sendable {
    let token: WindowToken
    let session: ConfigScriptSession
    let epoch: UInt64
    let title: String
    let bundle: String?

    nonisolated func payload(id: String) -> ConfigScriptEventPayload {
        ConfigScriptEventPayload(id: id, bundleId: bundle, edge: .title(title))
    }
}

enum ConfigScriptQueuedEvent: Sendable {
    case title(ConfigScriptWindowTitle)
    case native(ConfigScriptNativeEvent)
}
