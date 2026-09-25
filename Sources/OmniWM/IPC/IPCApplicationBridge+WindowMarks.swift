// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func windowMarkResponse(
        for request: IPCWindowMarkRequest,
        id: String,
        controller: WMController
    ) -> IPCResponse {
        IPCWindowMarkRequestExecutor(controller: controller).response(for: request, id: id)
    }
}
