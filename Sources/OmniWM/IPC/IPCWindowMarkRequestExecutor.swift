// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowMarkRequestExecutor {
    private let controller: WMController

    init(controller: WMController) {
        self.controller = controller
    }

    func response(for request: IPCWindowMarkRequest, id: String) -> IPCResponse {
        switch request {
        case .list:
            return listResponse(id: id)
        case let .set(name):
            guard let guardCode = controllerStateFailure() else {
                return setResponse(name, id: id)
            }
            return .failure(id: id, kind: .windowMark, code: guardCode)
        case let .focus(name):
            guard let guardCode = controllerStateFailure() else {
                return focusResponse(name, id: id)
            }
            return .failure(id: id, kind: .windowMark, code: guardCode)
        case let .summon(name):
            guard let guardCode = controllerStateFailure() else {
                return summonResponse(name, id: id)
            }
            return .failure(id: id, kind: .windowMark, code: guardCode)
        case let .remove(name):
            guard let guardCode = controllerStateFailure() else {
                return removeResponse(name, id: id)
            }
            return .failure(id: id, kind: .windowMark, code: guardCode)
        }
    }

    private func controllerStateFailure() -> IPCErrorCode? {
        guard let result = IPCCommandValidation.controllerState(controller) else { return nil }
        switch result {
        case .ignoredDisabled:
            return .disabled
        case .ignoredOverview:
            return .overviewOpen
        default:
            return nil
        }
    }

    private func setResponse(_ name: String, id: String) -> IPCResponse {
        guard controller.windowMarkRegistry.isValidName(name) else {
            return .failure(id: id, kind: .windowMark, code: .invalidMark)
        }
        guard let token = controller.workspaceManager.nativeManagedFocusToken,
              controller.workspaceManager.entry(for: token) != nil,
              controller.workspaceManager.handle(for: token) != nil
        else {
            return .failure(id: id, kind: .windowMark, code: .noFocusedWindow)
        }

        switch controller.windowMarkRegistry.set(name, for: token) {
        case .inserted,
             .unchanged:
            return .success(id: id, kind: .windowMark, status: .executed)
        case .duplicate:
            return .failure(id: id, kind: .windowMark, code: .duplicateMark)
        case .invalidName:
            return .failure(id: id, kind: .windowMark, code: .invalidMark)
        }
    }

    private func listResponse(id: String) -> IPCResponse {
        var entries: [IPCWindowMarkEntry] = []
        for mark in controller.windowMarkRegistry.marks {
            guard let entry = controller.workspaceManager.entry(for: mark.token),
                  let descriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
            else {
                _ = controller.windowMarkRegistry.remove(mark.name)
                return .failure(id: id, kind: .windowMark, code: .staleMark)
            }

            let appInfo = controller.appInfoCache.info(for: entry.pid)
            let app = IPCAppRef(
                name: appInfo?.name ?? "PID \(entry.pid)",
                bundleId: appInfo?.bundleId
            )
            let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
            entries.append(
                IPCWindowMarkEntry(
                    name: mark.name,
                    workspace: IPCWorkspaceRef(descriptor: descriptor, settings: controller.settings),
                    app: app,
                    title: title?.isEmpty == false ? title : nil
                )
            )
        }

        return .success(
            id: id,
            kind: .windowMark,
            result: IPCResult(windowMarks: IPCWindowMarksResult(marks: entries))
        )
    }

    private func focusResponse(_ name: String, id: String) -> IPCResponse {
        let token: WindowToken
        switch controller.windowMarkRegistry.lookup(name) {
        case let .found(foundToken):
            token = foundToken
        case .unknown:
            return .failure(id: id, kind: .windowMark, code: .unknownMark)
        case .invalidName:
            return .failure(id: id, kind: .windowMark, code: .invalidMark)
        }

        guard controller.workspaceManager.entry(for: token) != nil,
              let handle = controller.workspaceManager.handle(for: token)
        else {
            _ = controller.windowMarkRegistry.remove(name)
            return .failure(id: id, kind: .windowMark, code: .staleMark)
        }

        guard controller.windowActionHandler.navigateToExplicitlySelectedWindow(handle: handle) else {
            return .failure(id: id, kind: .windowMark, code: .windowActionFailed)
        }
        return .success(id: id, kind: .windowMark, status: .executed)
    }

    private func summonResponse(_ name: String, id: String) -> IPCResponse {
        let token: WindowToken
        switch controller.windowMarkRegistry.lookup(name) {
        case let .found(foundToken):
            token = foundToken
        case .unknown:
            return .failure(id: id, kind: .windowMark, code: .unknownMark)
        case .invalidName:
            return .failure(id: id, kind: .windowMark, code: .invalidMark)
        }

        guard let handle = controller.workspaceManager.handle(for: token) else {
            _ = controller.windowMarkRegistry.remove(name)
            return .failure(id: id, kind: .windowMark, code: .staleMark)
        }

        switch controller.windowActionHandler.summonWindowRightOutcome(handle: handle) {
        case .summoned:
            return .success(id: id, kind: .windowMark, status: .executed)
        case .movedToWorkspace:
            return .success(id: id, kind: .windowMark, status: .executed)
        case .moveFailed:
            return .failure(id: id, kind: .windowMark, code: .windowActionFailed)
        case .noAnchor:
            return .failure(id: id, kind: .windowMark, code: .noFocusedWindow)
        case .selfSummon:
            return .failure(id: id, kind: .windowMark, code: .selfSummon)
        case .hiddenTarget:
            return .failure(id: id, kind: .windowMark, code: .hiddenWindow)
        case .staleTarget:
            _ = controller.windowMarkRegistry.remove(name)
            return .failure(id: id, kind: .windowMark, code: .staleMark)
        case .unsupportedLayout:
            return .failure(id: id, kind: .windowMark, code: .unsupportedLayout)
        case .actionFailed:
            return .failure(id: id, kind: .windowMark, code: .windowActionFailed)
        }
    }

    private func removeResponse(_ name: String, id: String) -> IPCResponse {
        switch controller.windowMarkRegistry.remove(name) {
        case .removed:
            return .success(id: id, kind: .windowMark, status: .executed)
        case .unknown:
            return .failure(id: id, kind: .windowMark, code: .unknownMark)
        case .invalidName:
            return .failure(id: id, kind: .windowMark, code: .invalidMark)
        }
    }
}
