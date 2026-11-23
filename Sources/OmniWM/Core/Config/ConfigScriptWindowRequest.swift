// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC

struct ConfigScriptWindowRequest: Equatable, Sendable {
    let request: IPCWindowRequest
    let address: IPCWindowOpaqueID.Address

    var token: WindowToken {
        WindowToken(pid: address.pid, windowId: address.windowId)
    }

    init(words: [String]) throws(ConfigScriptError) {
        guard let request = IPCWindowRequest(actionWords: words) else {
            throw ConfigScriptError(line: nil, message: "Invalid window action or arguments.")
        }
        guard let address = IPCWindowOpaqueID.decode(request.windowId) else {
            throw ConfigScriptError(line: nil, message: "Expected a session-scoped window ID.")
        }
        self.request = request
        self.address = address
    }
}
