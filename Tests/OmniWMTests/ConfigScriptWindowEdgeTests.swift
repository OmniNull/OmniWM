// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWindowEdgeTests: XCTestCase {
    func testNativeAdmissionReadmissionAndRemovalPublishActualTransitions() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let source = try XCTUnwrap(controller.activeWorkspace())
        let otherName = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        let monitor = try XCTUnwrap(manager.monitors.first)
        let destination = try XCTUnwrap(manager.createDynamicWorkspace(named: otherName, on: monitor.id)).id
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: controller.automationSessionToken)
        var kinds: [ConfigScriptEventKind] = []
        var edges: [ConfigScriptEventPayload.Edge] = []
        let observers = ConfigScriptEventObservers(
            controller: controller, kinds: [.windowOpen, .windowMoveToWorkspace, .windowClose]
        ) { kind, payload in
            XCTAssertEqual(payload.id, id)
            XCTAssertEqual(
                manager.workspace(for: token),
                kind == .windowClose ? nil : (kind == .windowOpen ? source.id : destination)
            )
            kinds.append(kind)
            if let edge = payload.edge { edges.append(edge) }
        }
        defer { observers.stop() }
        let ax = WindowAdmissionTestSupport.track(token, in: source.id, controller: controller)
        for workspace in [source.id, destination, destination] {
            XCTAssertEqual(manager.addWindow(ax, pid: token.pid, windowId: token.windowId, to: workspace), token)
        }
        manager.setWorkspace(for: token, to: destination)
        XCTAssertNotNil(manager.removeWindow(pid: token.pid, windowId: token.windowId))
        XCTAssertNil(manager.removeWindow(pid: token.pid, windowId: token.windowId))
        XCTAssertEqual(kinds, [.windowOpen, .windowMoveToWorkspace, .windowClose])
        XCTAssertEqual(edges, [
            .workspace(id: source.id.uuidString, name: source.name),
            .workspace(
                id: destination.uuidString,
                name: otherName,
                previousId: source.id.uuidString,
                previousName: source.name
            ),
            .workspace(id: destination.uuidString, name: otherName)
        ])
    }

    func testGatherAndFamilyMovesPublishEveryMemberAfterTheCommit() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let controller = fixture.base.controller
        let manager = fixture.manager
        let expectedIDs = fixture.family.map { IPCWindowOpaqueID.encode(
            token: $0,
            sessionToken: controller.automationSessionToken
        ) }
        var ids: [String] = []
        var destination = fixture.otherMonitorDestination
        var source = fixture.source
        let observers = ConfigScriptEventObservers(
            controller: controller,
            kinds: [.windowMoveToWorkspace]
        ) { kind, payload in
            XCTAssertEqual(kind, .windowMoveToWorkspace)
            XCTAssertEqual(payload.bundleId, "family-state")
            XCTAssertEqual(payload.edge, .workspace(
                id: destination.uuidString, name: manager.descriptor(for: destination)?.name,
                previousId: source.uuidString, previousName: manager.descriptor(for: source)?.name
            ))
            XCTAssertTrue(fixture.family.allSatisfy { manager.workspace(for: $0) == destination })
            if let id = payload.id { ids.append(id) }
        }
        defer { observers.stop() }
        guard case let .ready(plan) = manager.planNiriGather(fixture.gatherRequest()) else {
            return XCTFail("The hosted family must have a gather plan.")
        }
        XCTAssertTrue(manager.commitNiriGather(plan))
        XCTAssertEqual(Set(ids), Set(expectedIDs))
        XCTAssertEqual(ids.count, expectedIDs.count)
        ids.removeAll()
        source = destination
        destination = fixture.destination
        manager.setWorkspace(for: fixture.main, to: destination)
        XCTAssertEqual(ids, expectedIDs)
        observers.stop()
        manager.setWorkspace(for: fixture.main, to: fixture.source)
        XCTAssertEqual(ids, expectedIDs)
    }
}
