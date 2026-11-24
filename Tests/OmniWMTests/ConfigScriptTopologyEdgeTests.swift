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
        let leftID = left.id.scriptIdentifier
        let rightID = right.id.scriptIdentifier
        XCTAssertEqual(received, [
            .workspaceCreated: [.init(id: id.uuidString, name: name, edge: .monitor(id: leftID, name: left.name))],
            .workspaceMoveToMonitor: [.init(id: id.uuidString, name: name, edge: .monitor(
                id: rightID, name: right.name, previousId: leftID, previousName: left.name
            ))],
            .workspaceRemoved: [.init(id: id.uuidString, name: name, edge: .monitor(id: rightID, name: right.name))]
        ])
        XCTAssertNil(manager.workspaceCatalog.name(for: id))
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
        let leftID = left.id.scriptIdentifier
        let rightID = right.id.scriptIdentifier
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
        let id = right.id.scriptIdentifier
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
        XCTAssertNil(observers.catalogMonitorContext)
        observers.stop()
        XCTAssertNil(manager.scriptTopologyObserver)
        XCTAssertNil(manager.scriptWorkspaceMoveObserver)
    }

    func testCommittedBulkRemovalPreservesOrderAndAccountsForMissingTail() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let manager = fixture.controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        let capacity = ConfigScriptCallbackQueue.edgeCapacity
        let existing = manager.workspaces.map(\.name)
        let firstName = try XCTUnwrap(existing.compactMap(Int.init).max()) + 1
        let overflow = existing.count
        let ids = try (firstName ..< firstName + capacity + overflow).map { name in
            try XCTUnwrap(manager.createDynamicWorkspace(named: String(name), on: monitor.id)).id
        }
        let expected = ids.prefix(capacity).map { "'\($0.uuidString)'" }.joined(separator: ",")
        fixture.apply(try await fixture.load([
            "local expected = {\(expected)}",
            "local received = 0",
            "omniwm.on('workspace.removed', function(e)",
            "    received += 1",
            "    assert(e.id == expected[received], 'unexpected removed workspace')",
            "    assert(e.missed == (if received == #expected then \(overflow) else 0))",
            "end)",
            "omniwm.command('Check removals', function() assert(received == #expected) end)"
        ]))
        manager.removeWorkspaces(ids + ids + [UUID()])
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertTrue(ids.allSatisfy { manager.workspaceCatalog.name(for: $0) == nil })
    }

    func testCatalogMonitorMatchesNativeResolutionForHiddenMissingAndDisconnectedWorkspaces() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let (left, disconnected) = monitors()
        manager.applyMonitorConfigurationChange([left])
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        let id = try XCTUnwrap(manager.createDynamicWorkspace(named: name, on: left.id)).id
        XCTAssertNil(manager.monitorIdShowingWorkspace(id))
        XCTAssertEqual(manager.configCatalogMonitor(for: id)?.id, manager.monitorForWorkspace(id)?.id)
        XCTAssertEqual(manager.configCatalogMonitor(for: id)?.name, left.name)
        let missing = UUID()
        XCTAssertNil(manager.monitorForWorkspace(missing))
        XCTAssertNil(manager.configCatalogMonitor(for: missing))
        manager.commitMonitorSessions([disconnected.id: MonitorSession(visibleWorkspaceId: id)])
        XCTAssertNil(manager.monitorForWorkspace(id))
        XCTAssertNil(manager.configCatalogMonitor(for: id))
    }

    func testNestedRemovalLeavesOuterTransactionIntact() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let monitor = try XCTUnwrap(manager.monitors.first)
        func workspace() throws -> UUID {
            let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
            return try XCTUnwrap(manager.createDynamicWorkspace(named: name, on: monitor.id)).id
        }
        let first = try workspace()
        let last = try workspace()
        let nested = try workspace()
        var received: [String] = []
        let observer = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceRemoved]) { _, event in
            guard let id = event.id else { return XCTFail("Missing removed workspace ID") }
            received.append(id)
            if id == first.uuidString { manager.removeWorkspaces([nested]) }
        }
        defer { observer.stop() }
        manager.removeWorkspaces([first, last])
        XCTAssertEqual(received, [first, nested, last].map(\.uuidString))
    }

    private func monitors() -> (Monitor, Monitor) {
        let left = NiriGatherFixture.monitor(displayId: 1)
        let right = NiriGatherFixture.monitor(displayId: left.displayId + 1, x: left.frame.maxX)
        return (left, right)
    }
}
