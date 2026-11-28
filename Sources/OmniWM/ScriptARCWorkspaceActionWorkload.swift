// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
func measureWorkspaceActions(in directory: URL) async throws {
    for route in ["workspace/focus-noop", "workspace/rename-unchanged", "workspace/rename-changed"] {
        let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent(route))
        defer { fixture.script.stop() }
        try await fixture.workspaceLabelOrFocus(route: route)
    }
    for (route, force) in [("workspace/move-accepted", true), ("workspace/move-refused", false)] {
        let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent(route))
        defer { fixture.script.stop() }
        try await fixture.workspaceMove(route: route, force: force)
    }
}

@MainActor
extension ScriptARCFixture {
    private static let workspaceChord = "Control+Option+W"
    private static let workspaceLabel = "Mail"
    private static let workspaceRename = "Work"

    private func workspaceBinding(_ statement: String) async throws -> HotkeyCommand {
        let queue = try await acceptTitleScript("""
        omniwm.keymap.set("\(Self.workspaceChord)", function()
            \(statement)
        end)
        """)
        await queue.waitForAuditPark()
        return try binding(Self.workspaceChord)
    }

    private func setWorkspaceLabel(_ label: String?, of rawName: String) {
        var configurations = controller.settings.workspaces.configurations
        let index = configurations.firstIndex { $0.name == rawName }!
        configurations[index].displayName = label
        controller.settings.workspaces.configurations = configurations
    }

    private func nativeWorkspaceAction(
        _ action: WorkspaceTargetAction, on rawName: String, route: String, reset: () -> Void
    ) {
        for report in [false, true] {
            reset()
            script_arc_begin()
            let result = controller.performWorkspaceTargetAction(action, onWorkspaceNamed: rawName)
            script_arc_end()
            precondition(result == .executed || result == .noChange)
            if report { script_arc_report(route, "native", 0) }
        }
    }

    private func workspaceLabel(of rawName: String) -> String? {
        controller.settings.workspaces.configurations.first { $0.name == rawName }?.displayName
    }

    fileprivate func workspaceLabelOrFocus(route: String) async throws {
        let active = controller.activeWorkspace()!
        let other = controller.workspaceManager.workspaces.first { $0.id != active.id }!.name
        let statement = switch route {
        case "workspace/focus-noop":
            "omniwm.dispatch(\"workspace\", \"focus-name\", \"\(active.name)\")"
        case "workspace/rename-unchanged":
            "omniwm.dispatch(\"workspace\", \"rename\", \"\(other)\", \"\(Self.workspaceLabel)\")"
        default:
            "omniwm.dispatch(\"workspace\", \"rename\", \"\(other)\", \"\(Self.workspaceRename)\")"
        }
        precondition(controller.workspaceNavigationHandler.canSkipSwitch(toVisibleWorkspace: active.id))
        let command = try await workspaceBinding(statement)
        for report in [false, true] {
            setWorkspaceLabel(Self.workspaceLabel, of: other)
            try await function(command, route: route, busy: false, report: report)
            precondition(script.diagnostic == nil && controller.activeWorkspace()?.id == active.id)
            let expected = route == "workspace/rename-changed" ? Self.workspaceRename : Self.workspaceLabel
            precondition(workspaceLabel(of: other) == expected)
        }
        switch route {
        case "workspace/focus-noop":
            nativeWorkspaceAction(.focus, on: active.name, route: "native/workspace-focus-noop") {}
        case "workspace/rename-changed":
            nativeWorkspaceAction(.rename(Self.workspaceRename), on: other, route: "native/workspace-rename-changed") {
                setWorkspaceLabel(Self.workspaceLabel, of: other)
            }
        default:
            break
        }
    }

    fileprivate func workspaceMove(route: String, force: Bool) async throws {
        let manager = controller.workspaceManager
        let first = manager.monitors.first!
        let frame = first.frame.offsetBy(dx: first.frame.width, dy: 0)
        let second = Monitor(
            id: .init(displayId: first.displayId + 1), displayId: first.displayId + 1, frame: frame,
            visibleFrame: frame, hasNotch: false, name: "Audit right", displayUUID: UUID().uuidString, isMain: false
        )
        manager.applyMonitorConfigurationChange([first, second])
        let active = controller.activeWorkspace()!
        let moved = manager.workspaces.first { $0.id != active.id }!
        let options = force ? ", { force = true }" : ""
        let command = try await workspaceBinding(
            "omniwm.dispatch(\"workspace\", \"move-to-monitor\", \"\(moved.name)\", \"right\"\(options))"
        )
        guard force else {
            try await refusedFunction(
                command, route: route,
                diagnostic: "workspace move-to-monitor: the workspace is assigned to another display; "
                    + "pass { force = true } to move it anyway.",
                report: true
            )
            precondition(manager.monitorForWorkspace(moved.id)?.id == first.id)
            return
        }
        for report in [false, true] {
            precondition(manager.monitorForWorkspace(moved.id)?.id == first.id)
            try await function(command, route: route, busy: false, report: report)
            precondition(script.diagnostic == nil && manager.monitorForWorkspace(moved.id)?.id == second.id)
            let back = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(moved.id, to: first.id, force: true)
            precondition(back?.status == .executed)
        }
        nativeWorkspaceAction(
            .moveToMonitor(.right, force: true), on: moved.name, route: "native/workspace-move-accepted"
        ) {
            if manager.monitorForWorkspace(moved.id)?.id != first.id {
                let back = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
                    moved.id,
                    to: first.id,
                    force: true
                )
                precondition(back?.status == .executed)
            }
        }
    }
}
