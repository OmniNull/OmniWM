// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowGatherIPCContractTests: XCTestCase {
    private enum TestFailure: Error {
        case missingGatherResult
    }

    private let sessionToken = "gather-session"

    func testRequestNeedsWindowIdsAndAKnownReachOnTheWire() throws {
        for reach in IPCWindowGatherReach.allCases {
            let request = IPCRequest(
                id: "gather",
                windowGather: IPCWindowGatherRequest(windowIds: ["ow_b", "ow_a"], from: reach)
            )
            let line = try IPCWire.encodeRequestLine(request)
            let json = String(decoding: line, as: UTF8.self)
            XCTAssertTrue(json.contains(#""kind":"window-gather""#), json)
            XCTAssertTrue(json.contains(#""payload":{"from":"\#(reach.rawValue)","windowIds":["ow_b","ow_a"]}"#), json)
            XCTAssertEqual(try IPCWire.decodeRequest(from: line), request)
        }
        let invalidPayloads = [
            #"{"windowIds":["ow_a"]}"#,
            #"{"windowIds":["ow_a"],"from":"everywhere"}"#,
            #"{"from":"all"}"#
        ]
        for payload in invalidPayloads {
            let version = OmniWMIPCProtocol.version
            let line = Data(#"{"version":\#(version),"id":"gather","kind":"window-gather","payload":\#(payload)}"#.utf8)
            XCTAssertThrowsError(try IPCWire.decodeRequest(from: line), payload)
        }
        XCTAssertEqual(IPCRequestKind.windowGather.rawValue, "window-gather")
        XCTAssertEqual(IPCResponseKind(requestKind: .windowGather), .windowGather)
        XCTAssertEqual(IPCResultKind.windowGather.rawValue, "window-gather")
        XCTAssertEqual(IPCErrorCode.ineligibleWindow.rawValue, "ineligible_window")
        XCTAssertEqual(IPCErrorCode.doesNotFit.rawValue, "does_not_fit")
    }

    func testCommandsAndCapabilitiesDiscoverTheGatherDescriptor() throws {
        let fixture = try makeFixture(displayId: 75_100)
        let router = IPCQueryRouter(controller: fixture.controller, appVersion: "test", sessionToken: sessionToken)
        let descriptors = IPCAutomationManifest.windowGatherActionDescriptors

        XCTAssertEqual(descriptors.map(\.path), ["window gather [--from workspace|monitor|all] <window-id>..."])
        XCTAssertEqual(descriptors.map(\.arguments), [["window-id..."]])
        XCTAssertEqual(router.commandsResult().windowGatherActions, descriptors)
        XCTAssertEqual(router.capabilitiesResult().windowGatherActions, descriptors)
        XCTAssertEqual(router.commandsResult().windowMarkActions, IPCAutomationManifest.windowMarkActionDescriptors)
    }

    func testDisabledAndOverviewStatesAreIgnoredWithoutAResult() throws {
        let fixture = try makeFixture(displayId: 75_101)
        let workspace = fixture.workspace("1")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(workspace, on: fixture.monitors[0].id))
        fixture.add([1, 2], to: workspace)
        let ids = [id(1, fixture), id(2, fixture)]
        let controller = fixture.controller

        controller.isEnabled = false
        let disabled = execute(fixture, ids, from: .workspace)
        controller.isEnabled = true
        controller.settings.animationsEnabled = false
        controller.toggleOverview()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
        }
        XCTAssertTrue(controller.isOverviewOpen())
        let overview = execute(fixture, ids, from: .workspace)

        for (response, code) in [(disabled, IPCErrorCode.disabled), (overview, .overviewOpen)] {
            XCTAssertEqual(response.kind, .windowGather)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.status, .ignored)
            XCTAssertEqual(response.code, code)
            XCTAssertNil(response.result)
        }
        XCTAssertEqual(fixture.layout(workspace), [[1], [2]])
    }

    func testGatherReportsOrderedStatusesAndARepeatIsUnchanged() throws {
        let fixture = try makeFixture(displayId: 75_102)
        let destination = fixture.workspace("1")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(destination, on: fixture.monitors[0].id))
        fixture.add([1, 2], to: destination)
        fixture.add([3], to: fixture.workspace("2"))
        fixture.select(1, in: destination)
        let ids = [1, 3, 2].map { id($0, fixture) }

        let outside = try gatherResult(execute(fixture, ids, from: .workspace))
        XCTAssertEqual(outside.windows.map(\.reason), [nil, .outsideReach, nil])

        let response = execute(fixture, ids, from: .monitor)
        XCTAssertTrue(response.ok, "unexpected code \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(response.kind, .windowGather)
        XCTAssertEqual(response.status, .executed)
        XCTAssertNil(response.code)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .gathered)
        XCTAssertEqual(result.workspace?.rawName, "1")
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.windows, [
            .init(windowId: ids[0], status: .unchanged),
            .init(windowId: ids[1], status: .moved),
            .init(windowId: ids[2], status: .moved)
        ])
        XCTAssertEqual(fixture.layout(destination), [[1, 3, 2]])
        XCTAssertEqual(fixture.layout(fixture.workspace("2")), [])

        let sequence = fixture.manager.worldSeq
        let repeated = execute(fixture, ids, from: .all)
        XCTAssertFalse(repeated.ok)
        XCTAssertEqual(repeated.status, .ignored)
        XCTAssertEqual(repeated.code, .noChange)
        let repeatedResult = try gatherResult(repeated)
        XCTAssertEqual(repeatedResult.outcome, .unchanged)
        XCTAssertEqual(repeatedResult.workspace?.rawName, "1")
        XCTAssertEqual(repeatedResult.windows.map(\.status), [.unchanged, .unchanged, .unchanged])
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testAllReachTakesWindowsFromAnotherMonitor() throws {
        let left = NiriGatherFixture.monitor(displayId: 75_103)
        let right = NiriGatherFixture.monitor(displayId: 75_104, x: 1_200)
        let fixture = try NiriGatherFixture(
            prefix: "OmniWMWindowGatherIPC",
            monitors: [left, right],
            workspaces: [.init(name: "1", monitor: left), .init(name: "2", monitor: right)]
        )
        let destination = fixture.workspace("1")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(destination, on: left.id))
        XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace("2"), on: right.id))
        fixture.manager.setInteractionMonitor(left.id)
        fixture.add([1], to: destination)
        fixture.add([2], to: fixture.workspace("2"))
        let ids = [2, 1].map { id($0, fixture) }

        let monitorReach = try gatherResult(execute(fixture, ids, from: .monitor))
        XCTAssertEqual(monitorReach.windows.map(\.status), [.refused, .blocked])
        XCTAssertEqual(monitorReach.windows.first?.reason, .outsideReach)

        let response = execute(fixture, ids, from: .all)
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(try gatherResult(response).windows.map(\.status), [.moved, .moved])
        XCTAssertEqual(fixture.layout(destination), [[2, 1]])
        XCTAssertEqual(fixture.layout(fixture.workspace("2")), [])
    }

    func testInvalidInputsRefuseEverythingWithPerInputReasonsInRequestOrder() throws {
        let fixture = try makeFixture(displayId: 75_105)
        let manager = fixture.manager
        let destination = fixture.workspace("1")
        XCTAssertTrue(manager.setActiveWorkspace(destination, on: fixture.monitors[0].id))
        fixture.add([1, 2, 3], to: destination)
        fixture.add([4], to: fixture.workspace("2"))
        XCTAssertTrue(manager.updateScratchpadMembership(fixture.token(2), to: 1, notify: false))
        manager.setAppHidden(true, pid: fixture.token(3).pid, source: .workspaceManager)
        let valid = id(1, fixture)
        let stale = IPCWindowOpaqueID.encode(
            pid: fixture.token(1).pid,
            windowId: fixture.token(1).windowId,
            sessionToken: "previous-session"
        )
        let sequence = manager.worldSeq
        let layout = fixture.layout(destination)

        let response = execute(
            fixture,
            [valid, "garbage", stale, valid, id(2, fixture), id(4, fixture), id(9, fixture), id(3, fixture)],
            from: .workspace
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.code, .invalidArguments)
        let result = try gatherResult(response)
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(result.reason, .windowRefused)
        XCTAssertEqual(result.workspace?.rawName, "1")
        XCTAssertEqual(result.windows, [
            .init(windowId: valid, status: .blocked),
            .init(windowId: "garbage", status: .unresolved, reason: .invalidWindowId),
            .init(windowId: stale, status: .unresolved, reason: .staleWindowId),
            .init(windowId: valid, status: .refused, reason: .duplicateWindow),
            .init(windowId: id(2, fixture), status: .refused, reason: .scratchpad),
            .init(windowId: id(4, fixture), status: .refused, reason: .outsideReach),
            .init(windowId: id(9, fixture), status: .unresolved, reason: .notFound),
            .init(windowId: id(3, fixture), status: .refused, reason: .appHidden)
        ])
        XCTAssertEqual(execute(fixture, [stale, valid], from: .workspace).code, .staleWindowId)
        XCTAssertEqual(execute(fixture, [id(9, fixture), valid], from: .workspace).code, .notFound)
        XCTAssertEqual(execute(fixture, [valid, id(4, fixture)], from: .workspace).code, .ineligibleWindow)
        XCTAssertEqual(manager.worldSeq, sequence)
        XCTAssertEqual(fixture.layout(destination), layout)
    }

    func testEligibilityReasonsMapToTheirWireReasonsAndTheFirstCode() throws {
        let fixture = try makeFixture(
            displayId: 75_106,
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3", layoutType: .dwindle)]
        )
        let manager = fixture.manager
        let destination = fixture.workspace("1")
        XCTAssertTrue(manager.setActiveWorkspace(destination, on: fixture.monitors[0].id))
        fixture.add([1, 2, 3, 4, 5, 6], to: destination)
        fixture.add([7], to: fixture.workspace("3"))
        XCTAssertTrue(manager.setWindowMinimized(true, token: fixture.token(2)))
        XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: fixture.token(3)))
        XCTAssertTrue(manager.setWindowMode(.floating, for: fixture.token(4)))
        manager.setLayoutReason(.nativeFullscreen, for: fixture.token(5))
        manager.withEngineMutationScope {
            fixture.node(6, in: destination)?.sizingMode = .fullscreen
        }
        let sequence = manager.worldSeq
        let ids = (1 ... 7).map { id($0, fixture) }

        let response = execute(fixture, ids, from: .all)

        XCTAssertEqual(response.code, .ineligibleWindow)
        let result = try gatherResult(response)
        XCTAssertEqual(result.reason, .windowRefused)
        XCTAssertEqual(result.windows.map(\.status), [.blocked] + Array(repeating: .refused, count: 6))
        XCTAssertEqual(
            result.windows.map(\.reason),
            [nil, .minimized, .nativeWithdrawn, .floating, .nativeFullscreen, .layoutFullscreen, .unsupportedLayout]
        )
        XCTAssertEqual(execute(fixture, [ids[6], ids[1]], from: .all).code, .unsupportedLayout)
        XCTAssertEqual(manager.worldSeq, sequence)
    }

    func testDestinationAndFitRefusalsBlockEveryInput() throws {
        let fixture = try makeFixture(
            displayId: 75_107,
            workspaces: [.init(name: "1"), .init(name: "2", layoutType: .dwindle)]
        )
        let manager = fixture.manager
        let destination = fixture.workspace("1")
        XCTAssertTrue(manager.setActiveWorkspace(destination, on: fixture.monitors[0].id))
        fixture.add([1, 2], to: destination, minHeight: 500)
        let ids = [1, 2].map { id($0, fixture) }
        let sequence = manager.worldSeq

        let tooTall = execute(fixture, ids, from: .workspace)
        XCTAssertEqual(tooTall.code, .doesNotFit)
        XCTAssertEqual(try gatherResult(tooTall).reason, .doesNotFit)
        XCTAssertEqual(try gatherResult(tooTall).windows.map(\.status), [.blocked, .blocked])

        let empty = execute(fixture, [], from: .workspace)
        XCTAssertEqual(empty.code, .invalidArguments)
        XCTAssertEqual(try gatherResult(empty).reason, .noWindows)
        XCTAssertEqual(try gatherResult(empty).workspace?.rawName, "1")
        XCTAssertEqual(try gatherResult(empty).windows, [])

        XCTAssertEqual(manager.worldSeq, sequence)
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspace("2"), on: fixture.monitors[0].id))
        let dwindleSequence = manager.worldSeq
        let dwindle = execute(fixture, ids, from: .all)
        XCTAssertEqual(dwindle.code, .unsupportedLayout)
        XCTAssertEqual(try gatherResult(dwindle).reason, .unsupportedLayout)
        XCTAssertEqual(try gatherResult(dwindle).workspace?.rawName, "2")
        XCTAssertEqual(try gatherResult(dwindle).windows.map(\.status), [.blocked, .blocked])
        XCTAssertEqual(manager.worldSeq, dwindleSequence)
        XCTAssertEqual(fixture.layout(destination), [[1], [2]])
    }

    func testBridgeDispatchesWithItsSessionTokenAndRequiresAuthorization() async throws {
        let fixture = try makeFixture(displayId: 75_108)
        let destination = fixture.workspace("1")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(destination, on: fixture.monitors[0].id))
        fixture.add([1], to: destination)
        fixture.add([2], to: fixture.workspace("2"))
        let bridge = IPCApplicationBridge(
            controller: fixture.controller,
            appVersion: "0.0.0-test",
            sessionToken: sessionToken,
            authorizationToken: "token"
        )
        let ids = [2, 1].map { id($0, fixture) }
        let gather = IPCWindowGatherRequest(windowIds: ids, from: .monitor)

        let unauthorized = await bridge.response(
            for: IPCRequest(id: "bridge-gather", windowGather: gather, authorizationToken: "wrong")
        )
        XCTAssertEqual(unauthorized.kind, .windowGather)
        XCTAssertEqual(unauthorized.code, .unauthorized)
        XCTAssertEqual(fixture.layout(destination), [[1]])

        let foreign = IPCWindowOpaqueID.encode(
            pid: fixture.token(1).pid,
            windowId: fixture.token(1).windowId,
            sessionToken: "other-session"
        )
        let stale = await bridge.response(for: IPCRequest(
            id: "bridge-gather",
            windowGather: IPCWindowGatherRequest(windowIds: [foreign], from: .monitor),
            authorizationToken: "token"
        ))
        XCTAssertEqual(stale.code, .staleWindowId)

        let response = await bridge.response(
            for: IPCRequest(id: "bridge-gather", windowGather: gather, authorizationToken: "token")
        )
        XCTAssertEqual(response.id, "bridge-gather")
        XCTAssertEqual(response.kind, .windowGather)
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(try gatherResult(response).outcome, .gathered)
        XCTAssertEqual(fixture.layout(destination), [[2, 1]])
    }

    private func makeFixture(
        displayId: UInt32,
        workspaces: [NiriGatherFixture.WorkspaceSpec] = [.init(name: "1"), .init(name: "2")]
    ) throws -> NiriGatherFixture {
        try NiriGatherFixture(
            prefix: "OmniWMWindowGatherIPC",
            monitors: [NiriGatherFixture.monitor(displayId: displayId)],
            workspaces: workspaces
        )
    }

    private func id(_ window: Int, _ fixture: NiriGatherFixture) -> String {
        let token = fixture.token(window)
        return IPCWindowOpaqueID.encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }

    private func execute(
        _ fixture: NiriGatherFixture,
        _ ids: [String],
        from reach: IPCWindowGatherReach
    ) -> IPCResponse {
        IPCWindowGatherRequestExecutor(controller: fixture.controller, sessionToken: sessionToken).response(
            for: IPCWindowGatherRequest(windowIds: ids, from: reach),
            id: "gather"
        )
    }

    private func gatherResult(_ response: IPCResponse) throws -> IPCWindowGatherResult {
        guard case let .windowGather(result)? = response.result?.payload else {
            XCTFail("response \(response.code?.rawValue ?? "ok") carried no gather result")
            throw TestFailure.missingGatherResult
        }
        return result
    }
}
