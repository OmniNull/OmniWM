// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func windowMarkResponse(
        for request: IPCWindowMarkRequest,
        id: String,
        controller: WMController,
        sessionToken: String = ""
    ) -> IPCResponse {
        IPCWindowMarkRequestExecutor(controller: controller, sessionToken: sessionToken).response(for: request, id: id)
    }
}
