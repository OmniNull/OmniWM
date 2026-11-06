// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ClipboardHistoryServiceTests: XCTestCase {
    func testRTFOnlyPlainTextCopyPreservesTextBeyondSearchLimit() async throws {
        let tail = "RTF complete tail"
        let text = String(repeating: "R", count: ClipboardHistoryStore.searchTextLimit) + tail
        let attributed = NSAttributedString(string: text)
        let data = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))

        try await assertFullPlainTextCopy(data: data, kind: .richText, tail: tail)
    }

    func testHTMLOnlyPlainTextCopyPreservesTextBeyondSearchLimit() async throws {
        let tail = "HTML complete tail"
        let text = String(repeating: "H", count: ClipboardHistoryStore.searchTextLimit) + tail
        let data = Data("<html><body><p>\(text)</p></body></html>".utf8)

        try await assertFullPlainTextCopy(data: data, kind: .html, tail: tail)
    }

    func testFailedClearRetainsPendingCaptureWithoutRecopyingUnchangedClipboard() async throws {
        let configuration = try makeConfiguration()
        let timer = ManualClipboardHistoryTimer()
        let readerGate = DispatchSemaphore(value: 0)
        defer { readerGate.signal() }
        let readStarted = expectation(description: "Pasteboard read started")
        let clearPausedPolling = expectation(description: "Clear paused polling")
        let captureCalls = Mutex(0)
        timer.onInvalidate = { clearPausedPolling.fulfill() }
        let changeCount = ClipboardChangeCount()
        let capture = makeCapture("saved", kind: .text)
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { changeCount.value }
        environment.capturePasteboard = { _ in
            let count = captureCalls.withLock {
                $0 += 1
                return $0
            }
            if count == 1 {
                readStarted.fulfill()
                readerGate.wait()
            }
            return capture
        }
        environment.makeTimer = { _, action in
            timer.action = action
            return timer
        }
        let service = ClipboardHistoryService(configuration: configuration, environment: environment)

        service.start()
        changeCount.value = 1
        timer.fire()
        await fulfillment(of: [readStarted], timeout: failureBound)
        try FileManager.default.createDirectory(at: configuration.storageURL, withIntermediateDirectories: false)
        let clear = Task { @MainActor in try await service.clearHistory() }
        await fulfillment(of: [clearPausedPolling], timeout: failureBound)
        readerGate.signal()
        do {
            _ = try await clear.value
            XCTFail("Expected Clear to report a persistence failure")
        } catch {}

        timer.onInvalidate = nil
        XCTAssertEqual(changeCount.value, 1)
        XCTAssertEqual(service.paletteItems.first?.title, "saved")
        XCTAssertEqual(service.paletteItems.first?.numberOfCopies, 1)
        XCTAssertNotNil(timer.action)
        timer.fire()
        do {
            try await service.flushForQuit()
            XCTFail("Expected the task-draining quit flush to report the blocked save")
        } catch {}
        XCTAssertEqual(service.paletteItems.first?.numberOfCopies, 1)
        XCTAssertEqual(captureCalls.withLock { $0 }, 1)
        XCTAssertNil(timer.action)
        service.resumeAfterCanceledQuit()
        XCTAssertNotNil(timer.action)
    }

    func testQuitFlushWaitsForImageRecognitionAndPersistsText() async throws {
        let configuration = try makeConfiguration()
        let timer = ManualClipboardHistoryTimer()
        let readerGate = DispatchSemaphore(value: 0)
        let recognitionGate = DispatchSemaphore(value: 0)
        defer {
            readerGate.signal()
            recognitionGate.signal()
        }
        let readStarted = expectation(description: "Pasteboard read started")
        let recognitionStarted = expectation(description: "Image recognition started")
        let timerInvalidated = expectation(description: "Quit stopped clipboard polling")
        let quitState = ClipboardQuitCheckState()
        timer.onInvalidate = { timerInvalidated.fulfill() }
        let changeCount = ClipboardChangeCount()
        let capture = makeCapture("image bytes", kind: .image)
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { changeCount.value }
        environment.capturePasteboard = { _ in
            readStarted.fulfill()
            readerGate.wait()
            return capture
        }
        environment.recognizeImageText = { _ in
            recognitionStarted.fulfill()
            recognitionGate.wait()
            return "Recognized words"
        }
        environment.makeTimer = { _, action in
            timer.action = action
            return timer
        }
        let service = ClipboardHistoryService(configuration: configuration, environment: environment)

        service.start()
        changeCount.value = 1
        timer.fire()
        await fulfillment(of: [readStarted], timeout: failureBound)
        let quit = Task { @MainActor in
            defer { quitState.didFinish = true }
            try await service.flushForQuit()
        }
        await fulfillment(of: [timerInvalidated], timeout: failureBound)
        XCTAssertFalse(quitState.didFinish)
        readerGate.signal()
        await fulfillment(of: [recognitionStarted], timeout: failureBound)
        XCTAssertFalse(quitState.didFinish)
        recognitionGate.signal()
        try await quit.value

        let persisted = try JSONDecoder().decode(
            [ClipboardHistoryItem].self,
            from: Data(contentsOf: configuration.storageURL)
        )
        XCTAssertEqual(persisted.first?.recognizedText, "Recognized words")
        XCTAssertEqual(persisted.first?.title, "Recognized words")
    }

    func testDisablingDuringCopyDoesNotRepublishHistory() async throws {
        let configuration = try makeConfiguration()
        let timer = ManualClipboardHistoryTimer()
        let changeCount = ClipboardChangeCount()
        let captured = expectation(description: "Clipboard item captured")
        let disabledStoreSettled = expectation(description: "Store applied the disabled configuration")
        disabledStoreSettled.assertForOverFulfill = false
        let capture = makeCapture("saved", kind: .text)
        weak var activeService: ClipboardHistoryService?
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { changeCount.value }
        environment.capturePasteboard = { _ in capture }
        environment.writePasteboard = { _ in
            var disabled = configuration
            disabled.isEnabled = false
            activeService?.updateConfiguration(disabled)
            activeService?.onPaletteItemsChanged = { items in
                XCTAssertTrue(items.isEmpty)
                disabledStoreSettled.fulfill()
            }
            return true
        }
        environment.makeTimer = { _, action in
            timer.action = action
            return timer
        }
        let service = ClipboardHistoryService(configuration: configuration, environment: environment)
        activeService = service
        service.onPaletteItemsChanged = { items in
            if items.first?.title == "saved" { captured.fulfill() }
        }

        service.start()
        changeCount.value = 1
        timer.fire()
        await fulfillment(of: [captured], timeout: failureBound)
        service.onPaletteItemsChanged = nil
        let id = try XCTUnwrap(service.paletteItems.first?.id)

        let didCopy = await service.copyItemToPasteboard(id: id)
        XCTAssertTrue(didCopy)
        XCTAssertTrue(service.paletteItems.isEmpty)
        await fulfillment(of: [disabledStoreSettled], timeout: failureBound)
    }

    private func assertFullPlainTextCopy(data: Data, kind: ClipboardContentKind, tail: String) async throws {
        let configuration = try makeConfiguration(maxItemBytes: data.count)
        let timer = ManualClipboardHistoryTimer()
        let changeCount = ClipboardChangeCount()
        let captureState = ClipboardCaptureCheckState()
        var copiedText: String?
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { changeCount.value }
        environment.capturePasteboard = { captureConfiguration in
            let item = NSPasteboardItem()
            item.setData(data, forType: kind == .richText ? .rtf : .html)
            return ClipboardHistoryPasteboard.capture(
                pasteboardItems: [item],
                configuration: captureConfiguration
            )
        }
        environment.writePlainTextPasteboard = { text, _ in
            copiedText = text
            return true
        }
        environment.writePasteboard = { _ in
            XCTFail("Formatted pasteboard write was used")
            return false
        }
        environment.makeTimer = { _, action in
            timer.action = action
            return timer
        }
        let service = ClipboardHistoryService(configuration: configuration, environment: environment)
        service.onPaletteItemsChanged = { items in
            if items.first?.kind == kind { captureState.didCapture = true }
        }

        service.start()
        changeCount.value = 1
        timer.fire()
        try await service.flushForQuit()
        XCTAssertTrue(captureState.didCapture, "Rich-only item captured")
        service.onPaletteItemsChanged = nil
        guard let item = service.paletteItems.first else {
            XCTFail("Rich-only item was not captured")
            return
        }
        XCTAssertEqual(item.searchText.count, ClipboardHistoryStore.searchTextLimit)
        XCTAssertFalse(item.searchText.contains(tail))
        XCTAssertTrue(item.canPastePlainText)

        let didCopy = await service.copyItemToPasteboard(id: item.id, plainText: true)
        XCTAssertTrue(didCopy)
        guard let copied = copiedText else {
            XCTFail("Plain-text pasteboard write did not run")
            return
        }
        XCTAssertGreaterThan(copied.count, ClipboardHistoryStore.searchTextLimit)
        XCTAssertTrue(copied.contains(tail))
    }

    private func makeConfiguration(maxItemBytes: Int = 4096) throws -> ClipboardHistoryConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return ClipboardHistoryConfiguration(
            isEnabled: true,
            maxItems: 10,
            maxItemBytes: maxItemBytes,
            maxTotalBytes: maxItemBytes * 10,
            storageDirectory: directory
        )
    }

    private func makeCapture(_ value: String, kind: ClipboardContentKind) -> ClipboardPasteboardCapture {
        ClipboardPasteboardCapture(
            contents: [ClipboardHistoryContent(
                itemIndex: 0,
                type: kind == .text ? "public.utf8-plain-text" : "public.png",
                kind: kind,
                data: Data(value.utf8)
            )],
            sourceBundleIdentifier: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

@MainActor
private final class ManualClipboardHistoryTimer: ClipboardHistoryTimer {
    var action: (@MainActor () -> Void)?
    var onInvalidate: (() -> Void)?

    func fire() {
        action?()
    }

    func invalidate() {
        action = nil
        onInvalidate?()
    }
}

@MainActor
private final class ClipboardChangeCount {
    var value = 0
}

@MainActor
private final class ClipboardQuitCheckState {
    var didFinish = false
}

@MainActor
private final class ClipboardCaptureCheckState {
    var didCapture = false
}
