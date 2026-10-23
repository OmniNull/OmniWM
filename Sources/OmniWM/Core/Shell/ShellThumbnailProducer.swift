// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ShellThumbnailProducer {
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.thumbnails.decode", qos: .utility)
    private var requests: [UUID: QLThumbnailGenerator.Request] = [:]
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func produce(_ source: ShellResourceStore.ThumbnailSource, request: ShellThumbnailRequest) async throws -> CGImage {
        try Task.checkCancellation()
        if let source = CGImageSourceCreateWithURL(
               source.file as CFURL,
               [kCGImageSourceShouldCache: false] as CFDictionary
           ),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: request.pixels
           ] as CFDictionary)
        {
            try Task.checkCancellation()
            return image
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let points = Double(request.pixels) / request.scale
                let thumbnail = QLThumbnailGenerator.Request(
                    fileAt: source.file, size: CGSize(width: points, height: points), scale: request.scale,
                    representationTypes: [.thumbnail, .icon]
                )
                thumbnail.contentType = UTType(source.uti)
                requests[id] = thumbnail
                QLThumbnailGenerator.shared.generateBestRepresentation(for: thumbnail) { [self] representation, error in
                    let result: Result<CGImage, ShellResourceFailure>
                    if let representation { result = .success(representation.cgImage) }
                    else {
                        result = .failure(ShellResourceFailure(error?.localizedDescription ?? "thumbnail unavailable"))
                    }
                    Task { await self.finish(id, result: result, continuation: continuation) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let request = requests[id] { QLThumbnailGenerator.shared.cancel(request) }
    }

    private func finish(
        _ id: UUID,
        result: Result<CGImage, ShellResourceFailure>,
        continuation: CheckedContinuation<CGImage, any Error>
    ) {
        requests.removeValue(forKey: id)
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}
