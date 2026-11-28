// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
final class IPCCommandRouter {
    let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCCommandRequest) -> ExternalCommandResult {
        guard let command = HotkeyCommand(direct: request.command) else { return .invalidArguments }
        return controller.commandHandler.performCommand(command, source: .ipc)
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        IPCWindowRequestExecutor(controller: controller, sessionToken: sessionToken).handle(request)
    }
}
