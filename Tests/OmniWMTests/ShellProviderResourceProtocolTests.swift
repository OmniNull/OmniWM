// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellProviderResourceProtocolTests: XCTestCase {
    func testActionMetadataEscapesPathsRetainsRawArgumentsAndEnforcesCompleteLineLimit() throws {
        let inputs = ShellResourceStore.ActionFiles(
            files: [ShellResourceFile(name: "a\"b.png", url: URL(fileURLWithPath: "/tmp/a\"b.png"))],
            outputDirectory: URL(fileURLWithPath: "/tmp/output")
        )
        let frame = try ShellProviderResourceProtocol.action(
            id: 42,
            name: "convert",
            arguments: Data("{\"n\":1}".utf8),
            files: inputs
        )
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [Any])
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[1] as? String, "r42")
        XCTAssertEqual((values[3] as? [String: Int])?["n"], 1)
        let metadata = try XCTUnwrap(values[4] as? [String: Any])
        XCTAssertEqual(metadata["outputDirectory"] as? String, "/tmp/output")
        XCTAssertEqual((metadata["files"] as? [[String: String]])?.first?["name"], "a\"b.png")
        XCTAssertEqual(frame.last, 10)
        XCTAssertThrowsError(try ShellProviderResourceProtocol.action(
            id: 42,
            name: "convert",
            arguments: Data(repeating: 32, count: 65_500),
            files: inputs
        )) { error in
            XCTAssertEqual(error as? ShellResourceFailure, ShellResourceFailure("provider_action_too_large"))
        }
    }

    func testMetadataRequiresWholeStrictBoundedListBeforeAnyImport() throws {
        let empty = try ShellProviderResourceProtocol.outputs(Data("{\"files\":[]}".utf8))
        XCTAssertTrue(empty.files.isEmpty)
        let valid = try ShellProviderResourceProtocol
            .outputs(Data("{\"files\":[{\"name\":\"image.png\",\"path\":\"nested/image.png\"}]}".utf8))
        XCTAssertEqual(valid.files, [ShellResourceOutput(name: "image.png", path: "nested/image.png")])
        XCTAssertEqual(valid.descriptors.first?.kind, "file")
        XCTAssertEqual(valid.descriptors.first?.uti, "public.png")
        for invalid in [
            "{}",
            "{\"files\":{}}",
            "{\"files\":[],\"extra\":1}",
            "{\"files\":[null]}",
            "{\"files\":[{\"name\":\"a\",\"path\":\"a\",\"extra\":1}]}"
        ] {
            XCTAssertThrowsError(try ShellProviderResourceProtocol.outputs(Data(invalid.utf8)))
        }
        for path in ["/tmp/a", "../a", "a/../b", "a//b", "a/./b", "", "a\0b", String(repeating: "x", count: 4097)] {
            let bytes = try JSONSerialization.data(withJSONObject: ["files": [["name": "a", "path": path]]])
            XCTAssertThrowsError(try ShellProviderResourceProtocol.outputs(bytes))
        }
        let oversized = try JSONSerialization.data(withJSONObject: ["files": Array(
            repeating: ["name": "a", "path": "a"],
            count: 33
        )])
        XCTAssertThrowsError(try ShellProviderResourceProtocol.outputs(oversized))
    }

    func testPendingInputPreparationCompletesOnlyAfterActualMaterializationAndCancelStopsPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        let owner = ShellServiceOwner(generation: 1, owner: 1, epoch: 1)
        try await store.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "lake", package: "root", instance: "child")
        )
        let ids = [ShellResourceID(), ShellResourceID()]
        try store.catalog.admit(
            ids.map { ShellResourceDescriptor(id: $0, name: "input.bin", kind: "file", uti: "public.data") },
            owner: owner
        )
        let first = ShellResourceLeaseKey(id: ShellServiceID(owner: owner, request: 1), incarnation: 1)
        let second = ShellResourceLeaseKey(id: ShellServiceID(owner: owner, request: 2), incarnation: 1)
        let received = Mutex<[UInt64: Data]>([:])
        let operation = ShellResourceOperation()
        await store.prepareProviderAction(
            first,
            action: .init(name: "convert", arguments: Data("null".utf8), inputs: [ids[0]]),
            operation: ShellResourceOperation()
        ) { result in
            if case let .success(frame) = result { received.withLock { $0[1] = frame } }
        }
        await store.prepareProviderAction(
            second,
            action: .init(name: "convert", arguments: Data("null".utf8), inputs: [ids[1]]),
            operation: operation
        ) { result in
            if case let .success(frame) = result { received.withLock { $0[2] = frame } }
        }
        XCTAssertTrue(received.withLock { $0.isEmpty })
        operation.cancel()
        try await store.materialize([.bytes(Data([1, 2, 3])), .bytes(Data([4]))], ids: ids, owner: owner)
        XCTAssertEqual(received.withLock { Set($0.keys) }, [1])
        await store.finishAction(first)
        await store.finishAction(second)
        await store.release(ids, owner: owner)
    }
}
