// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    func testSupersededSaveOnlyPersistsReplacement() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        let firstDuration = await requests.next()
        XCTAssertEqual(firstDuration, .milliseconds(250))
        let firstTask = await store.saveTask
        let obsoleteSave = try XCTUnwrap(firstTask)

        _ = await store.handleCapture(capture("second"))
        let secondDuration = await requests.next()
        XCTAssertEqual(secondDuration, .milliseconds(250))
        let secondTask = await store.saveTask
        let replacementSave = try XCTUnwrap(secondTask)

        XCTAssertTrue(obsoleteSave.isCancelled)
        await sleeper.resumeNext(throwing: CancellationError())
        await obsoleteSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(replacementSave.isCancelled)

        await sleeper.resumeNext()
        await replacementSave.value
        XCTAssertEqual(try persistedTitles(at: fileURL), ["second", "first"])
        let pendingSave = await store.saveTask
        XCTAssertNil(pendingSave)
    }

    func testCancelledSuccessfulSleepDoesNotFlushOrCancelReplacement() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        _ = await requests.next()
        let firstTask = await store.saveTask
        let obsoleteSave = try XCTUnwrap(firstTask)

        _ = await store.handleCapture(capture("second"))
        _ = await requests.next()
        let secondTask = await store.saveTask
        let replacementSave = try XCTUnwrap(secondTask)

        XCTAssertTrue(obsoleteSave.isCancelled)
        await sleeper.resumeNext()
        await obsoleteSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(replacementSave.isCancelled)

        await sleeper.resumeNext()
        await replacementSave.value
        XCTAssertEqual(try persistedTitles(at: fileURL), ["second", "first"])
    }

    func testExplicitFlushCancelsPendingSaveWithoutLaterWrite() async throws {
        let sleeper = ClipboardSaveSleeper()
        let (store, fileURL) = try makeStore(sleeper: sleeper)
        var requests = sleeper.requests.makeAsyncIterator()

        _ = await store.handleCapture(capture("first"))
        _ = await requests.next()
        let task = await store.saveTask
        let pendingSave = try XCTUnwrap(task)

        try await store.flush()
        XCTAssertTrue(pendingSave.isCancelled)
        XCTAssertEqual(try persistedTitles(at: fileURL), ["first"])
        try FileManager.default.removeItem(at: fileURL)

        await sleeper.resumeNext()
        await pendingSave.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let remainingSave = await store.saveTask
        XCTAssertNil(remainingSave)
    }

    func testDisabledRestartLoadsExistingHistoryWithoutOverwritingIt() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        _ = await store.handleCapture(capture("saved"))
        try await store.flush()
        let originalData = try Data(contentsOf: fileURL)
        let configuration = ClipboardHistoryConfiguration(
            isEnabled: false,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: fileURL.deletingLastPathComponent()
        )
        let restartedStore = ClipboardHistoryStore(configuration: configuration)

        let snapshots = await restartedStore.updateConfiguration(configuration)

        XCTAssertEqual(snapshots.map(\.title), ["saved"])
        let pendingSave = await restartedStore.saveTask
        XCTAssertNil(pendingSave)
        try await restartedStore.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testCaptureAlreadyInFlightCannotSaveAfterHistoryIsDisabled() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        _ = await store.handleCapture(capture("saved"))
        try await store.flush()
        let disabled = ClipboardHistoryConfiguration(
            isEnabled: false,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: fileURL.deletingLastPathComponent()
        )

        _ = await store.updateConfiguration(disabled)
        let rejected = await store.handleCapture(capture("late"))
        try await store.flush()

        XCTAssertEqual(rejected.map(\.title), ["saved"])
        XCTAssertEqual(try persistedTitles(at: fileURL), ["saved"])
    }

    func testCaptureAlreadyInFlightHonorsCurrentIgnoredTypes() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        let rejectedType = "custom.private"
        let capture = ClipboardPasteboardCapture(
            contents: [
                ClipboardHistoryContent(
                    itemIndex: 0,
                    type: "public.utf8-plain-text",
                    kind: .text,
                    data: Data("private".utf8)
                ),
                ClipboardHistoryContent(
                    itemIndex: 0,
                    type: rejectedType,
                    kind: .other,
                    data: Data("metadata".utf8)
                )
            ],
            sourceBundleIdentifier: nil,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let updated = ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: fileURL.deletingLastPathComponent(),
            ignoredTypes: [rejectedType]
        )

        _ = await store.updateConfiguration(updated)
        let rejected = await store.handleCapture(capture)
        try await store.flush()

        XCTAssertTrue(rejected.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCaptureFenceRejectsDelayedCaptureWithoutChangingSavedHistory() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        _ = await store.handleCapture(capture("saved"), epoch: 1)
        try await store.flush()
        let originalData = try Data(contentsOf: fileURL)
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let lateCapture = capture("late")
        let delayed = Task {
            for await _ in release { break }
            return await store.handleCapture(lateCapture, epoch: 1)
        }

        await store.fenceCaptures(epoch: 2)
        continuation.yield(())
        continuation.finish()
        let snapshots = await delayed.value

        XCTAssertEqual(snapshots.map(\.title), ["saved"])
        let pendingSave = await store.saveTask
        XCTAssertNil(pendingSave)
        try await store.flush()
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testClearKeepsPinsDurablyAndRejectsEarlierCapture() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        let first = await store.handleCapture(capture("pinned"), epoch: 1)
        let pinnedID = try XCTUnwrap(first.first?.id)
        _ = await store.pin(id: pinnedID, isPinned: true)
        _ = await store.handleCapture(capture("ordinary"), epoch: 1)

        let cleared = try await store.clear(epoch: 2)

        XCTAssertEqual(cleared.map(\.title), ["pinned"])
        XCTAssertTrue(cleared[0].isPinned)
        XCTAssertEqual(try persistedTitles(at: fileURL), ["pinned"])
        let restartedStore = ClipboardHistoryStore(configuration: ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: fileURL.deletingLastPathComponent()
        ))
        let reloaded = await restartedStore.load()
        XCTAssertEqual(reloaded.map(\.title), ["pinned"])
        XCTAssertTrue(reloaded[0].isPinned)
        let afterLateCapture = await store.handleCapture(capture("late"), epoch: 1)
        XCTAssertEqual(afterLateCapture.map(\.title), ["pinned"])
        let afterNewCapture = await store.handleCapture(capture("new"), epoch: 3)
        XCTAssertEqual(afterNewCapture.map(\.title), ["pinned", "new"])
    }

    func testPinnedItemsStayFirstAndSurviveLoweredLimits() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        let first = await store.handleCapture(capture("pin"))
        let pinnedID = try XCTUnwrap(first.first?.id)
        _ = await store.pin(id: pinnedID, isPinned: true)
        _ = await store.handleCapture(capture("first"))
        let latest = await store.handleCapture(capture("second"))
        XCTAssertEqual(latest.map(\.title), ["pin", "second", "first"])

        let lowered = ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 1,
            maxItemBytes: 2,
            maxTotalBytes: 2,
            storageDirectory: fileURL.deletingLastPathComponent()
        )
        let retained = await store.updateConfiguration(lowered)
        XCTAssertEqual(retained.map(\.title), ["pin"])
        let rejected = await store.handleCapture(capture("x"))
        XCTAssertEqual(rejected.map(\.title), ["pin"])
        let cleared = try await store.clear(epoch: 1)
        XCTAssertEqual(cleared.map(\.title), ["pin"])
        XCTAssertEqual(try persistedTitles(at: fileURL), ["pin"])
    }

    func testPinnedAndUnpinnedGroupsRetainRecencyOrder() async throws {
        let (store, _) = try makeStore(sleeper: ClipboardSaveSleeper())
        let first = await store.handleCapture(capture("first"))
        let firstID = try XCTUnwrap(first.first?.id)
        let second = await store.handleCapture(capture("second"))
        let secondID = try XCTUnwrap(second.first?.id)
        _ = await store.pin(id: firstID, isPinned: true)
        let initiallyPinned = await store.pin(id: secondID, isPinned: true)
        XCTAssertEqual(initiallyPinned.map(\.title), ["second", "first"])

        let recalled = await store.handleCapture(capture("first"))
        XCTAssertEqual(recalled.map(\.title), ["first", "second"])
        let unpinned = await store.pin(id: firstID, isPinned: false)
        XCTAssertEqual(unpinned.map(\.title), ["second", "first"])
        XCTAssertTrue(unpinned[0].isPinned)
        XCTAssertFalse(unpinned[1].isPinned)
    }

    func testDerivedAndRecognizedTextUpdateTitlesAndSearchMetadata() async throws {
        let (store, _) = try makeStore(sleeper: ClipboardSaveSleeper())
        let richCapture = capture("{\\rtf1 Rich}", kind: .richText, derivedText: "Rich words")
        let rich = await store.handleCapture(richCapture)
        XCTAssertEqual(rich.first?.title, "Rich words")
        XCTAssertEqual(rich.first?.searchText, "Rich words")
        XCTAssertTrue(rich.first?.canPastePlainText == true)
        let unparsableRich = await store.handleCapture(capture("{\\rtf1 Other}", kind: .richText))
        XCTAssertFalse(unparsableRich.first { $0.title == "Rich Text" }?.canPastePlainText ?? true)

        let imageCapture = capture("image bytes", kind: .image)
        let image = await store.handleCapture(imageCapture)
        let imageID = try XCTUnwrap(image.first { $0.kind == .image }?.id)
        let fetchedImage = await store.item(id: imageID)
        let storedImage = try XCTUnwrap(fetchedImage)
        _ = await store.setRecognizedText(id: imageID, digest: storedImage.digest, text: "")
        let completedWithoutText = await store.item(id: imageID)
        XCTAssertEqual(completedWithoutText?.recognizedText, "")
        let recognized = await store.setRecognizedText(id: imageID, digest: storedImage.digest, text: "Scanned words")
        XCTAssertEqual(recognized.first { $0.id == imageID }?.title, "Scanned words")
        XCTAssertEqual(recognized.first { $0.id == imageID }?.searchText, "Scanned words")
        XCTAssertFalse(recognized.first { $0.id == imageID }?.canPastePlainText ?? true)

        _ = await store.delete(id: imageID)
        let stale = await store.setRecognizedText(id: imageID, digest: storedImage.digest, text: "late")
        XCTAssertEqual(stale.map(\.title), ["Rich Text", "Rich words"])
    }

    func testFailedDurableClearAndFlushLeaveItemsAvailable() async throws {
        let (store, fileURL) = try makeStore(sleeper: ClipboardSaveSleeper())
        _ = await store.handleCapture(capture("kept"))
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        do {
            _ = try await store.clear(epoch: 1)
            XCTFail("Expected clear to report a write failure")
        } catch {}
        do {
            try await store.flush()
            XCTFail("Expected flush to report a write failure")
        } catch {}
        let afterFailures = await store.paletteItems()
        XCTAssertEqual(afterFailures.map(\.title), ["kept"])

        try FileManager.default.removeItem(at: fileURL)
        try await store.flush()
        XCTAssertEqual(try persistedTitles(at: fileURL), ["kept"])
    }

    private func makeStore(sleeper: ClipboardSaveSleeper) throws -> (ClipboardHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let configuration = ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 10,
            maxItemBytes: 4096,
            maxTotalBytes: 40960,
            storageDirectory: directory
        )
        let store = ClipboardHistoryStore(configuration: configuration, sleep: { try await sleeper.sleep(for: $0) })
        return (store, configuration.storageURL)
    }

    private func capture(
        _ text: String,
        kind: ClipboardContentKind = .text,
        derivedText: String? = nil
    ) -> ClipboardPasteboardCapture {
        ClipboardPasteboardCapture(
            contents: [
                ClipboardHistoryContent(
                    itemIndex: 0,
                    type: kind == .text ? "public.utf8-plain-text" : kind.rawValue,
                    kind: kind,
                    data: Data(text.utf8)
                )
            ],
            sourceBundleIdentifier: nil,
            capturedAt: Date(timeIntervalSince1970: 0),
            derivedText: derivedText
        )
    }

    private func persistedTitles(at fileURL: URL) throws -> [String] {
        try JSONDecoder().decode([ClipboardHistoryItem].self, from: Data(contentsOf: fileURL)).map(\.title)
    }
}

private actor ClipboardSaveSleeper {
    let requests: AsyncStream<Duration>
    private let requestContinuation: AsyncStream<Duration>.Continuation
    private var sleepers: [CheckedContinuation<Void, any Error>] = []

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream()
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(continuation)
            requestContinuation.yield(duration)
        }
    }

    func resumeNext(throwing error: (any Error)? = nil) {
        let continuation = sleepers.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
