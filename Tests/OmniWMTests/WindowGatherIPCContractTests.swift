// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowGatherIPCContractTests: XCTestCase {
    private let sessionToken = "gather-session"

    func testRequestAndResultRoundTripThroughTheWire() throws {
        let request = IPCRequest(
            id: "gather-1",
            windowGather: IPCWindowGatherRequest(windowIds: ["ow_a", "ow_b"], workspaceTarget: .rawID("3"))
        )
        let line = try IPCWire.encodeRequestLine(request)
        let json = try XCTUnwrap(String(data: line, encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"window-gather\""), json)
        XCTAssertTrue(json.contains("\"windowIds\":[\"ow_a\",\"ow_b\"]"), json)
        XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCRequest.self, from: line), request)

        let result = IPCResult(windowGather: IPCWindowGatherResult(
            outcome: .refused,
            workspace: IPCWorkspaceRef(id: "ws", rawName: "3", displayName: "3", number: 3),
            reason: .windowRefused,
            windows: [
                .init(windowId: "ow_a", status: .blocked),
                .init(windowId: "ow_b", status: .refused, reason: .scratchpad)
            ]
        ))
        let response = IPCResponse.failure(id: "gather-1", kind: .windowGather, code: .ineligibleWindow, result: result)
        let responseLine = try IPCWire.encodeResponseLine(response)
        let responseJSON = try XCTUnwrap(String(data: responseLine, encoding: .utf8))
        XCTAssertTrue(responseJSON.contains("\"code\":\"ineligible_window\""), responseJSON)
        XCTAssertTrue(responseJSON.contains("\"reason\":\"scratchpad\""), responseJSON)
        XCTAssertTrue(responseJSON.contains("\"modelCommitted\":false"), responseJSON)
        XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCResponse.self, from: responseLine), response)
    }

    func testCapabilitiesAdvertiseTheGatherRequest() {
        XCTAssertEqual(IPCAutomationManifest.windowGatherActionDescriptors.map(\.path), ["window-gather"])
        XCTAssertEqual(
            IPCAutomationManifest.windowGatherActionDescriptors.first?.arguments,
            ["windowIds", "markNames", "workspaceTarget"]
        )
    }

    func testExecutorReportsGatheredAndThenUnchanged() throws {
        let fixture = try makeFixture(displayId: 75_101)
        let destination = fixture.workspace("3")
        fixture.add([1], to: fixture.workspace("1"))
        fixture.add([2], to: fixture.workspace("2"))
        fixture.add([3], to: destination)
        let ids = [1, 2, 3].map { id(fixture.token($0)) }

        let response = execute(fixture, ids: ids, target: .rawID("3"))
        XCTAssertTrue(response.ok, "unexpected code \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(response.kind, .windowGather)
        XCTAssertEqual(response.status, .executed)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .gathered)
        XCTAssertEqual(result.workspace?.rawName, "3")
        XCTAssertEqual(result.windows.map(\.status), [.moved, .moved, .moved])
        XCTAssertEqual(result.moved, ids)
        XCTAssertEqual(result.relayoutWorkspaces.map(\.rawName), ["3", "1", "2"])
        XCTAssertTrue(result.modelCommitted)
        XCTAssertTrue(result.relayoutRequested)
        XCTAssertEqual(fixture.layout(destination), [[1, 2, 3]])

        let repeated = execute(fixture, ids: ids, target: .rawID("3"))
        XCTAssertFalse(repeated.ok)
        XCTAssertEqual(repeated.status, .ignored)
        XCTAssertEqual(repeated.code, .noChange)
        let repeatedResult = try gatherResult(repeated)
        XCTAssertEqual(repeatedResult.outcome, .unchanged)
        XCTAssertEqual(repeatedResult.windows.map(\.status), [.unchanged, .unchanged, .unchanged])
        XCTAssertEqual(repeatedResult.moved, [])
        XCTAssertEqual(repeatedResult.relayoutWorkspaces, [])
        XCTAssertFalse(repeatedResult.modelCommitted)
    }

    func testExecutorRefusesWithStablePerInputDiagnostics() throws {
        let fixture = try makeFixture(displayId: 75_102)
        let source = fixture.workspace("1")
        fixture.add([1, 2], to: source)
        XCTAssertTrue(fixture.manager.updateScratchpadMembership(fixture.token(2), to: 1, notify: false))
        let valid = id(fixture.token(1))
        let stale = IPCWindowOpaqueID.encode(pid: 1, windowId: 2, sessionToken: "previous-session")
        let sequence = fixture.manager.worldSeq

        let response = execute(
            fixture,
            ids: [valid, "garbage", stale, valid, id(fixture.token(2)), id(fixture.token(9))],
            target: .rawID("3")
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.code, .invalidArguments)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(result.reason, .windowRefused)
        XCTAssertEqual(result.windows, [
            .init(windowId: valid, status: .blocked),
            .init(windowId: "garbage", status: .unresolved, reason: .invalidWindowId),
            .init(windowId: stale, status: .unresolved, reason: .staleWindowId),
            .init(windowId: valid, status: .refused, reason: .duplicateWindow),
            .init(windowId: id(fixture.token(2)), status: .refused, reason: .scratchpad),
            .init(windowId: id(fixture.token(9)), status: .unresolved, reason: .notFound)
        ])
        XCTAssertEqual(result.moved, [])
        XCTAssertEqual(result.relayoutWorkspaces, [])
        XCTAssertEqual(fixture.manager.worldSeq, sequence)

        let ineligible = execute(fixture, ids: [valid, id(fixture.token(2))], target: .rawID("3"))
        XCTAssertEqual(ineligible.code, .ineligibleWindow)

        let missingDestination = execute(fixture, ids: [valid], target: .displayName("missing-destination"))
        XCTAssertEqual(missingDestination.code, .notFound)
        XCTAssertEqual(try gatherResult(missingDestination).reason, .destinationNotFound)
        XCTAssertNil(try gatherResult(missingDestination).workspace)

        let empty = execute(fixture, ids: [], target: .rawID("3"))
        XCTAssertEqual(empty.code, .invalidArguments)
        XCTAssertEqual(try gatherResult(empty).reason, .noWindows)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testBridgeDispatchesGatherRequestsWithTheSessionWindowIds() async throws {
        let fixture = try makeFixture(displayId: 75_103)
        fixture.add([1, 2], to: fixture.workspace("1"))
        let bridge = IPCApplicationBridge(
            controller: fixture.controller,
            appVersion: "0.0.0-test",
            sessionToken: sessionToken,
            authorizationToken: "token"
        )
        let request = IPCRequest(
            id: "bridge-gather",
            windowGather: IPCWindowGatherRequest(
                windowIds: [2, 1].map { id(fixture.token($0)) },
                workspaceTarget: .rawID("2")
            ),
            authorizationToken: "token"
        )

        let response = await bridge.response(for: request)
        XCTAssertEqual(response.id, "bridge-gather")
        XCTAssertEqual(response.kind, .windowGather)
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(try gatherResult(response).outcome, .gathered)
        XCTAssertEqual(fixture.layout(fixture.workspace("2")), [[2, 1]])
    }

    private func makeFixture(displayId: UInt32) throws -> NiriGatherFixture {
        try NiriGatherFixture(
            prefix: "OmniWMWindowGatherIPC",
            monitors: [NiriGatherFixture.monitor(displayId: displayId)],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3")]
        )
    }

    private func id(_ token: WindowToken) -> String {
        IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }

    private func execute(_ fixture: NiriGatherFixture, ids: [String], target: WorkspaceTarget) -> IPCResponse {
        IPCWindowGatherRequestExecutor(controller: fixture.controller, sessionToken: sessionToken).response(
            for: IPCWindowGatherRequest(windowIds: ids, workspaceTarget: target),
            id: "gather"
        )
    }

    private func gatherResult(_ response: IPCResponse) throws -> IPCWindowGatherResult {
        guard case let .windowGather(result) = try XCTUnwrap(response.result).payload else {
            throw XCTSkip("response carried no gather result")
        }
        return result
    }
}
