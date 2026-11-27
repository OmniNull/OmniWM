// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMAutomation
import OmniWMIPC
import ScriptARCCounters

@MainActor
private struct ScriptARCTopologyInputs {
    let workspace: WorkspaceDescriptor
    let first: Monitor
    let second: Monitor
    let current: [Monitor]
    let priorLayout: [Monitor]
    let priorRemoval: [Monitor]

    init(manager: WorkspaceManager) {
        current = manager.monitors
        first = current.first!
        workspace = manager.descriptor(for: manager.workspaceId(named: "1")!)!
        let nextId = first.displayId + 1
        second = Monitor(
            id: .init(displayId: nextId), displayId: nextId, frame: first.frame, visibleFrame: first.visibleFrame,
            hasNotch: false, name: "Second", isMain: false
        )
        let prior = Monitor(
            id: first.id, displayId: first.displayId, frame: first.frame,
            visibleFrame: first.visibleFrame.insetBy(dx: 0, dy: first.visibleFrame.height / 2),
            hasNotch: false, name: first.name, isMain: first.isMain
        )
        priorLayout = [prior]
        priorRemoval = [first, second]
    }

    @inline(never)
    func publish(_ kind: ConfigScriptEventKind, in manager: WorkspaceManager) {
        switch kind {
        case .workspaceCreated:
            manager.withCatalogObserver(.creation) { $0.workspaceCreated(workspace, in: manager) }
        case .workspaceRemoved:
            if let observer = manager.scriptWorkspaceRemovalObserver {
                var removed = ConfigScriptWorkspaceRemovals()
                removed.append(id: workspace.id, name: workspace.name, in: manager)
                removed.publish(to: observer, in: manager)
            }
        case .workspaceMoveToMonitor:
            manager.withCatalogObserver(.move) {
                $0.workspaceMoved(workspace.id, from: second, to: ConfigScriptCatalogMonitor(first), in: manager)
            }
        case .monitorAdded:
            manager.withCatalogObserver(.topology) { $0.topologyCommitted(previous: [], current: current, in: manager) }
        case .monitorRemoved:
            manager.withCatalogObserver(.topology) { $0.topologyCommitted(
                previous: priorRemoval,
                current: current,
                in: manager
            ) }
        case .monitorLayoutChanged:
            manager.withCatalogObserver(.topology) { $0.topologyCommitted(
                previous: priorLayout,
                current: current,
                in: manager
            ) }
        default:
            preconditionFailure()
        }
    }
}

@MainActor
extension ScriptARCFixture {
    func topologyEvents(in directory: URL) async throws {
        let manager = controller.workspaceManager
        let inputs = ScriptARCTopologyInputs(manager: manager)
        let kinds: [ConfigScriptEventKind] = [
            .workspaceCreated, .workspaceRemoved, .workspaceMoveToMonitor, .monitorAdded, .monitorRemoved,
            .monitorLayoutChanged
        ]
        for kind in kinds {
            let control = "absent/" + kind.rawValue
            try await loadMissingScript(in: directory)
            precondition(script.callbackQueue == nil && script.eventObservers == nil)
            script_arc_begin()
            inputs.publish(kind, in: manager)
            script_arc_end()
            script_arc_report(control, "native", 0)
            let queue = try await acceptTitleScript("""
            omniwm.on("\(kind.rawValue)", function(e) assert(e.id and e.name and e.missed == 0) end)
            """)
            await queue.waitForAuditPark()
            for report in [false, true] {
                script_arc_begin()
                inputs.publish(kind, in: manager)
                script_arc_end()
                precondition(queue.hasPendingWork)
                try await finishWorker(seed: false)
                if report { script_arc_report("event/" + kind.rawValue, control, 1) }
            }
        }
        try await ownedCatalogMove(in: directory)
        let (first, second) = try await catalogReassignment(in: directory)
        try await hiddenCatalogCreation(
            in: directory,
            assignment: .secondary,
            expected: second,
            route: "native/catalog-ranked"
        )
        try await hiddenCatalogCreation(
            in: directory,
            assignment: .tertiary,
            expected: first,
            route: "native/catalog-unavailable"
        )
    }

    private func ownedCatalogMove(in directory: URL) async throws {
        try await loadMissingScript(in: directory)
        let manager = controller.workspaceManager
        let first = manager.monitors.first!
        let name = String(Int.max)
        let workspace = manager.createDynamicWorkspace(named: name, on: first.id)!.id
        let previous = Monitor(
            id: first.id, displayId: first.displayId, frame: first.frame, visibleFrame: first.visibleFrame,
            hasNotch: false, name: UUID().uuidString, isMain: true
        )
        let nextID = first.displayId + 1
        let current = ConfigScriptCatalogMonitor(Monitor(
            id: .init(displayId: nextID), displayId: nextID, frame: first.frame, visibleFrame: first.visibleFrame,
            hasNotch: false, name: UUID().uuidString, isMain: false
        ))
        let queue = try await acceptTitleScript("""
        omniwm.on("workspace.move_to_monitor", function(e)
            assert(e.name == "\(name)" and e.missed == 0)
            assert(e.previousMonitorName == "\(previous.name)" and e.monitorName == "\(current.name)")
        end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            script_arc_begin()
            manager
                .withCatalogObserver(.move) { $0.workspaceMoved(workspace, from: previous, to: current, in: manager) }
            script_arc_end()
            try await finishWorker(seed: false)
            if report {
                script_arc_report("owned/workspace.move_to_monitor", "event/workspace.move_to_monitor", 1)
            }
        }
        manager.removeWorkspaces([workspace])
    }

    private func catalogReassignment(in directory: URL) async throws -> (Monitor, Monitor) {
        try await loadMissingScript(in: directory)
        let manager = controller.workspaceManager
        let first = manager.monitors.first!
        let newId = first.displayId + 1
        let frame = first.frame.offsetBy(dx: first.frame.width, dy: 0)
        let second = Monitor(
            id: .init(displayId: newId), displayId: newId, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Audit right", displayUUID: UUID().uuidString, isMain: false
        )
        manager.applyMonitorConfigurationChange([first, second])
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        let left = MonitorAssignment.specificDisplay(OutputId(from: first))
        let right = MonitorAssignment.specificDisplay(OutputId(from: second))
        manager.settings.workspaces.configurations.append(WorkspaceConfiguration(name: name, monitorAssignment: left))
        manager.applySettings()
        let index = manager.settings.workspaces.configurations.firstIndex { $0.name == name }!
        let id = manager.workspaceId(named: name)!
        for subscribed in [false, true] {
            if subscribed {
                let queue = try await acceptTitleScript("""
                omniwm.on("workspace.move_to_monitor", function(e) assert(e.name == "\(name)" and e.missed == 0) end)
                """)
                await queue.waitForAuditPark()
            }
            for report in [false, true] {
                manager.settings.workspaces.configurations[index].monitorAssignment = left
                manager.applySettings()
                if let queue = script.callbackQueue { await queue.waitForAuditPark() }
                precondition(manager.monitorForWorkspace(id)?.id == first.id)
                manager.settings.workspaces.configurations[index].monitorAssignment = right
                script_arc_begin()
                manager.applySettings()
                script_arc_end()
                if subscribed { try await finishWorker(seed: false) }
                precondition(manager.monitorForWorkspace(id)?.id == second.id)
                if report {
                    script_arc_report(
                        subscribed ? "native/catalog-bulk+script" : "native/catalog-bulk",
                        subscribed ? "native/catalog-bulk" : "native", subscribed ? 1 : 0
                    )
                }
            }
        }
        return (first, second)
    }

    private func hiddenCatalogCreation(
        in directory: URL, assignment: MonitorAssignment, expected monitor: Monitor, route: String
    ) async throws {
        try await loadMissingScript(in: directory)
        let manager = controller.workspaceManager
        let visible = manager.visibleWorkspaceId(on: monitor.id)!
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        manager.settings.monitors.ranking = manager.monitors.map(OutputId.init(from:))
        manager.settings.workspaces.configurations.append(WorkspaceConfiguration(
            name: name,
            monitorAssignment: assignment
        ))
        manager.applySettings()
        precondition(manager.setActiveWorkspace(visible, on: monitor.id))
        let monitorID = monitor.id.scriptIdentifier
        for subscribed in [false, true] {
            if subscribed {
                let queue = try await acceptTitleScript("""
                omniwm.on("workspace.created", function(e) assert(e.name == "\(name)" and e.monitorId == "\(monitorID)") end)
                """)
                await queue.waitForAuditPark()
            }
            for report in [false, true] {
                manager.removeWorkspaces([manager.workspaceId(named: name)!])
                script_arc_begin()
                let id = manager.workspaceId(for: name, createIfMissing: true)!
                script_arc_end()
                if subscribed { try await finishWorker(seed: false) }
                precondition(manager.monitorIdShowingWorkspace(id) == nil && manager.monitorForWorkspace(id)?
                    .id == monitor.id)
                if report {
                    script_arc_report(
                        subscribed ? route + "+script" : route,
                        subscribed ? route : "native", subscribed ? 1 : 0
                    )
                }
            }
        }
    }
}

@MainActor
extension ScriptARCFixture {
    func checkCatalogRemovalLifetime() async throws {
        let manager = controller.workspaceManager
        let monitor = manager.monitors.first!
        checkCatalogRegistrationReplacement(in: manager, on: monitor)
        let marker = "Archive · " + UUID().uuidString
        let names = [String(Int.max - 1), String(Int.max - 2)]
        let expected = names.map { "'\($0)'" }.joined(separator: ",")
        let queue = try await acceptTitleScript("""
        local names = {\(expected)}
        local received = 0
        omniwm.on("workspace.removed", function(e)
            received += 1
            assert(e.name == names[received] and e.monitorName == "\(marker)" and e.missed == 0)
        end)
        omniwm.command("Check catalog", function() assert(received == #names) end)
        """)
        await queue.waitForAuditPark()
        manager.applyMonitorConfigurationChange([Monitor(
            id: monitor.id, displayId: monitor.displayId, frame: monitor.frame, visibleFrame: monitor.visibleFrame,
            hasNotch: monitor.hasNotch, name: marker, displayUUID: monitor.displayUUID, isMain: monitor.isMain
        )])
        let ids = names.map { manager.createDynamicWorkspace(named: $0, on: monitor.id)!.id }
        manager.removeWorkspaces(ids + ids)
        manager.applyMonitorConfigurationChange([monitor])
        let verify = script.acceptedCommands.first { $0.name == "Check catalog" }!
        precondition(key(.configFunction(verify.function), measured: false) == .executed)
        await queue.waitForAuditPark()
        precondition(script.diagnostic == nil)
    }

    private func checkCatalogRegistrationReplacement(in manager: WorkspaceManager, on monitor: Monitor) {
        let first = String(Int.max - 3)
        let second = String(Int.max - 4)
        var calls: [String] = []
        let initial = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceCreated]) { _, event in
            precondition(event.name == first)
            calls.append(first)
            manager.scriptWorkspaceCreationObserver?.stop()
            let replacement = ConfigScriptEventObservers(controller: self.controller, kinds: [.workspaceCreated]) {
                _, nested in
                precondition(nested.name == second)
                calls.append(second)
            }
            defer { replacement.stop() }
            precondition(manager.createDynamicWorkspace(named: second, on: monitor.id) != nil)
        }
        defer { initial.stop() }
        precondition(manager.createDynamicWorkspace(named: first, on: monitor.id) != nil)
        precondition(calls == [first, second])
        manager.removeWorkspaces([manager.workspaceId(named: first)!, manager.workspaceId(named: second)!])
    }
}
