// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreVideo
import Foundation
@testable import OmniWM
import XCTest

enum OverviewPreviewTestWaitError: Error {
    case starts(Int)
    case stops(Int)
    case publication
}

@MainActor
final class OverviewPreviewTestStream: OverviewPreviewStreamControl {
    let request: OverviewPreviewRequest
    let output: OverviewPreviewStream
    private let onStart: @MainActor () -> Void
    private let onStop: @MainActor () -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var stopCount = 0
    private var isFinished = false

    init(
        request: OverviewPreviewRequest,
        output: OverviewPreviewStream,
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.request = request
        self.output = output
        self.onStart = onStart
        self.onStop = onStop
    }

    func start() async throws {
        guard !isFinished else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onStart()
        }
    }

    func completeStart(error: (any Error)? = nil) {
        let continuation = continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func finish() {
        isFinished = true
        output.invalidate()
        completeStart(error: CancellationError())
    }

    func stop() {
        stopCount += 1
        onStop()
    }
}

@MainActor
final class OverviewPreviewManualSleeper {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async throws {
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func resumeAll() {
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

@MainActor
final class OverviewPreviewTestDriver {
    let coordinator = PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry())
    private(set) var streams: [OverviewPreviewTestStream] = []
    private var startedCount = 0
    private var startWaiters: [(Int, XCTestExpectation)] = []
    private var stoppedCount = 0
    private var stopWaiters: [(Int, XCTestExpectation)] = []
    private var isFinished = false

    func makeCapture(
        consumer: OverviewFrameTrace.PreviewConsumer = .overview,
        traceRecorder: OverviewFrameTrace.Recorder = OverviewFrameTrace.shared,
        hasCaptureAccess: @escaping @MainActor () -> Bool = { true },
        adoptsProvisionalPreviews: Bool = true,
        maximumRetainedBytes: Int = 128 * 1_024 * 1_024,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> OverviewThumbnailCapture {
        OverviewThumbnailCapture(
            coordinator: coordinator,
            consumer: consumer,
            traceRecorder: traceRecorder,
            hasCaptureAccess: hasCaptureAccess,
            adoptsProvisionalPreviews: adoptsProvisionalPreviews,
            maximumRetainedBytes: maximumRetainedBytes,
            sleep: sleep,
            streamFactory: { [self] request, output in
                guard !isFinished else { throw CancellationError() }
                let stream = OverviewPreviewTestStream(request: request, output: output, onStart: { [self] in
                    startedCount += 1
                    let ready = startWaiters.filter { $0.0 <= startedCount }
                    startWaiters.removeAll { $0.0 <= startedCount }
                    for (_, waiter) in ready { waiter.fulfill() }
                }, onStop: { [self] in
                    stoppedCount += 1
                    let ready = stopWaiters.filter { $0.0 <= stoppedCount }
                    stopWaiters.removeAll { $0.0 <= stoppedCount }
                    for (_, waiter) in ready { waiter.fulfill() }
                })
                streams.append(stream)
                return stream
            }
        )
    }

    func waitForStarts(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard startedCount < count else { return }
        let started = XCTestExpectation(description: "Preview start count \(count)")
        startWaiters.append((count, started))
        defer { startWaiters.removeAll { $0.1 === started } }
        guard await XCTWaiter.fulfillment(of: [started], timeout: 1) == .completed,
              startedCount >= count
        else {
            XCTFail("Expected \(count) preview starts; received \(startedCount)", file: file, line: line)
            throw OverviewPreviewTestWaitError.starts(count)
        }
    }

    func completeAllStarts() {
        for stream in streams { stream.completeStart() }
    }

    func waitForStops(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard stoppedCount < count else { return }
        let stopped = XCTestExpectation(description: "Preview stop count \(count)")
        stopWaiters.append((count, stopped))
        defer { stopWaiters.removeAll { $0.1 === stopped } }
        guard await XCTWaiter.fulfillment(of: [stopped], timeout: 1) == .completed,
              stoppedCount >= count
        else {
            XCTFail("Expected \(count) preview stops; received \(stoppedCount)", file: file, line: line)
            throw OverviewPreviewTestWaitError.stops(count)
        }
    }

    func finish() {
        isFinished = true
        for stream in streams { stream.finish() }
        streams.removeAll()
    }
}

func makeOverviewPreviewFrame(
    width: Int = 80,
    height: Int = 60,
    contentRect: CGRect? = nil,
    scaleFactor: CGFloat = 1
) throws -> OverviewPreviewFrame {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    let result = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    XCTAssertEqual(result, kCVReturnSuccess)
    return try XCTUnwrap(OverviewPreviewFrame(
        pixelBuffer: XCTUnwrap(pixelBuffer),
        contentRect: contentRect,
        scaleFactor: scaleFactor
    ))
}
