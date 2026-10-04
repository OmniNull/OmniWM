// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreVideo
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class OverviewPreviewTestStream: OverviewPreviewStreamControl {
    let request: OverviewPreviewRequest
    let output: OverviewPreviewStream
    private let onStart: @MainActor () -> Void
    private let onStop: @MainActor () -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var stopCount = 0

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

    func stop() {
        stopCount += 1
        onStop()
    }
}

@MainActor
final class OverviewPreviewTestDriver {
    let coordinator = PreviewCaptureCoordinator(ownedWindowRegistry: OwnedWindowRegistry())
    private(set) var streams: [OverviewPreviewTestStream] = []
    private var startedCount = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stoppedCount = 0
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func makeCapture(
        consumer: OverviewFrameTrace.PreviewConsumer = .overview,
        traceRecorder: OverviewFrameTrace.Recorder = OverviewFrameTrace.shared,
        hasCaptureAccess: @escaping @MainActor () -> Bool = { true },
        adoptsProvisionalPreviews: Bool = true,
        maximumRetainedBytes: Int = 128 * 1_024 * 1_024
    ) -> OverviewThumbnailCapture {
        OverviewThumbnailCapture(
            coordinator: coordinator,
            consumer: consumer,
            traceRecorder: traceRecorder,
            hasCaptureAccess: hasCaptureAccess,
            adoptsProvisionalPreviews: adoptsProvisionalPreviews,
            maximumRetainedBytes: maximumRetainedBytes,
            streamFactory: { [self] request, output in
                let stream = OverviewPreviewTestStream(request: request, output: output, onStart: { [self] in
                    startedCount += 1
                    let ready = startWaiters.filter { $0.0 <= startedCount }
                    startWaiters.removeAll { $0.0 <= startedCount }
                    for (_, waiter) in ready { waiter.resume() }
                }, onStop: { [self] in
                    stoppedCount += 1
                    let ready = stopWaiters.filter { $0.0 <= stoppedCount }
                    stopWaiters.removeAll { $0.0 <= stoppedCount }
                    for (_, waiter) in ready { waiter.resume() }
                })
                streams.append(stream)
                return stream
            }
        )
    }

    func waitForStarts(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func completeAllStarts() {
        for stream in streams { stream.completeStart() }
    }

    func waitForStops(_ count: Int) async {
        guard stoppedCount < count else { return }
        await withCheckedContinuation { stopWaiters.append((count, $0)) }
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
