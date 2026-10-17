// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func gatherResponse(
        _ request: IPCWindowGatherRequest,
        id: String,
        controller: WMController,
        session sessionToken: String
    ) -> IPCResponse {
        IPCWindowGatherRequestExecutor(controller: controller, sessionToken: sessionToken).response(
            for: request,
            id: id
        )
    }
}
