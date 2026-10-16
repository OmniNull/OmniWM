// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

final class ShellResourceIngressTests: XCTestCase {
    private func fixture(receivers: Int = 1) throws -> (ShellFilePromiseBatch, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("promise", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            try ShellFilePromiseBatch(
                receiverCount: receivers,
                directory: directory,
                temporaryRoot: root,
                operation: ShellResourceOperation()
            ),
            root
        )
    }

    private func file(_ batch: ShellFilePromiseBatch, _ name: String, value: String = "data") throws -> URL {
        let url = batch.directory.appendingPathComponent(name)
        try Data(value.utf8).write(to: url)
        return url
    }

    func testEarlyCallbacksWaitForAtomicDeclarationAndAdmission() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let wakes = Mutex(0)
        batch.attachWake { wakes.withLock { $0 += 1 } }
        batch.receive(receiver: 0, url: try file(batch, "b"), error: nil)
        batch.receive(receiver: 0, url: try file(batch, "a"), error: nil)
        XCTAssertEqual(wakes.withLock { $0 }, 0)
        XCTAssertTrue(batch.takeBatch().deliveries.isEmpty)
        let items = try batch.configure(names: [["a", "b"]], types: [["public.data"]])
        XCTAssertEqual(items.map(\.name), ["a", "b"])
        XCTAssertEqual(wakes.withLock { $0 }, 0)
        batch.activate()
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        let result = batch.takeBatch()
        XCTAssertEqual(result.deliveries.map(\.index), [1, 0])
        XCTAssertTrue(result.finished)
        XCTAssertNil(result.error)
        batch.finishBatch()
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertFalse(batch.takeBatch().finished)
    }

    func testUnknownFailureWaitsUntilSuccessfulNamesClaimTheirOwnSlots() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let wakes = Mutex(0)
        batch.attachWake { wakes.withLock { $0 += 1 } }
        _ = try batch.configure(names: [["a", "b"]], types: [[]])
        batch.activate()
        batch.receive(receiver: 0, url: batch.directory.appendingPathComponent("a"), error: "b failed")
        XCTAssertEqual(wakes.withLock { $0 }, 0)
        XCTAssertTrue(batch.takeBatch().deliveries.isEmpty)
        batch.finishBatch()
        XCTAssertEqual(wakes.withLock { $0 }, 0)
        batch.receive(receiver: 0, url: try file(batch, "a", value: "actual a"), error: nil)
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        let result = batch.takeBatch()
        XCTAssertEqual(result.deliveries.map(\.index), [0, 1])
        guard case let .success(copy) = result.deliveries[0].result else { return XCTFail("a was not imported") }
        XCTAssertEqual(try Data(contentsOf: copy.file), Data("actual a".utf8))
        guard case let .failure(error) = result.deliveries[1].result
        else { return XCTFail("b did not retain its failure") }
        XCTAssertEqual(error.description, "b failed")
        XCTAssertTrue(result.finished)
        batch.finishBatch()
        XCTAssertEqual(wakes.withLock { $0 }, 1)
    }

    func testTerminalFailuresWaitBehindSuccessfulNamesAcrossBoundedDrains() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = (0 ..< 18).map { "file-\($0)" }
        _ = try batch.configure(names: [names], types: [[]])
        batch.receive(receiver: 0, url: batch.directory.appendingPathComponent(names[0]), error: "unknown failure")
        for name in names.prefix(17).reversed() {
            batch.receive(receiver: 0, url: try file(batch, name), error: nil)
        }
        batch.activate()
        let first = batch.takeBatch()
        XCTAssertEqual(first.deliveries.map(\.index), Array((1 ..< 17).reversed()).map(Optional.some))
        XCTAssertFalse(first.finished)
        batch.finishBatch()
        let final = batch.takeBatch()
        XCTAssertEqual(final.deliveries.map(\.index), [0, 17])
        guard case .success = final.deliveries[0].result else { return XCTFail("named a was stolen by failure") }
        guard case .failure = final.deliveries[1].result else { return XCTFail("remaining slot did not fail") }
        XCTAssertTrue(final.finished)
    }

    func testSharedDestinationSurvivesUntilEveryReceiverReturns() throws {
        let (batch, root) = try fixture(receivers: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try batch.configure(names: [["a"], ["b"]], types: [["public.data"], ["public.data"]])
        batch.activate()
        batch.receive(receiver: 0, url: try file(batch, "a"), error: nil)
        let first = batch.takeBatch()
        XCTAssertFalse(first.finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.directory.path))
        batch.finishBatch()
        batch.receive(receiver: 1, url: try file(batch, "b"), error: nil)
        let second = batch.takeBatch()
        XCTAssertTrue(second.finished)
        XCTAssertEqual(second.deliveries.map(\.index), [1])
    }

    func testExcessNamesRejectBeforeActivationAndLateFailuresStillFinish() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try batch.configure(names: [(0 ..< 33).map { "\($0)" }], types: [[]]))
        XCTAssertFalse(batch.operation.isActive)
        for _ in 0 ..< 32 { batch.receive(receiver: 0, url: URL(fileURLWithPath: "/ignored"), error: "failed") }
        XCTAssertFalse(batch.takeBatch().finished)
        batch.finishBatch()
        batch.receive(receiver: 0, url: URL(fileURLWithPath: "/ignored"), error: "failed")
        let final = batch.takeBatch()
        XCTAssertTrue(final.finished)
        XCTAssertNotNil(final.error)
        XCTAssertTrue(final.deliveries.isEmpty)
    }

    func testCancellationRetainsOwnedCopiesOnlyForCleanupAndIgnoresErrorURL() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try batch.configure(names: [["a", "b"]], types: [[]])
        batch.receive(receiver: 0, url: try file(batch, "a"), error: nil)
        batch.cancel()
        batch.receive(receiver: 0, url: URL(fileURLWithPath: "/must-not-read"), error: "cancelled externally")
        let result = batch.takeBatch()
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.error, "cancelled")
        XCTAssertTrue(result.deliveries.allSatisfy { $0.index == nil })
        guard case let .success(copy) = try XCTUnwrap(result.deliveries.first).result
        else { return XCTFail("missing cleanup backing") }
        XCTAssertEqual(try Data(contentsOf: copy.file), Data("data".utf8))
        ShellResourceReceivedFile.remove(copy.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.directory.appendingPathComponent("a").path))
    }

    func testBoundedDrainEmitsOneWakePerRemainingBatch() throws {
        let (batch, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = (0 ..< 32).map { "\($0)" }
        let wakes = Mutex(0)
        batch.attachWake { wakes.withLock { $0 += 1 } }
        _ = try batch.configure(names: [names], types: [[]])
        for name in names { batch.receive(receiver: 0, url: try file(batch, name), error: nil) }
        batch.activate()
        XCTAssertEqual(wakes.withLock { $0 }, 1)
        XCTAssertEqual(batch.takeBatch().deliveries.count, 16)
        batch.finishBatch()
        XCTAssertEqual(wakes.withLock { $0 }, 2)
        let final = batch.takeBatch()
        XCTAssertEqual(final.deliveries.count, 16)
        XCTAssertTrue(final.finished)
        batch.finishBatch()
        XCTAssertEqual(wakes.withLock { $0 }, 2)
    }

    func testScopeBeginsOnceAndEndsAtLastRetainedReference() {
        let calls = Mutex<[String]>([])
        let url = URL(fileURLWithPath: "/unused")
        var access = ShellResourceSecurityScope.begin(url, start: { _ in calls.withLock { $0.append("start") }
            return true
        }, stop: { _ in calls.withLock { $0.append("stop") } })
        var retained = access
        access = nil
        XCTAssertEqual(calls.withLock { $0 }, ["start"])
        XCTAssertNotNil(retained)
        retained = nil
        XCTAssertEqual(calls.withLock { $0 }, ["start", "stop"])
        let unavailable = ShellResourceSecurityScope.begin(
            url,
            start: { _ in false },
            stop: { _ in XCTFail("unbalanced stop") }
        )
        XCTAssertNil(unavailable)
    }

    @MainActor
    func testPasteboardCapturesSupportedRepresentationsWithoutFileReads() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = NSPasteboardItem()
        file.setString("file:///missing/image.png", forType: .fileURL)
        file.setString("duplicate text", forType: .string)
        let text = NSPasteboardItem()
        text.setString("hello", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([file, text]))
        let snapshot = try ShellDropSnapshot.capture(pasteboard, accepts: .all)
        XCTAssertEqual(snapshot.items.map(\.kind), ["file", "text"])
        XCTAssertEqual(snapshot.items.map(\.name), ["image.png", "Text"])
        XCTAssertTrue(snapshot.promises.isEmpty)
        XCTAssertTrue(ShellDropSnapshot.types(pasteboard).contains(.image))
        let imagesOnly = try ShellDropSnapshot.capture(pasteboard, accepts: .image)
        XCTAssertEqual(imagesOnly.items.count, 1)
    }

    @MainActor
    func testImageOnlyDropUsesPNGWhenTheSameItemAlsoOffersAURL() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        let bytes = Data([1, 2, 3, 4])
        item.setString("https://example.invalid/image", forType: .URL)
        item.setData(bytes, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let snapshot = try ShellDropSnapshot.capture(pasteboard, accepts: .image)
        XCTAssertEqual(snapshot.items.map(\.kind), ["image"])
        guard case let .bytes(data) = try XCTUnwrap(snapshot.items.first).source else { return XCTFail("missing PNG") }
        XCTAssertEqual(data, bytes)
    }

    @MainActor
    func testTextOnlyDropUsesTextWhenTheSameItemAlsoOffersAFilePromise() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let delegate = PromiseDelegate()
        let provider = TextPromise(fileType: "public.data", delegate: delegate)
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)?.count, 1)
        let snapshot = try ShellDropSnapshot.capture(pasteboard, accepts: .text)
        XCTAssertTrue(snapshot.promises.isEmpty)
        XCTAssertEqual(snapshot.items.map(\.kind), ["text"])
        guard case let .text(value) = try XCTUnwrap(snapshot.items.first).source else { return XCTFail("missing text") }
        XCTAssertEqual(value, "fallback text")
    }

    private final class TextPromise: NSFilePromiseProvider {
        override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            super.writableTypes(for: pasteboard) + [.string]
        }

        override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            type == .string ? "fallback text" : super.pasteboardPropertyList(forType: type)
        }
    }

    private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        @MainActor
        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            "promised.data"
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            XCTFail("snapshotting must not start promise receipt")
            completionHandler(ShellResourceFailure("unexpected receipt"))
        }
    }
}
