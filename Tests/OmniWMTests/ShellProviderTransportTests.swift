// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellProviderTransportTests: XCTestCase {
    func testFramerPreservesSplitUTF8AndOnlyClassifiesPayload() throws {
        var framer = ShellProviderLineFramer()
        var messages: [ShellProviderProtocol.Message] = []
        let input = Data("[\"state\",\"title\",\"🎵 café\"]\n[\"event\",\"ready\"]\n[\"state\",\"broken\",{bad}]\n".utf8)
        for byte in input {
            try [byte].withUnsafeBytes { try framer.consume($0) { messages.append($0) } }
        }
        try framer.finish()
        XCTAssertEqual(messages, [
            .state(topic: "title", value: Data("\"🎵 café\"".utf8)),
            .event(name: "ready", value: Data("null".utf8)),
            .state(topic: "broken", value: Data("{bad}".utf8))
        ])
        XCTAssertEqual(framer.bufferedBytes, 0)
    }

    func testFramerExactLimitCountsNewlineAndRejectsOversizeOrIncompleteInput() throws {
        let prefix = Data("[\"state\",\"x\",\"".utf8)
        let suffix = Data("\"]\n".utf8)
        var exact = prefix
        exact.append(Data(repeating: 97, count: ShellProviderProtocol.lineLimit - prefix.count - suffix.count))
        exact.append(suffix)
        var framer = ShellProviderLineFramer()
        var count = 0
        try exact.withUnsafeBytes { try framer.consume($0) { _ in count += 1 } }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(exact.count, 65_536)

        var oversized = prefix
        oversized.append(Data(repeating: 97, count: 65_536))
        var large = ShellProviderLineFramer()
        XCTAssertThrowsError(try oversized.withUnsafeBytes { try large.consume($0) { _ in XCTFail() } })
        XCTAssertEqual(large.bufferedBytes, 0)
        XCTAssertNotNil(large.failure)

        var incomplete = ShellProviderLineFramer()
        try Data("[\"event\",\"ready\"]".utf8).withUnsafeBytes { try incomplete.consume($0) { _ in XCTFail() } }
        XCTAssertThrowsError(try incomplete.finish())
    }

    func testHeaderGrammarAndMaximumUInt64Correlation() throws {
        for line in [
            "[\"unknown\",\"x\",0]", "[\"state\",\"bad name\",0]", "[\"state\",\"a\\u0062\",0]",
            "[\"state\",\"1name\",0]", "[\"event\",\"x\",0,1]", "[\"result\",\"r1\",1]",
            "[\"result\",\"r1\",false]", "[\"state\",\"x\",]"
        ] {
            XCTAssertThrowsError(try ShellProviderProtocol.classify(Array(line.utf8)), line)
        }
        XCTAssertEqual(ShellProviderProtocol.request("r18446744073709551615"), UInt64.max)
        XCTAssertNil(ShellProviderProtocol.request("r18446744073709551616"))
        XCTAssertNil(ShellProviderProtocol.request("r01"))
        let action = try ShellProviderProtocol.action(id: .max, name: "convert.file", arguments: Data("{\"n\":1}".utf8))
        XCTAssertEqual(
            String(decoding: action, as: UTF8.self),
            "[\"action\",\"r18446744073709551615\",\"convert.file\",{\"n\":1}]\n"
        )
        XCTAssertThrowsError(try ShellProviderProtocol.action(
            id: 1,
            name: "x",
            arguments: Data(repeating: 32, count: 65_536)
        ))
    }

    func testInboxKeepsLatestRawStateBeforeOrderedEventsAndResults() {
        let (inbox, identity) = makeInbox()
        let id = request(identity, 1)
        XCTAssertTrue(inbox.register(id, identity: identity))
        XCTAssertEqual(inbox.post(.state(topic: "count", value: Data("1".utf8)), from: identity), .accepted)
        XCTAssertEqual(inbox.post(.event(name: "one", value: Data("1".utf8)), from: identity), .accepted)
        inbox.post(.state(topic: "count", value: Data("2".utf8)), from: identity)
        inbox.post(.result(id: "r1", ok: true, value: Data("3".utf8), attachments: nil), from: identity)
        inbox.post(.event(name: "two", value: Data("2".utf8)), from: identity)
        let batch = inbox.takeBatch(now: 0)
        XCTAssertEqual(batch.map(\.control), [
            .event(name: "one", value: Data("1".utf8)),
            .result(id: id, outcome: .provider(ok: true, value: Data("3".utf8), attachments: nil)),
            .event(name: "two", value: Data("2".utf8))
        ])
        XCTAssertEqual(batch[0].snapshot?.topics, [.init(name: "count", value: Data("2".utf8))])
        XCTAssertNil(batch[1].snapshot)
        XCTAssertNil(batch[2].snapshot)
        XCTAssertEqual(inbox.pendingActions, 0)
        XCTAssertEqual(inbox.counters.coalescedStates, 1)
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
    }

    func testStatePacingIsBeforeConsumptionAndControlInvalidatesDeadline() {
        let (inbox, identity) = makeInbox()
        let wakes = Mutex(0)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        inbox.post(.state(topic: "value", value: Data("1".utf8)), from: identity)
        XCTAssertEqual(inbox.takeBatch(now: 0).first?.snapshot?.topics.count, 1)
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
        inbox.post(.state(topic: "value", value: Data("2".utf8)), from: identity)
        XCTAssertTrue(inbox.takeBatch(now: 1).isEmpty)
        let deadline = ShellProviderInbox.stateInterval
        XCTAssertEqual(inbox.finishBatch(now: 1), .deadline(deadline))
        let before = wakes.withLock { $0 }
        inbox.post(.state(topic: "value", value: Data("3".utf8)), from: identity)
        XCTAssertEqual(wakes.withLock { $0 }, before)
        inbox.post(.event(name: "read", value: Data("null".utf8)), from: identity)
        XCTAssertEqual(wakes.withLock { $0 }, before + 1)
        let batch = inbox.takeBatch(now: 2)
        XCTAssertEqual(batch.first?.snapshot?.topics, [.init(name: "value", value: Data("3".utf8))])
        XCTAssertEqual(inbox.finishBatch(now: 2), .idle)
        inbox.deadlineFired(deadline, now: deadline)
        XCTAssertEqual(wakes.withLock { $0 }, before + 1)
    }

    func testOneWakePerBoundedBatchAndOneDueStateWake() {
        let (inbox, identity) = makeInbox()
        let wakes = Mutex(0)
        inbox.attachWake { wakes.withLock { $0 += 1 } }
        for _ in 0 ..< 20 { inbox.post(.event(name: "tick", value: Data("0".utf8)), from: identity) }
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(inbox.takeBatch(now: 0).count, 16)
        XCTAssertEqual(inbox.finishBatch(now: 0), .waking)
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        XCTAssertEqual(inbox.takeBatch(now: 0).count, 4)
        XCTAssertEqual(inbox.finishBatch(now: 0), .idle)
        inbox.post(.state(topic: "x", value: Data("1".utf8)), from: identity)
        _ = inbox.takeBatch(now: 10)
        _ = inbox.finishBatch(now: 10)
        inbox.post(.state(topic: "x", value: Data("2".utf8)), from: identity)
        XCTAssertTrue(inbox.takeBatch(now: 11).isEmpty)
        let due = 10 + ShellProviderInbox.stateInterval
        XCTAssertEqual(inbox.finishBatch(now: 11), .deadline(due))
        let before = wakes.withLock { $0 }
        inbox.deadlineFired(due, now: due - 1)
        XCTAssertEqual(wakes.withLock { $0 }, before)
        inbox.deadlineFired(due, now: due)
        inbox.deadlineFired(due, now: due)
        XCTAssertEqual(wakes.withLock { $0 }, before + 1)
        XCTAssertEqual(inbox.takeBatch(now: due).first?.snapshot?.topics, [.init(name: "x", value: Data("2".utf8))])
        XCTAssertEqual(inbox.finishBatch(now: due), .idle)
    }

    func testDeletionDoesNotAccumulateTombstonesAndIdenticalStateDoesNotWake() {
        let (inbox, identity) = makeInbox()
        _ = inbox.takeBatch(now: 0)
        _ = inbox.finishBatch(now: 0)
        for index in 0 ..< 1000 {
            inbox.post(.state(topic: "t\(index)", value: Data("1".utf8)), from: identity)
            inbox.post(.state(topic: "t\(index)", value: Data("null".utf8)), from: identity)
        }
        XCTAssertNil(inbox.takeState(identity, now: 0))
        for index in 0 ..< 64 {
            XCTAssertEqual(inbox.post(.state(topic: "t\(index)", value: Data("1".utf8)), from: identity), .accepted)
        }
        XCTAssertEqual(inbox.takeState(identity, now: 1)?.topics.count, 64)
        XCTAssertEqual(inbox.post(.state(topic: "t0", value: Data("1".utf8)), from: identity), .unchanged)
        inbox.post(.state(topic: "t0", value: Data("null".utf8)), from: identity)
        XCTAssertEqual(inbox.takeState(identity, now: 2)?.topics, [.init(name: "t0", value: nil)])
        XCTAssertEqual(inbox.post(.state(topic: "replacement", value: Data("1".utf8)), from: identity), .accepted)
        XCTAssertEqual(
            inbox.post(.state(topic: "overflow", value: Data("1".utf8)), from: identity),
            .failed("Provider state limit exceeded")
        )
    }

    func testLiveStateByteAccountingDropsDeletedValues() {
        let (inbox, identity) = makeInbox()
        let value = Data(repeating: 97, count: 65_500)
        for index in 0 ..< 16 {
            XCTAssertEqual(inbox.post(.state(topic: "t\(index)", value: value), from: identity), .accepted)
        }
        inbox.post(.state(topic: "t0", value: Data("null".utf8)), from: identity)
        XCTAssertEqual(inbox.post(.state(topic: "t16", value: value), from: identity), .accepted)
        XCTAssertEqual(
            inbox.post(.state(topic: "t17", value: value), from: identity),
            .failed("Provider state limit exceeded")
        )
        XCTAssertEqual(inbox.post(.event(name: "late", value: Data()), from: identity), .ignored)
    }

    func testEventOverflowSettlesActionsWithoutDroppingReservedReplies() {
        let (inbox, identity) = makeInbox()
        let first = request(identity, 1)
        let second = request(identity, 2)
        XCTAssertTrue(inbox.register(first, identity: identity))
        XCTAssertTrue(inbox.register(second, identity: identity))
        for _ in 0 ..< 256 { inbox.post(.event(name: "tick", value: Data("0".utf8)), from: identity) }
        XCTAssertEqual(
            inbox.post(.result(id: "r1", ok: true, value: Data("1".utf8), attachments: nil), from: identity),
            .accepted
        )
        XCTAssertEqual(
            inbox.post(.event(name: "overflow", value: Data("0".utf8)), from: identity),
            .failed("Provider event queue exceeded 256 entries")
        )
        XCTAssertEqual(inbox.pendingEvents, 0)
        XCTAssertEqual(inbox.takeBatch(now: 0).compactMap(\.control), [
            .result(id: first, outcome: .provider(ok: true, value: Data("1".utf8), attachments: nil)),
            .result(id: second, outcome: .failure("Provider disconnected"))
        ])
        XCTAssertEqual(inbox.pendingActions, 0)
    }

    func testOptionsRestartRetainsQueuedResultsSettlesOthersAndRejectsOldState() {
        let (inbox, old) = makeInbox()
        let one = request(old, 1)
        let two = request(old, 2)
        let three = request(old, 3)
        for id in [one, two, three] { XCTAssertTrue(inbox.register(id, identity: old)) }
        inbox.post(.state(topic: "version", value: Data("1".utf8)), from: old)
        inbox.post(.event(name: "discard", value: Data("0".utf8)), from: old)
        inbox.post(.result(id: "r2", ok: true, value: Data("2".utf8), attachments: nil), from: old)
        inbox.end(old, status: .exited(0))
        let current = ShellProviderIdentity(owner: old.owner, incarnation: old.incarnation + 1)
        XCTAssertTrue(inbox.activate(current))
        inbox.post(.state(topic: "version", value: Data("2".utf8)), from: current)
        XCTAssertEqual(inbox.post(.state(topic: "version", value: Data("3".utf8)), from: old), .ignored)
        XCTAssertEqual(
            inbox.post(.result(id: "r1", ok: true, value: Data("3".utf8), attachments: nil), from: old),
            .ignored
        )
        let batch = inbox.takeBatch(now: 0)
        XCTAssertEqual(batch.prefix(3).map(\.control), [
            .result(id: two, outcome: .provider(ok: true, value: Data("2".utf8), attachments: nil)),
            .result(id: one, outcome: .failure("Provider disconnected")),
            .result(id: three, outcome: .failure("Provider disconnected"))
        ])
        XCTAssertTrue(batch.prefix(3).allSatisfy { $0.identity == old && $0.snapshot == nil })
        XCTAssertEqual(batch.last?.identity, current)
        XCTAssertEqual(batch.last?.snapshot?.topics, [.init(name: "version", value: Data("2".utf8))])
        XCTAssertEqual(inbox.pendingActions, 0)
        inbox.end(old, status: .failed("late"))
        XCTAssertTrue(inbox.takeBatch(now: 1).isEmpty)
    }

    func testUnknownDuplicateCancelledAndUnsupportedAttachmentResultsAreBounded() {
        let (inbox, identity) = makeInbox()
        let first = request(identity, 1)
        let second = request(identity, 2)
        XCTAssertTrue(inbox.register(first, identity: identity))
        XCTAssertTrue(inbox.register(second, identity: identity))
        let result = ShellProviderProtocol.Message.result(id: "r1", ok: true, value: Data("0".utf8), attachments: nil)
        XCTAssertEqual(inbox.post(result, from: identity), .accepted)
        XCTAssertEqual(inbox.post(result, from: identity), .ignored)
        XCTAssertEqual(
            inbox.post(.result(id: "r999", ok: true, value: Data(), attachments: nil), from: identity),
            .ignored
        )
        inbox.cancel(first)
        XCTAssertEqual(inbox.post(result, from: identity), .ignored)
        inbox.post(.result(id: "r2", ok: true, value: Data("0".utf8), attachments: Data("{}".utf8)), from: identity)
        XCTAssertEqual(inbox.takeBatch(now: 0).compactMap(\.control), [
            .result(id: second, outcome: .failure("unexpected_provider_files"))
        ])
        XCTAssertEqual(inbox.counters.ignoredResults, 3)
        XCTAssertEqual(inbox.pendingActions, 0)
    }

    func testPartialWritesRetryInterruptionsAndWaitForReadinessWithoutLosingOffsets() throws {
        let (_, identity) = makeInbox()
        var queue = ShellProviderWriteQueue()
        try queue.append(Data("first\n".utf8), id: request(identity, 1))
        try queue.append(Data("second\n".utf8), id: request(identity, 2))
        var calls = 0
        var output: [UInt8] = []
        let blocked = queue.drain { bytes in
            calls += 1
            if calls == 1 { return .interrupted }
            if calls == 3 { return .wouldBlock }
            output.append(contentsOf: bytes.prefix(2))
            return .written(2)
        }
        XCTAssertEqual(blocked, .blocked)
        XCTAssertEqual(queue.pendingBytes, 11)
        XCTAssertFalse(queue.cancel(request(identity, 1)))
        XCTAssertEqual(queue.drain { bytes in output.append(contentsOf: bytes)
            return .written(bytes.count)
        }, .empty)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "first\nsecond\n")
        XCTAssertEqual(queue.pendingBytes, 0)
    }

    func testWriteBacklogAdmissionIsAtomicAndWorkIsBounded() throws {
        let (_, identity) = makeInbox()
        var queue = ShellProviderWriteQueue()
        var frame = Data(repeating: 97, count: 65_535)
        frame.append(10)
        for id in 1 ... 16 { try queue.append(frame, id: request(identity, UInt64(id))) }
        XCTAssertThrowsError(try queue.append(Data("x\n".utf8), id: request(identity, 17)))
        XCTAssertEqual(queue.pendingBytes, 1_048_576)
        XCTAssertEqual(queue.count, 16)
        var calls = 0
        XCTAssertEqual(queue.drain { _ in calls += 1
            return .interrupted
        }, .yielded)
        XCTAssertEqual(calls, 32)
        var written = 0
        XCTAssertEqual(queue.drain { bytes in written += bytes.count
            return .written(bytes.count)
        }, .yielded)
        XCTAssertEqual(written, 65_536)
        XCTAssertTrue(queue.cancel(request(identity, 2)))
        XCTAssertEqual(queue.pendingBytes, 14 * 65_536)
        XCTAssertEqual(queue.drain { _ in .written(0) }, .failed("Invalid provider write progress"))
        queue.removeAll()
        XCTAssertEqual(queue.pendingBytes, 0)
        XCTAssertEqual(queue.count, 0)
    }

    func testStderrTruncationAndRateLimitStillConsumeEveryByte() {
        var diagnostics = ShellProviderDiagnostics()
        var lines: [ShellProviderDiagnostics.Line] = []
        var first = Data(repeating: 120, count: 100_000)
        first.append(10)
        first.withUnsafeBytes { diagnostics.consume($0, now: 0) { lines.append($0) } }
        for _ in 0 ..< 29 {
            Data("line\n".utf8).withUnsafeBytes { diagnostics.consume($0, now: 0) { lines.append($0) } }
        }
        XCTAssertEqual(lines.count, 20)
        XCTAssertEqual(lines[0].text.utf8.count, 1024)
        XCTAssertTrue(lines[0].truncated)
        XCTAssertEqual(diagnostics.suppressed, 10)
        XCTAssertEqual(diagnostics.truncatedLines, 1)
        XCTAssertEqual(diagnostics.bufferedBytes, 0)
        Data("next\n".utf8)
            .withUnsafeBytes { diagnostics.consume($0, now: ShellProviderDiagnostics.interval) { lines.append($0) } }
        XCTAssertEqual(lines.last, .init(text: "next", truncated: false, suppressed: 10))
        XCTAssertEqual(diagnostics.suppressed, 0)
    }

    private func makeInbox() -> (ShellProviderInbox, ShellProviderIdentity) {
        let inbox = ShellProviderInbox()
        let identity = ShellProviderIdentity(owner: .init(generation: 1, owner: 1, epoch: 1), incarnation: 1)
        XCTAssertTrue(inbox.activate(identity))
        return (inbox, identity)
    }

    private func request(_ identity: ShellProviderIdentity, _ number: UInt64) -> ShellServiceID {
        ShellServiceID(owner: identity.owner, request: number)
    }
}
