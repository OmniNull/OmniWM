// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func shellResponse(for request: IPCShellRequest, id: String, controller: WMController) async -> IPCResponse {
        controller.noteUserAction()
        let result: ExternalCommandResult = switch request {
        case let .toggle(widget) where request.isValid:
            controller.commandHandler.performCommand(.shellToggle(widget))
        case let .trigger(widget, name, value) where request.isValid:
            controller.automationRefusal
                ?? controller.workspaceBarManager.applyShellRuntimeRequest(.trigger(
                    widget: widget,
                    name: name,
                    value: value
                ))
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
