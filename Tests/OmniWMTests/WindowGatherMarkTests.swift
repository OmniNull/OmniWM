// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowGatherMarkTests: XCTestCase {
    private let sessionToken = "mark-gather-session"

    func testMarksResolveInOrderAndUseOneAtomicGatherWithoutNavigation() async throws {
        let fixture = try makeFixture(75_201)
        let manager = fixture.manager
        let active = fixture.workspace("1")
        let destination = fixture.workspace("3")
        XCTAssertTrue(manager.setActiveWorkspace(active, on: fixture.monitors[0].id))
        fixture.add([1, 11], to: active)
        fixture.add([2], to: fixture.workspace("2"))
        fixture.add([3], to: destination)
        _ = manager.setManagedFocus(fixture.token(11), in: active, onMonitor: fixture.monitors[0].id)
        for (name, number) in [("editor", 1), ("chat", 2), ("local", 3)] {
            XCTAssertEqual(fixture.controller.windowMarkRegistry.set(name, for: fixture.token(number)), .inserted)
        }
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let focus = manager.focusSessionSnapshot
        let marks = fixture.controller.windowMarkRegistry.marks
        let sequence = fixture.lastTraceSequence()
        let refresh = fixture.controller.layoutRefreshController
        refresh.beginPerformanceCapture()

        let response = try execute(fixture, names: ["chat", "editor", "local"])
        XCTAssertTrue(response.ok)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .gathered)
        XCTAssertEqual(result.windows.map(\.windowId), [2, 1, 3].map { windowId(fixture.token($0)) })
        XCTAssertEqual(result.moved, [2, 1, 3].map { windowId(fixture.token($0)) })
        XCTAssertEqual(fixture.layout(destination), [[2, 1, 3]])
        let rows = try windowRows(response)
        XCTAssertEqual(rows.compactMap { $0["markName"] as? String }, ["chat", "editor", "local"])
        let lines = fixture.traceLines(after: sequence)
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.first?.contains("event=user_command label=niri_gather") == true)
        XCTAssertEqual(refresh.performanceSnapshot()?.refreshesEnqueued, 1)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitors[0].id)?.id, active)
        XCTAssertEqual(manager.focusSessionSnapshot.nativeFocusOwner, focus.nativeFocusOwner)
        XCTAssertEqual(manager.focusSessionSnapshot.selectedManagedToken, focus.selectedManagedToken)
        XCTAssertEqual(manager.focusSessionSnapshot.pendingManagedFocus, focus.pendingManagedFocus)
        XCTAssertEqual(fixture.controller.windowMarkRegistry.marks, marks)

        let repeatSequence = manager.worldSeq
        let repeated = try execute(fixture, names: ["chat", "editor", "local"])
        XCTAssertEqual(repeated.code, .noChange)
        XCTAssertEqual(try gatherResult(repeated).outcome, .unchanged)
        XCTAssertEqual(manager.worldSeq, repeatSequence)
        XCTAssertEqual(refresh.endPerformanceCapture()?.refreshesEnqueued, 1)
    }

    func testResolutionFailuresAndAliasesRefuseAllWithoutPruningOrPublishing() throws {
        let fixture = try makeFixture(75_202)
        fixture.add([1, 2], to: fixture.workspace("1"))
        XCTAssertTrue(fixture.manager.setWindowMinimized(true, token: fixture.token(2)))
        let registry = fixture.controller.windowMarkRegistry
        for (name, number) in [("editor", 1), ("alias", 1), ("stale", 9), ("minimized", 2)] {
            XCTAssertEqual(registry.set(name, for: fixture.token(number)), .inserted)
        }
        let names = [" editor ", "missing", "\u{0001}", "stale", "editor", "alias", "minimized"]
        let marks = registry.marks
        let sequence = fixture.manager.worldSeq
        let trace = fixture.manager.reconcileTraceDump()
        let layout = fixture.layout(fixture.workspace("1"))
        let refresh = fixture.controller.layoutRefreshController
        refresh.beginPerformanceCapture()

        let response = try execute(fixture, names: names)
        XCTAssertEqual(response.code, .unknownMark)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(result.reason, .windowRefused)
        XCTAssertEqual(
            result.windows.map(\.status),
            [.blocked, .unresolved, .unresolved, .unresolved, .refused, .refused, .refused]
        )
        let rows = try windowRows(response)
        XCTAssertEqual(rows.compactMap { $0["markName"] as? String }, names)
        XCTAssertEqual(
            rows.map { $0["reason"] as? String },
            [nil, "unknown_mark", "invalid_mark", "stale_mark", "duplicate_window", "duplicate_window", "minimized"]
        )
        for index in [1, 2, 3] {
            XCTAssertNil(rows[index]["windowId"], "unresolved marks must not fabricate IDs")
        }
        XCTAssertEqual(result.moved, [])
        XCTAssertEqual(result.relayoutWorkspaces, [])
        XCTAssertFalse(result.modelCommitted)
        XCTAssertFalse(result.relayoutRequested)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        XCTAssertEqual(fixture.manager.reconcileTraceDump(), trace)
        XCTAssertEqual(fixture.layout(fixture.workspace("1")), layout)
        XCTAssertEqual(registry.marks, marks)
        XCTAssertEqual(refresh.endPerformanceCapture()?.refreshesEnqueued, 0)

        for (name, code) in [("missing", IPCErrorCode.unknownMark), ("\u{0001}", .invalidMark), ("stale", .staleMark)] {
            XCTAssertEqual(try execute(fixture, names: [name]).code, code)
        }
        XCTAssertEqual(try execute(fixture, names: ["editor", "editor"]).code, .invalidArguments)
        XCTAssertEqual(try execute(fixture, names: ["editor", "alias"]).code, .invalidArguments)
        XCTAssertEqual(try execute(fixture, names: ["minimized"]).code, .ineligibleWindow)
        XCTAssertEqual(registry.marks, marks)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testMarkPayloadRoundTripAndExclusiveSelectorKeys() throws {
        let request = try decode(["markNames": ["editor", "chat"], "workspaceTarget": target])
        let encoded = try IPCWire.encodeRequestLine(request)
        XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCRequest.self, from: encoded), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["markNames"] as? [String], ["editor", "chat"])
        XCTAssertNil(payload["windowIds"])
        for payload: [String: Any] in [
            ["workspaceTarget": target],
            ["markNames": [], "windowIds": [], "workspaceTarget": target],
            ["markNames": NSNull(), "workspaceTarget": target],
            ["markNames": [1], "workspaceTarget": target]
        ] {
            XCTAssertThrowsError(try decode(payload))
        }
        let fixture = try makeFixture(75_203)
        let empty = try execute(fixture, names: [])
        XCTAssertEqual(try gatherResult(empty).reason, .noWindows)
    }

    func testBridgeDispatchesNativeMarkRequestAndRoundTripsRequiredCapabilities() async throws {
        let fixture = try makeFixture(75_204)
        fixture.add([1, 2], to: fixture.workspace("1"))
        let registry = fixture.controller.windowMarkRegistry
        XCTAssertEqual(registry.set("editor", for: fixture.token(1)), .inserted)
        XCTAssertEqual(registry.set("chat", for: fixture.token(2)), .inserted)
        let bridge = IPCApplicationBridge(
            controller: fixture.controller,
            appVersion: "0.0.0-test",
            sessionToken: sessionToken,
            authorizationToken: "token"
        )
        let request = IPCRequest(
            id: "bridge-mark-gather",
            windowGather: IPCWindowGatherRequest(markNames: ["chat", "editor"], workspaceTarget: .rawID("3")),
            authorizationToken: "token"
        )
        let decoded = try IPCWire.decodeRequest(from: IPCWire.encodeRequestLine(request))
        XCTAssertEqual(decoded, request)
        let response = await bridge.response(for: decoded)
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.kind, .windowGather)
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(try gatherResult(response).windows.map(\.markName), ["chat", "editor"])
        XCTAssertEqual(fixture.layout(fixture.workspace("3")), [[2, 1]])

        let capabilitiesResponse = await bridge.response(for: IPCRequest(
            id: "capabilities",
            query: IPCQueryRequest(name: .capabilities),
            authorizationToken: "token"
        ))
        guard case let .capabilities(capabilities) = try XCTUnwrap(capabilitiesResponse.result).payload else {
            return XCTFail("expected capabilities")
        }
        XCTAssertEqual(capabilities.protocolVersion, 21)
        XCTAssertEqual(capabilities.windowGatherActions.first?.arguments, ["windowIds", "markNames", "workspaceTarget"])
        let data = try IPCWire.makeEncoder().encode(capabilities)
        XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCCapabilitiesQueryResult.self, from: data), capabilities)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "windowGatherActions")
        let missing = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try IPCWire.makeDecoder().decode(IPCCapabilitiesQueryResult.self, from: missing))
    }

    private var target: [String: String] {
        ["kind": "raw-id", "value": "3"]
    }

    private func decode(_ payload: [String: Any]) throws -> IPCRequest {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": OmniWMIPCProtocol.version, "id": "marks-gather", "kind": "window-gather", "payload": payload
        ])
        return try IPCWire.makeDecoder().decode(IPCRequest.self, from: data)
    }

    private func execute(_ fixture: NiriGatherFixture, names: [String]) throws -> IPCResponse {
        guard case let .windowGather(request) = try decode(["markNames": names, "workspaceTarget": target]).payload
        else {
            throw XCTUnwrapError()
        }
        return IPCWindowGatherRequestExecutor(controller: fixture.controller, sessionToken: sessionToken)
            .response(for: request, id: "marks-gather")
    }

    private func makeFixture(_ displayId: UInt32) throws -> NiriGatherFixture {
        try NiriGatherFixture(
            prefix: "OmniWMWindowGatherMarks",
            monitors: [NiriGatherFixture.monitor(displayId: displayId)],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3")]
        )
    }

    private func windowId(_ token: WindowToken) -> String {
        IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }

    private func gatherResult(_ response: IPCResponse) throws -> IPCWindowGatherResult {
        guard case let .windowGather(result) = try XCTUnwrap(response.result).payload else {
            throw XCTUnwrapError()
        }
        return result
    }

    private func windowRows(_ response: IPCResponse) throws -> [[String: Any]] {
        let data = try IPCWire.encodeResponseLine(response)
        XCTAssertEqual(try IPCWire.makeDecoder().decode(IPCResponse.self, from: data), response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let payload = try XCTUnwrap(result["payload"] as? [String: Any])
        return try XCTUnwrap(payload["windows"] as? [[String: Any]])
    }

    private struct XCTUnwrapError: Error {}
}
