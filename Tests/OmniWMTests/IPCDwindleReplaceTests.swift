// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class IPCDwindleReplaceTests: XCTestCase {
    private let sessionToken = "dwindle-replace-tests"
    private let authorizationToken = "dwindle-replace-authorization"
    private let windows = [1, 2, 3]
    private let lateWindow = 4
    private let monitor = NiriGatherFixture.monitor(displayId: 1)

    private func fixture() throws -> NiriGatherFixture {
        let fixture = try NiriGatherFixture(
            prefix: "dwindle-replace",
            monitors: [monitor],
            workspaces: [.init(name: "1", layoutType: .dwindle, monitor: monitor)]
        )
        let workspace = fixture.workspace("1")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(workspace, on: monitor.id))
        fixture.add(windows, to: workspace)
        return fixture
    }

    private func query(_ fixture: NiriGatherFixture) throws -> IPCDwindleTree {
        let router = IPCQueryRouter(controller: fixture.controller, appVersion: nil, sessionToken: sessionToken)
        var tree: IPCDwindleTree?
        if case let .dwindleTree(payload) = IPCResult(query: IPCQueryRequest(name: .dwindleTree), queryRouter: router)
            .payload
        {
            tree = payload.tree
        }
        return try XCTUnwrap(tree)
    }

    private func replace(_ fixture: NiriGatherFixture, _ tree: IPCDwindleTree) -> IPCResponse {
        IPCDwindleRequestExecutor(controller: fixture.controller, sessionToken: sessionToken)
            .response(for: IPCDwindleRequest(name: .replace, tree: tree), id: "replace")
    }

    private func edited(
        _ tree: IPCDwindleTree,
        workspaceId: String? = nil,
        revision: String? = nil,
        nodes: [IPCDwindleNode]? = nil
    ) -> IPCDwindleTree {
        IPCDwindleTree(
            workspaceId: workspaceId ?? tree.workspaceId,
            revision: revision ?? tree.revision,
            preselect: tree.preselect,
            nodes: nodes ?? tree.nodes
        )
    }

    private func edited(_ tree: IPCDwindleTree, replacing index: Int, with node: IPCDwindleNode) -> IPCDwindleTree {
        var nodes = tree.nodes
        nodes[index] = node
        return edited(tree, nodes: nodes)
    }

    private func rearranged(_ tree: IPCDwindleTree) throws -> IPCDwindleTree {
        var nodes = tree.nodes
        let leaves = nodes.indices.filter { nodes[$0].kind == .leaf }
        let first = try XCTUnwrap(leaves.first)
        let last = try XCTUnwrap(leaves.last)
        XCTAssertNotEqual(nodes[first], nodes[last])
        nodes.swapAt(first, last)
        let split = try XCTUnwrap(nodes.firstIndex { $0.kind == .split })
        let presets = DwindleSettings.splitRatioPresets.map { Double($0) }
        let ratio = try XCTUnwrap(presets.first { $0 != nodes[split].ratio })
        nodes[split] = try IPCDwindleNode(orientation: XCTUnwrap(nodes[split].orientation), ratio: ratio)
        return IPCDwindleTree(
            workspaceId: tree.workspaceId,
            revision: tree.revision,
            preselect: IPCDirection.allCases.first { $0 != tree.preselect },
            nodes: nodes
        )
    }

    private func node(_ json: String) throws -> IPCDwindleNode {
        try IPCWire.makeDecoder().decode(IPCDwindleNode.self, from: Data(json.utf8))
    }

    private func assertRefused(
        _ response: IPCResponse,
        _ code: IPCErrorCode,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response.kind, .dwindle, message, file: file, line: line)
        XCTAssertFalse(response.ok, message, file: file, line: line)
        XCTAssertEqual(response.status, .error, message, file: file, line: line)
        XCTAssertEqual(response.code, code, message, file: file, line: line)
        XCTAssertNil(response.result, message, file: file, line: line)
    }

    private func assertEachIsInvalid(
        in fixture: NiriGatherFixture,
        unchanged tree: IPCDwindleTree,
        _ cases: [(String, IPCDwindleTree)]
    ) throws {
        let sequence = fixture.manager.worldSeq
        for (name, invalid) in cases {
            assertRefused(replace(fixture, invalid), .invalidArguments, name)
        }
        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    private func rendered(_ result: IPCResult) throws -> String {
        let response = IPCResponse.success(id: "discovery", kind: .query, result: result)
        return try XCTUnwrap(String(data: CLIRenderer.responseOutput(response, format: .tsv).data, encoding: .utf8))
    }

    func testAReplacementOverTheSameWindowsIsExecutedAndReadBack() async throws {
        let fixture = try fixture()
        let before = try query(fixture)
        let replacement = try rearranged(before)
        let bridge = IPCApplicationBridge(
            controller: fixture.controller,
            appVersion: nil,
            sessionToken: sessionToken,
            authorizationToken: authorizationToken
        )
        let request = IPCRequest(
            id: "replace",
            dwindle: IPCDwindleRequest(name: .replace, tree: replacement),
            authorizationToken: authorizationToken
        )

        let response = await bridge.response(for: request)

        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.kind, .dwindle)
        XCTAssertTrue(response.ok, "unexpected code \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(response.status, .executed)
        XCTAssertNil(response.code)
        XCTAssertNil(response.result)
        let after = try query(fixture)
        XCTAssertEqual(after.workspaceId, before.workspaceId)
        XCTAssertEqual(after.nodes, replacement.nodes)
        XCTAssertEqual(after.preselect, replacement.preselect)
        XCTAssertNotEqual(after.revision, before.revision)
    }

    func testAnExactEchoChangesNothing() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let sequence = fixture.manager.worldSeq

        for revision in [tree.revision, tree.revision.lowercased()] {
            let response = replace(fixture, edited(tree, revision: revision))
            XCTAssertEqual(response.kind, .dwindle)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.status, .ignored)
            XCTAssertEqual(response.code, .noChange)
            XCTAssertNil(response.result)
        }

        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testAStaleRevisionIsRefusedAndChangesNothing() throws {
        let fixture = try fixture()
        let original = try query(fixture)
        XCTAssertEqual(try replace(fixture, rearranged(original)).status, .executed)
        let current = try query(fixture)
        let sequence = fixture.manager.worldSeq

        assertRefused(replace(fixture, original), .staleRevision)

        XCTAssertEqual(try query(fixture), current)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testWindowIDsFromAnotherSessionOrGarbageAreStale() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let sequence = fixture.manager.worldSeq
        let leaf = try XCTUnwrap(tree.nodes.firstIndex { $0.kind == .leaf })
        var members = try XCTUnwrap(tree.nodes[leaf].members)
        let active = try XCTUnwrap(tree.nodes[leaf].active)
        let window = try XCTUnwrap(
            IPCWindowOpaqueID.decode(members[members.startIndex], expectingSessionToken: sessionToken)
        )
        let foreign = IPCWindowOpaqueID.encode(
            pid: window.pid,
            windowId: window.windowId,
            sessionToken: "another-session"
        )

        for id in [foreign, "garbage"] {
            members[members.startIndex] = id
            let renamed = edited(tree, replacing: leaf, with: IPCDwindleNode(members: members, active: active))
            assertRefused(replace(fixture, renamed), .staleWindowId, id)
        }

        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testMalformedNodesAreInvalidArgumentsAndChangeNothing() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let split = try XCTUnwrap(tree.nodes.firstIndex { $0.kind == .split })
        let leaf = try XCTUnwrap(tree.nodes.lastIndex { $0.kind == .leaf })
        let orientation = try XCTUnwrap(tree.nodes[split].orientation).rawValue
        let ratio = try XCTUnwrap(tree.nodes[split].ratio)
        let members = try XCTUnwrap(tree.nodes[leaf].members)
        let active = try XCTUnwrap(tree.nodes[leaf].active)
        let ids = try String(decoding: JSONEncoder().encode(members), as: UTF8.self)
        func showing(_ active: Int) -> IPCDwindleTree {
            edited(tree, replacing: leaf, with: IPCDwindleNode(members: members, active: active))
        }

        try assertEachIsInvalid(in: fixture, unchanged: tree, [
            ("a split with one child", edited(tree, nodes: [tree.nodes[split], tree.nodes[leaf]])),
            (
                "a leaf without members",
                edited(tree, replacing: leaf, with: IPCDwindleNode(members: [], active: active))
            ),
            ("a zero active index", showing(0)),
            ("an active index past the last member", showing(members.count + 1)),
            ("the lowest active index", showing(.min)),
            ("the highest active index", showing(.max)),
            (
                "a split without a ratio",
                edited(tree, replacing: split, with: node(#"{"kind":"split","orientation":"\#(orientation)"}"#))
            ),
            (
                "a split with members",
                edited(tree, replacing: split, with: node(
                    #"{"kind":"split","orientation":"\#(orientation)","ratio":\#(ratio),"members":\#(ids)}"#
                ))
            ),
            (
                "a leaf with an orientation",
                edited(tree, replacing: leaf, with: node(
                    #"{"kind":"leaf","members":\#(ids),"active":\#(active),"orientation":"\#(orientation)"}"#
                ))
            )
        ])
    }

    func testARevisionOrWorkspaceIDThatDoesNotParseIsInvalid() throws {
        let fixture = try fixture()
        let tree = try query(fixture)

        try assertEachIsInvalid(in: fixture, unchanged: tree, [
            ("a short revision", edited(tree, revision: String(tree.revision.dropLast()))),
            ("a signed revision", edited(tree, revision: "+" + String(tree.revision.dropFirst()))),
            ("a revision that is not hex", edited(tree, revision: String(tree.revision.dropLast()) + "G")),
            ("a workspace ID that is not a UUID", edited(tree, workspaceId: String(tree.workspaceId.dropLast())))
        ])
    }

    func testDisabledAndOverviewRequestsAreIgnoredWithoutChanges() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let replacement = try rearranged(tree)
        let controller = fixture.controller

        controller.isEnabled = false
        let disabled = replace(fixture, replacement)
        XCTAssertEqual(try query(fixture), tree)
        controller.isEnabled = true
        controller.settings.animationsEnabled = false
        let overview: IPCResponse
        do {
            controller.toggleOverview()
            defer {
                if controller.isOverviewOpen() {
                    controller.toggleOverview()
                }
            }
            XCTAssertTrue(controller.isOverviewOpen())
            overview = replace(fixture, replacement)
            XCTAssertEqual(try query(fixture), tree)
        }

        for (response, code) in [(disabled, IPCErrorCode.disabled), (overview, .overviewOpen)] {
            XCTAssertEqual(response.kind, .dwindle)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.status, .ignored)
            XCTAssertEqual(response.code, code)
            XCTAssertNil(response.result)
        }
    }

    func testAnotherWorkspaceOrADifferentWindowSetIsRefused() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let sequence = fixture.manager.worldSeq
        let leaves = tree.nodes.indices.filter { tree.nodes[$0].kind == .leaf }
        let first = try XCTUnwrap(leaves.first)
        let last = try XCTUnwrap(leaves.last)

        assertRefused(replace(fixture, edited(tree, workspaceId: UUID().uuidString)), .wrongWorkspace)
        assertRefused(replace(fixture, edited(tree, nodes: [tree.nodes[first]])), .membershipMismatch)
        assertRefused(replace(fixture, edited(tree, replacing: last, with: tree.nodes[first])), .membershipMismatch)

        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testTheFocusedWindowMustStayTheShownTabOfItsGroup() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let focused = try fixture.token(XCTUnwrap(windows.first))
        let grouped = try fixture.token(XCTUnwrap(windows.last))
        fixture.manager.withEngineMutationScope(in: workspace) {
            XCTAssertTrue(engine.groupWindow(grouped, into: focused, in: workspace))
            _ = engine.activateWindow(focused, in: workspace)
        }
        XCTAssertEqual(engine.existingState(for: workspace)?.leafByToken[focused]?.tile?.activeToken, focused)
        XCTAssertTrue(fixture.manager.setManagedFocus(focused, in: workspace))
        XCTAssertEqual(fixture.manager.selectedManagedToken, focused)
        let tree = try query(fixture)
        let sequence = fixture.manager.worldSeq
        let group = try XCTUnwrap(tree.nodes.firstIndex { $0.members?.count == [focused, grouped].count })
        let members = try XCTUnwrap(tree.nodes[group].members)
        let shown = try XCTUnwrap(tree.nodes[group].active)
        let swapped = edited(tree, replacing: group, with: IPCDwindleNode(members: members.reversed(), active: shown))

        assertRefused(replace(fixture, swapped), .focusConflict)

        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testWindowsThatCannotFitOrBeTiledAreRefused() throws {
        let fixture = try fixture()
        let tree = try query(fixture)
        let replacement = try rearranged(tree)
        for window in windows {
            XCTAssertTrue(fixture.manager.setObservedSizeEvidence(
                ObservedSizeEvidence(minSize: monitor.visibleFrame.size), for: fixture.token(window)
            ))
        }
        let sequence = fixture.manager.worldSeq

        assertRefused(replace(fixture, replacement), .doesNotFit)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)

        XCTAssertTrue(try fixture.manager.setWindowMinimized(true, token: fixture.token(XCTUnwrap(windows.first))))
        let minimizedSequence = fixture.manager.worldSeq
        assertRefused(replace(fixture, replacement), .ineligibleWindow)

        XCTAssertEqual(try query(fixture), tree)
        XCTAssertEqual(fixture.manager.worldSeq, minimizedSequence)
    }

    func testAWorkspaceDwindleHasNotCaughtUpWithIsBusy() throws {
        let fixture = try fixture()
        let workspace = fixture.workspace("1")
        let tree = try query(fixture)
        _ = WindowAdmissionTestSupport.track(fixture.token(lateWindow), in: workspace, controller: fixture.controller)
        let sequence = fixture.manager.worldSeq

        assertRefused(replace(fixture, tree), .busy)

        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        XCTAssertEqual(fixture.controller.dwindleEngine?.windowCount(in: workspace), windows.count)
    }

    func testTheLargestTreeFitsOneRequestLine() throws {
        let session = UUID().uuidString
        let orientation = try XCTUnwrap(IPCResizeAxis.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count })
        let preselect = try XCTUnwrap(IPCDirection.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count })
        let split = IPCDwindleNode(
            orientation: orientation,
            ratio: Double(DwindleSettings.physicalRatios.upperBound.nextDown)
        )
        let leaves = (0 ..< DwindleLayoutEngine.treeMemberLimit).map { index in
            let members = [IPCWindowOpaqueID.encode(
                pid: pid_t.max - pid_t(index),
                windowId: Int(CGWindowID.max) - index,
                sessionToken: session
            )]
            return IPCDwindleNode(members: members, active: members.count)
        }
        let nodes = try leaves.dropLast().flatMap { [split, $0] } + [XCTUnwrap(leaves.last)]
        XCTAssertEqual(nodes.count, DwindleTreeRequest.nodeLimit)
        let request = IPCRequest(
            id: UUID().uuidString,
            dwindle: IPCDwindleRequest(name: .replace, tree: IPCDwindleTree(
                workspaceId: UUID().uuidString,
                revision: String(format: "%016llX", UInt64.max),
                preselect: preselect,
                nodes: nodes
            )),
            authorizationToken: UUID().uuidString
        )

        let line = try IPCWire.encodeRequestLine(request)

        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertLessThanOrEqual(line.count - 1, IPCConnection.maxRequestLineBytes)
        XCTAssertEqual(try IPCWire.decodeRequest(from: line), request)
        var reference = try IPCWire.makeEncoder().encode(request)
        reference.append(UInt8(ascii: "\n"))
        XCTAssertEqual(line, reference)
    }

    func testCommandsAndCapabilitiesDescribeTheReplaceRequest() throws {
        let fixture = try fixture()
        let router = IPCQueryRouter(controller: fixture.controller, appVersion: nil, sessionToken: sessionToken)
        let descriptors = IPCAutomationManifest.dwindleActionDescriptors
        let descriptor = try XCTUnwrap(descriptors.first)

        XCTAssertEqual(descriptors.map(\.name), IPCDwindleActionName.allCases)
        XCTAssertEqual(router.commandsResult().dwindleActions, descriptors)
        XCTAssertEqual(router.capabilitiesResult().dwindleActions, descriptors)
        let commands = try rendered(IPCResult(commands: router.commandsResult()))
        XCTAssertTrue(commands.contains("\(descriptor.path)\t\(descriptor.summary)\tdwindle"), commands)
        let capabilities = try rendered(IPCResult(capabilities: router.capabilitiesResult()))
        XCTAssertTrue(capabilities.contains("dwindle-actions\t\(descriptors.count)"), capabilities)
        XCTAssertEqual(IPCRequestKind.dwindle.rawValue, "dwindle")
        XCTAssertEqual(IPCResponseKind(requestKind: .dwindle), .dwindle)
        XCTAssertEqual(
            [IPCErrorCode.staleRevision, .wrongWorkspace, .membershipMismatch, .focusConflict, .busy].map(\.rawValue),
            ["stale_revision", "wrong_workspace", "membership_mismatch", "focus_conflict", "busy"]
        )
    }
}
