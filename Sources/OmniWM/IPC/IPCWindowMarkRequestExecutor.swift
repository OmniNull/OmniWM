// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowMarkRequestExecutor {
    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String = "") {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func response(for request: IPCWindowMarkRequest, id: String) -> IPCResponse {
        let action: WindowMarkAction
        switch request {
        case .list: return listResponse(id: id)
        case let .set(name): action = .init(kind: .set, name: name)
        case let .focus(name): action = .init(kind: .focus, name: name)
        case let .summon(name): action = .init(kind: .summon, name: name)
        case let .remove(name): action = .init(kind: .remove, name: name)
        }
        controller.noteUserAction()
        do {
            _ = try controller.performWindowMark(action, focus: .actionTime)
            return .success(id: id, kind: .windowMark, status: .executed)
        } catch {
            return .failure(id: id, kind: .windowMark, code: error.ipcCode)
        }
    }

    private func listResponse(id: String) -> IPCResponse {
        var entries: [IPCWindowMarkEntry] = []
        for mark in controller.windowMarkRegistry.marks {
            guard let entry = controller.workspaceManager.entry(for: mark.token),
                  let descriptor = controller.workspaceManager.descriptor(for: entry.workspaceId)
            else {
                _ = controller.windowMarkRegistry.remove(mark.name)
                continue
            }

            let presentation = controller.appInfoCache.presentation(
                for: entry, title: AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
            )
            let app = IPCAppRef(
                name: presentation.name ?? "PID \(entry.pid)",
                bundleId: entry.target.hostedMetadata?.appId ?? controller.appInfoCache.bundleId(for: entry.pid)
            )
            let title = presentation.title
            let id = IPCWindowOpaqueID.encode(token: entry.token, sessionToken: sessionToken)
            entries.append(
                IPCWindowMarkEntry(
                    name: mark.name,
                    id: id,
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
}

extension WindowMarkRefusal {
    fileprivate var ipcCode: IPCErrorCode {
        switch self {
        case .disabled: .disabled
        case .overviewOpen: .overviewOpen
        case .invalidMark: .invalidMark
        case .duplicateMark: .duplicateMark
        case .unknownMark: .unknownMark
        case .staleMark: .staleMark
        case .noFocusedWindow,
             .focusChanged: .noFocusedWindow
        case .selfSummon: .selfSummon
        case .hiddenWindow: .hiddenWindow
        case .unsupportedLayout: .unsupportedLayout
        case .windowActionFailed: .windowActionFailed
        }
    }
}
