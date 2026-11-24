// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ScriptARCCounters

@MainActor
extension ScriptARCFixture {
    func windowTransactions(in directory: URL, subscribed: Bool) async throws {
        let manager = controller.workspaceManager
        let first = manager.workspace(for: otherWindow)!
        let second = manager.workspaceId(named: "2")!
        let extra = WindowToken(pid: token.pid, windowId: token.windowId + Self.totalRows)
        let ax = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: extra.windowId)
        func admit() {
            precondition(manager
                .addWindow(ax, pid: extra.pid, windowId: extra.windowId, to: first, mode: .tiling) == extra)
        }
        func remove() {
            precondition(manager.removeWindow(pid: extra.pid, windowId: extra.windowId) != nil)
        }
        func change(_ kind: ConfigScriptEventKind, forward: Bool) {
            switch kind {
            case .windowOpen: if forward { admit() } else { remove() }
            case .windowClose: if forward { remove() } else { admit() }
            case .windowMoveToWorkspace: manager.setWorkspace(for: otherWindow, to: forward ? second : first)
            case .windowMinimize: precondition(manager.setWindowMinimized(forward, token: otherWindow))
            case .windowUpdateState: precondition(manager.setWindowMode(
                    forward ? .floating : .tiling,
                    for: otherWindow
                ))
            case .windowFullscreen:
                if forward {
                    precondition(manager.markNativeFullscreenSuspended(otherWindow, ownsNativeFocus: false))
                } else {
                    precondition(manager.restoreNativeFullscreenRecord(for: otherWindow, clearsNativeFocusOwner: false))
                }
            default: preconditionFailure()
            }
        }
        try await measureTransactions(
            in: directory,
            subscribed: subscribed,
            admit: admit,
            remove: remove,
            change: change
        )
    }

    private func measureTransactions(
        in directory: URL, subscribed: Bool, admit: () -> Void, remove: () -> Void,
        change: (ConfigScriptEventKind, Bool) -> Void
    ) async throws {
        let kinds: [ConfigScriptEventKind] = [
            .windowOpen, .windowClose, .windowMoveToWorkspace, .windowMinimize, .windowUpdateState, .windowFullscreen
        ]
        for kind in kinds {
            try await loadMissingScript(in: directory)
            if kind == .windowClose { admit() }
            if subscribed {
                let queue =
                    try await acceptTitleScript("omniwm.on('\(kind.rawValue)', function(e) assert(e.id) end)")
                await queue.waitForAuditPark()
            }
            for report in [false, true] {
                script_arc_begin()
                change(kind, true)
                script_arc_end()
                if subscribed { try await finishWorker(seed: false) }
                let control = "native/" + kind.rawValue
                if report { script_arc_report(
                    subscribed ? control + "+script" : control,
                    subscribed ? control : "native",
                    subscribed ? 1 : 0
                ) }
                change(kind, false)
                await script.callbackQueue?.waitForAuditPark()
            }
            try await loadMissingScript(in: directory)
            if kind == .windowClose { remove() }
        }
    }
}
