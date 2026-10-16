// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func shellResponse(for request: IPCShellRequest, id: String, controller: WMController) async -> IPCResponse {
        let result: ExternalCommandResult = switch request {
        case let .toggle(widget) where request.isValid:
            controller.commandHandler.performCommand(.shellToggle(widget))
        case .trigger where request.isValid:
            IPCCommandValidation.controllerState(controller)
                ?? controller.workspaceBarManager.applyShellRequest(request)
        case .profile,
             .theme,
             .eject,
             .initialize:
            await controller.workspaceBarManager.applyShellFileRequest(request)
        default:
            controller.workspaceBarManager.applyShellRequest(request)
        }
        return response(for: result, id: id, kind: .shell)
    }
}
