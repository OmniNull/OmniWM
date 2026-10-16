// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellProviderActionsTests: XCTestCase {
    func testFIFOAndOneCombinedBacklogBoundAcrossUtilityHandoff() {
        let actions = ShellProviderActions()
        actions.activate(identity)
        let frame = fullFrame()
        for request in 1 ... 16 {
            XCTAssertNil(actions.append(frame, id: id(request), identity: identity))
        }
        XCTAssertEqual(actions.pendingBytes, ShellProviderWriteQueue.byteLimit)
        XCTAssertNotNil(actions.append(frame, id: id(17), identity: identity))
        let batch = actions.takeBatch()
        XCTAssertEqual(batch.map(\.id), (1 ... 16).map(id))
        XCTAssertFalse(actions.hasPending)
        XCTAssertEqual(actions.pendingBytes, ShellProviderWriteQueue.byteLimit)
        XCTAssertNotNil(actions.append(frame, id: id(17), identity: identity))
        actions.consumed(frame.count, identity: identity)
        XCTAssertNil(actions.append(frame, id: id(17), identity: identity))
        XCTAssertEqual(actions.takeBatch().map(\.id), [id(17)])
        XCTAssertEqual(actions.pendingBytes, ShellProviderWriteQueue.byteLimit)
    }

    func testCancellationCompactsPendingFramesWithoutTombstones() {
        let actions = ShellProviderActions()
        actions.activate(identity)
        let frame = Data("action\n".utf8)
        for request in 1 ... 10_000 {
            XCTAssertNil(actions.append(frame, id: id(request), identity: identity))
            actions.cancel(id(request), identity: identity)
        }
        XCTAssertEqual(actions.pendingBytes, 0)
        XCTAssertFalse(actions.hasPending)
        XCTAssertTrue(actions.takeBatch().isEmpty)
    }

    func testCancelledUnsentWriterFramesArePrunedWhilePartialFrameFinishes() throws {
        let actions = ShellProviderActions()
        actions.activate(identity)
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        XCTAssertNil(actions.append(first, id: id(1), identity: identity))
        XCTAssertNil(actions.append(second, id: id(2), identity: identity))
        var writer = ShellProviderWriteQueue()
        for action in actions.takeBatch() { try writer.append(action.frame, id: action.id) }
        var calls = 0
        XCTAssertEqual(writer.drain { _ in
            calls += 1
            return calls == 1 ? .written(2) : .wouldBlock
        }, .blocked)
        actions.consumed(2, identity: identity)
        let discarded = writer.discardUnsent { _ in true }
        XCTAssertEqual(discarded, second.count)
        actions.consumed(discarded, identity: identity)
        XCTAssertEqual(actions.pendingBytes, first.count - 2)
        var output = Data()
        let before = writer.pendingBytes
        XCTAssertEqual(writer.drain { bytes in
            output.append(contentsOf: bytes)
            return .written(bytes.count)
        }, .empty)
        actions.consumed(before - writer.pendingBytes, identity: identity)
        XCTAssertEqual(output, Data(first.dropFirst(2)))
        XCTAssertEqual(actions.pendingBytes, 0)
    }

    func testTerminalAndOldIncarnationProgressCannotAffectReplacement() {
        let actions = ShellProviderActions()
        let frame = Data("action\n".utf8)
        actions.activate(identity)
        XCTAssertNil(actions.append(frame, id: id(1), identity: identity))
        _ = actions.takeBatch()
        actions.stop(identity)
        XCTAssertEqual(actions.pendingBytes, 0)
        XCTAssertNotNil(actions.append(frame, id: id(2), identity: identity))
        let next = ShellProviderIdentity(owner: owner, incarnation: 2)
        actions.activate(next)
        XCTAssertNil(actions.append(frame, id: id(3), identity: next))
        actions.consumed(frame.count, identity: identity)
        actions.cancel(id(3), identity: identity)
        actions.stop(identity)
        XCTAssertEqual(actions.pendingBytes, frame.count)
        XCTAssertEqual(actions.takeBatch().map(\.id), [id(3)])
    }

    private var owner: ShellServiceOwner {
        .init(generation: 1, owner: 2, epoch: 3)
    }

    private var identity: ShellProviderIdentity {
        .init(owner: owner, incarnation: 1)
    }

    private func id(_ number: Int) -> ShellServiceID {
        .init(owner: owner, request: UInt64(number))
    }

    private func fullFrame() -> Data {
        var bytes = Data(repeating: 97, count: ShellProviderProtocol.lineLimit - 1)
        bytes.append(10)
        return bytes
    }
}
