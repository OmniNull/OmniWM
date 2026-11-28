// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC

@MainActor
struct IPCWindowRequestExecutor {
    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func handle(_ request: IPCWindowRequest) -> ExternalCommandResult {
        if let refusal = controller.automationRefusal { return refusal }
        guard let address = IPCWindowOpaqueID.decode(request.windowId) else { return .invalidArguments }
        guard address.sessionToken == sessionToken else { return .staleWindowId }
        guard let action = WindowAction(request) else { return .invalidArguments }
        return controller.performWindowAction(action, on: WindowToken(pid: address.pid, windowId: address.windowId))
    }
}

extension WindowAction {
    init?(_ request: IPCWindowRequest) {
        let change = request.change.map(NiriSizeChange.init(ipc:))
        let forward = request.cycle.map { $0 == .forward }
        let action: WindowAction? = switch request.name {
        case .focus: .focus
        case .navigate: .navigate
        case .summonRight: .summonRight
        case .close: .close
        case .moveToWorkspace: request.workspaceTarget.map { .moveToWorkspace($0) }
        case .moveColumnToFirst: .moveColumn(.first)
        case .moveColumnToLast: .moveColumn(.last)
        case .moveColumnToIndex: request.columnIndex.flatMap { $0 >= 1 ? .moveColumn(.index($0)) : nil }
        case .moveColumn: request.direction.map { .moveColumn(.direction(Direction(ipc: $0))) }
        case .toggleContainerFullPrimarySpan: .toggleContainerFullPrimarySpan
        case .setContainerPrimarySpan: change.map { .setContainerPrimarySpan($0) }
        case .setWindowPrimarySpan: change.map { .setWindowPrimarySpan($0) }
        case .cycleWindowPrimarySpan: forward.map { .cycleWindowPrimarySpan(forward: $0) }
        case .setWindowSecondarySpan: change.map { .setWindowSecondarySpan($0) }
        case .resetWindowSecondarySpan: .resetWindowSecondarySpan
        case .cycleWindowSecondarySpan: forward.map { .cycleWindowSecondarySpan(forward: $0) }
        case .toggleColumnTabbed: .toggleColumnTabbed
        case .toggleFloating: .toggleFloating
        case .assignToScratchpad: request.scratchpadIndex.flatMap(ScratchpadIndex.init).map { .assignToScratchpad($0) }
        }
        guard let action else { return nil }
        self = action
    }
}
