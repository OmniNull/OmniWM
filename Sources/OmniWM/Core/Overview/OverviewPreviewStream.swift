// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization

final class OverviewPreviewStream: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private struct State {
        var active = true
        var scheduled = false
        var pending: OverviewPreviewFrame?
    }

    private let state = Mutex(State())
    private let onReady: @Sendable () -> Void
    private let onFailure: @Sendable () -> Void

    init(onReady: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable () -> Void) {
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func offer(_ frame: OverviewPreviewFrame) {
        let schedule = state.withLock { value in
            guard value.active else { return false }
            value.pending = frame
            guard !value.scheduled else { return false }
            value.scheduled = true
            return true
        }
        if schedule { onReady() }
    }

    func take() -> OverviewPreviewFrame? {
        state.withLock { value in
            let frame = value.pending
            value.pending = nil
            value.scheduled = false
            return frame
        }
    }

    func invalidate() {
        state.withLock { value in
            value.active = false
            value.pending = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let status = metadata[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let contentRect: CGRect?
        if let dictionary = metadata[.contentRect] as? [String: Any] {
            contentRect = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        } else {
            contentRect = metadata[.contentRect] as? CGRect
        }
        let scaleFactor = (metadata[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        guard let frame = OverviewPreviewFrame(
            pixelBuffer: pixelBuffer,
            contentRect: contentRect,
            scaleFactor: scaleFactor
        ) else { return }
        offer(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        invalidate()
        onFailure()
    }
}

@MainActor
protocol OverviewPreviewStreamControl: AnyObject {
    func start() async throws
    func stop()
}

@MainActor
final class OverviewNativePreviewStream: OverviewPreviewStreamControl {
    private let stream: SCStream

    convenience init(window: SCWindow, request: OverviewPreviewRequest, output: OverviewPreviewStream) throws {
        try self.init(window: window, pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight, output: output)
    }

    init(window: SCWindow, pixelWidth: Int, pixelHeight: Int, output: OverviewPreviewStream) throws {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureDynamicRange = .SDR
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: config,
            delegate: output
        )
        try stream.addStreamOutput(
            output,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "app.omniwm.overview.preview")
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func stop() {
        stream.stopCapture { [self] error in
            withExtendedLifetime(self) {}
            if error != nil { FallbackFiringRecorder.shared.note(.capture, "overviewStreamStopException") }
        }
    }
}
