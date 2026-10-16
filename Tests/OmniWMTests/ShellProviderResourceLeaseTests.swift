// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellProviderResourceLeaseTests: XCTestCase {
    func testPhysicalLimitRetainsCancelledActionsUntilActualFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShellResourceStore(directory: directory)
        var keys: [ShellResourceLeaseKey] = []
        for slot in 1 ... 8 {
            let owner = ShellServiceOwner(generation: 1, owner: UInt32(slot), epoch: 1)
            try await store.activate(
                owner,
                namespace: ShellStoreNamespace(profile: "lake", package: "root", instance: "i\(slot)")
            )
            for request in 1 ... 32 {
                let key = ShellResourceLeaseKey(
                    id: ShellServiceID(owner: owner, request: UInt64(request)),
                    incarnation: 1
                )
                let operation = ShellResourceOperation()
                let result = Mutex<Result<ShellResourceStore.ActionFiles, ShellResourceFailure>?>(nil)
                await store
                    .beginAction(key, inputs: [], operation: operation) { value in result.withLock { $0 = value } }
                let files = try XCTUnwrap(result.withLock { $0 }).get()
                XCTAssertTrue(FileManager.default.fileExists(atPath: files.outputDirectory.path))
                operation.cancel()
                XCTAssertTrue(FileManager.default.fileExists(atPath: files.outputDirectory.path))
                keys.append(key)
            }
            let overflow = ShellResourceLeaseKey(id: ShellServiceID(owner: owner, request: 33), incarnation: 1)
            let denied = Mutex<ShellResourceFailure?>(nil)
            await store.beginAction(overflow, inputs: [], operation: ShellResourceOperation()) { result in
                if case let .failure(error) = result { denied.withLock { $0 = error } }
            }
            XCTAssertEqual(denied.withLock { $0?.description }, "resource_actions_busy")
        }
        let ninth = ShellServiceOwner(generation: 1, owner: 9, epoch: 1)
        try await store.activate(
            ninth,
            namespace: ShellStoreNamespace(profile: "lake", package: "root", instance: "i9")
        )
        let blocked = ShellResourceLeaseKey(id: ShellServiceID(owner: ninth, request: 1), incarnation: 1)
        let failure = Mutex<ShellResourceFailure?>(nil)
        await store.beginAction(blocked, inputs: [], operation: ShellResourceOperation()) { result in
            if case let .failure(error) = result { failure.withLock { $0 = error } }
        }
        XCTAssertEqual(failure.withLock { $0?.description }, "resource_actions_busy")
        let count = await store.providerResourceActionCount()
        XCTAssertEqual(count, 256)
        await store.finishAction(keys.removeLast())
        let recovered = Mutex(false)
        await store.beginAction(blocked, inputs: [], operation: ShellResourceOperation()) { result in
            if case .success = result { recovered.withLock { $0 = true } }
        }
        XCTAssertTrue(recovered.withLock { $0 })
        let other = ShellServiceOwner(generation: 2, owner: 1, epoch: 1)
        try await store.activate(
            other,
            namespace: ShellStoreNamespace(profile: "other", package: "root", instance: "i1")
        )
        let independent = ShellResourceLeaseKey(id: ShellServiceID(owner: other, request: 1), incarnation: 1)
        let accepted = Mutex(false)
        await store.beginAction(independent, inputs: [], operation: ShellResourceOperation()) { result in
            if case .success = result { accepted.withLock { $0 = true } }
        }
        XCTAssertTrue(accepted.withLock { $0 })
        for key in keys + [blocked, independent] { await store.finishAction(key) }
        let final = await store.providerResourceActionCount()
        XCTAssertEqual(final, 0)
    }
}

private extension ShellResourceStore {
    func providerResourceActionCount() -> Int {
        actions.count
    }
}
