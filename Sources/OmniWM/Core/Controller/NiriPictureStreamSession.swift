// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class NiriPictureStreamSession {
    struct Request: Equatable {
        let token: WindowToken
        let pixelWidth: Int
        let pixelHeight: Int

        init(token: WindowToken, size: CGSize, scale: CGFloat) {
            self.token = token
            pixelWidth = max(1, Int(ceil(size.width * scale)))
            pixelHeight = max(1, Int(ceil(size.height * scale)))
        }
    }

    typealias Build = @MainActor () throws -> any OverviewPreviewStreamControl
    typealias Prepare = @MainActor (
        Request, OverviewPreviewStream, @escaping @MainActor (Build?) -> Void
    ) -> Task<Void, Never>?

    enum Phase {
        case preparing
        case ready(Build)
        case starting
        case running
        case failed
        case stopped
    }

    let request: Request
    var phase: Phase = .preparing
    var output: OverviewPreviewStream?
    var preparation: Task<Void, Never>?
    var startTask: Task<Void, Never>?
    var control: (any OverviewPreviewStreamControl)?

    init(request: Request) {
        self.request = request
    }

    func stop(failed: Bool = false) {
        phase = failed ? .failed : .stopped
        output?.invalidate()
        preparation?.cancel()
        preparation = nil
        startTask?.cancel()
        startTask = nil
        control?.stop()
        control = nil
    }

    static func prepareNative(
        _ request: Request,
        output: OverviewPreviewStream,
        completion: @escaping @MainActor (Build?) -> Void
    ) -> Task<Void, Never>? {
        Task { @MainActor in
            guard ScreenCapturePermissionMonitor.shared.isGranted else { completion(nil)
                return
            }
            let discovery = await PreviewCaptureCoordinator.shared.window(for: request.token)
            guard !Task.isCancelled else { return }
            guard let window = discovery.window,
                  window.windowID == request.token.windowId,
                  window.owningApplication?.processID == request.token.pid,
                  ScreenCapturePermissionMonitor.shared.isGranted
            else { completion(nil)
                return
            }
            completion {
                try OverviewNativePreviewStream(
                    window: window, pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight, output: output
                )
            }
        }
    }
}

extension NiriEdgePictures.Picture {
    func acceptStill(_ image: CGImage?) {
        guard content?.preview == nil, let image else { return }
        content = .image(image)
    }
}
