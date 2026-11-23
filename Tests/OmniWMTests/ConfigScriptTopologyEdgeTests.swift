// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptTopologyEdgeTests: XCTestCase {
    func testWorkspaceCatalogAndMovesPublishOnlyCommittedEdges() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let (left, right) = monitors()
        manager.applyMonitorConfigurationChange([left, right])
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        var received: [ConfigScriptEventKind: [ConfigScriptEventPayload]] = [:]
        let observers = ConfigScriptEventObservers(
            controller: controller, kinds: [.workspaceCreated, .workspaceMoveToMonitor, .workspaceRemoved]
        ) { kind, payload in
            guard payload.name == name else { return }
            received[kind, default: []].append(payload)
            let id = payload.id.flatMap(UUID.init(uuidString:))
            XCTAssertEqual(id.flatMap(manager.descriptor(for:)) == nil, kind == .workspaceRemoved)
            if kind == .workspaceMoveToMonitor {
                XCTAssertEqual(id.flatMap(manager.monitorForWorkspace)?.id, right.id)
            }
        }
        defer { observers.stop() }
        let descriptor = try XCTUnwrap(manager.createDynamicWorkspace(named: name, on: left.id))
        let id = descriptor.id
        XCTAssertEqual(manager.createDynamicWorkspace(named: name, on: left.id)?.id, id)
        XCTAssertEqual(manager.moveWorkspaceToMonitor(id, to: right.id, force: true).status, .executed)
        XCTAssertTrue(manager.moveWorkspaceToMonitor(id, to: right.id, force: true).affectedWorkspaces.isEmpty)
        manager.removeWorkspaces([id, id])
        manager.removeWorkspaces([id])
        let leftID = IPCDisplayRef.identifier(left.id)
        let rightID = IPCDisplayRef.identifier(right.id)
        XCTAssertEqual(received, [
            .workspaceCreated: [.init(id: id.uuidString, name: name, edge: .monitor(id: leftID, name: left.name))],
            .workspaceMoveToMonitor: [.init(id: id.uuidString, name: name, edge: .monitor(
                id: rightID, name: right.name, previousId: leftID, previousName: left.name
            ))],
            .workspaceRemoved: [.init(id: id.uuidString, name: name, edge: .monitor(id: rightID, name: right.name))]
        ])
        XCTAssertNil(observers.workspaceMonitorAssignments[id])
    }

    func testSettingsAndDisconnectPublishActualWorkspaceOwnershipChanges() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let (left, right) = monitors()
        manager.applyMonitorConfigurationChange([left, right])
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        let config = WorkspaceConfiguration(name: name, monitorAssignment: .specificDisplay(OutputId(from: left)))
        manager.settings.workspaces.configurations.append(config)
        manager.applySettings()
        let id = try XCTUnwrap(manager.workspaceId(named: name))
        XCTAssertEqual(manager.monitorForWorkspace(id)?.id, left.id)
        var moves: [ConfigScriptEventPayload] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceMoveToMonitor]) {
            if $1.id == id.uuidString { moves.append($1) }
        }
        defer { observers.stop() }
        let index = try XCTUnwrap(manager.settings.workspaces.configurations.firstIndex { $0.id == config.id })
        manager.settings.workspaces.configurations[index].monitorAssignment = .specificDisplay(OutputId(from: right))
        manager.applySettings()
        manager.applySettings()
        manager.applyMonitorConfigurationChange([left])
        let leftID = IPCDisplayRef.identifier(left.id)
        let rightID = IPCDisplayRef.identifier(right.id)
        XCTAssertEqual(moves, [
            .init(id: id.uuidString, name: name, edge: .monitor(
                id: rightID, name: right.name, previousId: leftID, previousName: left.name
            )),
            .init(id: id.uuidString, name: name, edge: .monitor(
                id: leftID, name: left.name, previousId: rightID, previousName: right.name
            ))
        ])
    }

    func testMonitorEdgesIgnoreReorderAndMetadataButIncludeUsableFrameChanges() {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let (left, right) = monitors()
        manager.applyMonitorConfigurationChange([left])
        var received: [ConfigScriptEventKind: [ConfigScriptEventPayload]] = [:]
        let observers = ConfigScriptEventObservers(
            controller: controller, kinds: [.monitorAdded, .monitorRemoved, .monitorLayoutChanged]
        ) { kind, payload in
            received[kind, default: []].append(payload)
            XCTAssertEqual(manager.monitors.contains { $0.id == right.id }, kind != .monitorRemoved)
        }
        manager.applyMonitorConfigurationChange([left, right])
        manager.applyMonitorConfigurationChange([right, left])
        let changed = Monitor(
            id: right.id, displayId: right.displayId, frame: right.frame,
            visibleFrame: right.frame.insetBy(dx: 0, dy: right.frame.height / 8), hasNotch: false,
            name: right.name, isMain: false
        )
        let renamed = Monitor(
            id: right.id, displayId: right.displayId, frame: changed.frame, visibleFrame: changed.visibleFrame,
            hasNotch: false, name: "Renamed", isMain: false
        )
        manager.applyMonitorConfigurationChange([changed, left])
        manager.applyMonitorConfigurationChange([renamed, left])
        manager.applyMonitorConfigurationChange([left])
        let id = IPCDisplayRef.identifier(right.id)
        XCTAssertEqual(received, [
            .monitorAdded: [.init(id: id, name: right.name, edge: .geometry(
                frame: right.frame, visibleFrame: right.visibleFrame
            ))],
            .monitorLayoutChanged: [.init(id: id, name: changed.name, edge: .geometry(
                frame: changed.frame, previousFrame: right.frame,
                visibleFrame: changed.visibleFrame, previousVisibleFrame: right.visibleFrame
            ))],
            .monitorRemoved: [.init(id: id, name: renamed.name, edge: .geometry(
                frame: renamed.frame, visibleFrame: renamed.visibleFrame
            ))]
        ])
        XCTAssertTrue(observers.workspaceMonitorAssignments.isEmpty)
        observers.stop()
        XCTAssertNil(manager.scriptTopologyObserver)
        XCTAssertNil(manager.scriptWorkspaceMoveObserver)
    }

    private func monitors() -> (Monitor, Monitor) {
        let left = NiriGatherFixture.monitor(displayId: 1)
        let right = NiriGatherFixture.monitor(displayId: left.displayId + 1, x: left.frame.maxX)
        return (left, right)
    }
}
