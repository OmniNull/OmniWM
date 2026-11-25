// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class IPCDwindleTreeQueryTests: XCTestCase {
    private let sessionToken = "dwindle-tree-tests"
    private let monitor = NiriGatherFixture.monitor(displayId: 1)

    private func fixture(_ layouts: [LayoutType]) throws -> NiriGatherFixture {
        let fixture = try NiriGatherFixture(
            prefix: "dwindle-tree",
            monitors: [monitor],
            workspaces: layouts.enumerated().map { index, layout in
                NiriGatherFixture.WorkspaceSpec(name: String(index + 1), layoutType: layout, monitor: monitor)
            }
        )
        XCTAssertTrue(fixture.manager.setActiveWorkspace(fixture.workspace("1"), on: monitor.id))
        return fixture
    }

    private func groupedFixture() throws -> NiriGatherFixture {
        let fixture = try fixture([.dwindle])
        let workspace = fixture.workspace("1")
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        fixture.add([1, 2, 3, 4], to: workspace)
        fixture.manager.withEngineMutationScope(in: workspace) {
            XCTAssertTrue(engine.groupWindow(fixture.token(4), into: fixture.token(3), in: workspace))
        }
        let tile = try XCTUnwrap(engine.existingState(for: workspace)?.leafByToken[fixture.token(3)]?.tile)
        let last = try XCTUnwrap(tile.members.last?.token)
        XCTAssertNotEqual(last, tile.members.first?.token)
        fixture.manager.withEngineMutationScope(in: workspace) {
            _ = engine.activateWindow(last, in: workspace)
            XCTAssertTrue(engine.setPreselection(.right, in: workspace))
        }
        XCTAssertEqual(tile.activeToken, last)
        return fixture
    }

    private func query(_ fixture: NiriGatherFixture) -> IPCDwindleTreeQueryResult? {
        let router = IPCQueryRouter(controller: fixture.controller, appVersion: nil, sessionToken: sessionToken)
        let result = IPCResult(query: IPCQueryRequest(name: .dwindleTree), queryRouter: router)
        guard case let .dwindleTree(payload) = result.payload else { return nil }
        return payload
    }

    func testTheTreeFollowsTheLayoutSnapshotWithItsTabsAndPreselect() throws {
        let fixture = try groupedFixture()
        let workspace = fixture.workspace("1")
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let snapshot = try XCTUnwrap(fixture.manager.withEngineMutationScope(in: workspace) {
            engine.layoutSnapshot(in: workspace)
        })
        let expected = try snapshot.nodes.map { node throws -> IPCDwindleNode in
            if let orientation = node.orientation {
                let axis: IPCResizeAxis = orientation == .vertical ? .vertical : .horizontal
                return IPCDwindleNode(orientation: axis, ratio: node.ratio)
            }
            let members = snapshot.members[node.members]
            let active = try XCTUnwrap(members.firstIndex { $0.token == node.active })
            return IPCDwindleNode(
                members: members.map { IPCWindowOpaqueID.encode(token: $0.token, sessionToken: sessionToken) },
                active: active - members.startIndex + 1
            )
        }
        var hasher = Hasher()
        hasher.combine(sessionToken)
        let read = engine.readTree(
            in: workspace, hasher: hasher,
            admission: { fixture.manager.windowQueries.tiledAdmission(of: $0, in: workspace) },
            split: { _, _ in true }, leaf: { _, _ in true }
        )
        guard case let .read(_, revision) = read else { return XCTFail("Expected the engine to read the tree") }

        let result = try XCTUnwrap(query(fixture))
        let tree = try XCTUnwrap(result.tree)
        XCTAssertEqual(tree.nodes, expected)
        XCTAssertEqual(tree.preselect, .right)
        XCTAssertEqual(tree.workspaceId, workspace.uuidString)
        XCTAssertEqual(result.workspace?.id, workspace.uuidString)
        XCTAssertFalse(result.tooLarge)
        XCTAssertEqual(tree.revision, String(format: "%016llX", revision))
        XCTAssertEqual(tree.revision.count, UInt64.bitWidth / 4)
        XCTAssertTrue(tree.revision.allSatisfy { $0.isHexDigit && !$0.isLowercase })
        XCTAssertEqual(query(fixture), result)
    }

    func testOtherLayoutsAndUnsyncedWindowsHaveNoTreeAndAnEmptyWorkspaceHasNoNodes() throws {
        let fixture = try fixture([.dwindle, .niri])
        let dwindle = fixture.workspace("1")
        let empty = try XCTUnwrap(query(fixture))
        let emptyTree = try XCTUnwrap(empty.tree)
        XCTAssertEqual(emptyTree.nodes, [])
        XCTAssertNil(emptyTree.preselect)
        XCTAssertEqual(emptyTree.workspaceId, dwindle.uuidString)
        XCTAssertEqual(emptyTree.revision.count, UInt64.bitWidth / 4)
        XCTAssertFalse(empty.tooLarge)

        _ = WindowAdmissionTestSupport.track(fixture.token(1), in: dwindle, controller: fixture.controller)
        XCTAssertEqual(fixture.controller.dwindleEngine?.existingState(for: dwindle)?.tileCount ?? 0, 0)
        let unsynced = try XCTUnwrap(query(fixture))
        XCTAssertEqual(unsynced.workspace?.id, dwindle.uuidString)
        XCTAssertNil(unsynced.tree)
        XCTAssertFalse(unsynced.tooLarge)

        let niri = fixture.workspace("2")
        XCTAssertTrue(fixture.manager.setActiveWorkspace(niri, on: monitor.id))
        let other = try XCTUnwrap(query(fixture))
        XCTAssertEqual(other.workspace?.id, niri.uuidString)
        XCTAssertNil(other.tree)
        XCTAssertFalse(other.tooLarge)
    }

    func testATreeOverTheMemberLimitIsTooLarge() throws {
        let fixture = try fixture([.dwindle])
        let workspace = fixture.workspace("1")
        let limit = DwindleLayoutEngine.treeMemberLimit
        fixture.add(Array(1 ... limit), to: workspace)
        let full = try XCTUnwrap(query(fixture))
        XCTAssertEqual(full.tree?.nodes.reduce(0) { $0 + ($1.members?.count ?? 0) }, limit)
        XCTAssertFalse(full.tooLarge)

        fixture.add([limit + 1], to: workspace)
        let over = try XCTUnwrap(query(fixture))
        XCTAssertEqual(over.workspace?.id, workspace.uuidString)
        XCTAssertNil(over.tree)
        XCTAssertTrue(over.tooLarge)
    }

    func testTheResultRoundTripsOnTheWireAsSplitAndLeafNodes() throws {
        let result = try XCTUnwrap(query(groupedFixture()))
        let response = IPCResponse.success(id: "dwindle-tree", kind: .query, result: IPCResult(dwindleTree: result))
        let line = try IPCWire.encodeResponseLine(response)
        XCTAssertEqual(try IPCWire.decodeResponse(from: line), response)
        for pretty in [false, true] {
            var reference = try IPCWire.makeEncoder(prettyPrinted: pretty).encode(response)
            reference.append(0x0A)
            XCTAssertEqual(try IPCWire.encodeResponseLine(response, prettyPrinted: pretty), reference)
        }

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let wire = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(wire["kind"] as? String, "dwindle-tree")
        let payload = try XCTUnwrap(wire["payload"] as? [String: Any])
        let tree = try XCTUnwrap(payload["tree"] as? [String: Any])
        let nodes = try XCTUnwrap(tree["nodes"] as? [[String: Any]])
        XCTAssertEqual(
            Set(nodes.map { Set($0.keys) }),
            [["kind", "orientation", "ratio"], ["kind", "members", "active"]]
        )
    }

    func testTheCLIParsesCompletesAndRendersTheQuery() throws {
        let descriptor = try XCTUnwrap(IPCAutomationManifest.queryDescriptor(for: .dwindleTree))
        XCTAssertTrue(descriptor.selectors.isEmpty)
        XCTAssertTrue(descriptor.fields.isEmpty)
        XCTAssertNil(IPCQuerySelection.validate(IPCQueryRequest(name: .dwindleTree), sessionToken: sessionToken))
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "dwindle-tree"])
        guard case let .query(request) = parsed.request.payload else {
            return XCTFail("Expected a query payload")
        }
        XCTAssertEqual(request, IPCQueryRequest(name: .dwindleTree))
        XCTAssertEqual(parsed.outputFormat, .json)
        XCTAssertTrue(CLICompletionSelector.suggestions(words: ["omniwmctl", "query", ""]).contains("dwindle-tree"))

        let tree = IPCDwindleTree(
            workspaceId: UUID().uuidString,
            revision: String(format: "%016llX", UInt64.max),
            preselect: .left,
            nodes: [
                IPCDwindleNode(orientation: .vertical, ratio: 1),
                IPCDwindleNode(members: ["first"], active: 1),
                IPCDwindleNode(members: ["second", "third"], active: 2)
            ]
        )
        let rows = [
            "KIND\tORIENTATION\tRATIO\tACTIVE\tMEMBERS",
            "split\tvertical\t1.00\t-\t-",
            "leaf\t-\t-\t1\tfirst",
            "leaf\t-\t-\t2\tsecond, third"
        ]
        let result = IPCDwindleTreeQueryResult(workspace: nil, tree: tree, tooLarge: false)
        XCTAssertEqual(try rendered(result, format: .tsv).components(separatedBy: "\n"), rows)
        let header = "\(tree.workspaceId): revision \(tree.revision), preselect left\n"
        XCTAssertTrue(try rendered(result, format: .table).hasPrefix(header))
        let tooLarge = IPCDwindleTreeQueryResult(workspace: nil, tree: nil, tooLarge: true)
        XCTAssertEqual(try rendered(tooLarge, format: .text), "dwindle tree too large")
        let none = IPCDwindleTreeQueryResult(workspace: nil, tree: nil, tooLarge: false)
        XCTAssertEqual(try rendered(none, format: .text), "no dwindle tree")
    }

    private func rendered(_ result: IPCDwindleTreeQueryResult, format: CLIOutputFormat) throws -> String {
        let response = IPCResponse.success(id: "1", kind: .query, result: IPCResult(dwindleTree: result))
        let output = try CLIRenderer.responseOutput(response, format: format)
        return try XCTUnwrap(String(data: output.data, encoding: .utf8)).trimmingCharacters(in: .newlines)
    }
}
