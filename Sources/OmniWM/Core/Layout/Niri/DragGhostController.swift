// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ScreenCaptureKit

@MainActor
final class DragGhostController {
    typealias ImageCapture = @MainActor (WindowToken, CGSize) async -> CGImage?

    private static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private(set) var ghostWindow: DragGhostWindow?
    private(set) var captureTask: Task<Void, Never>?
    private var isActive: Bool = false
    private var cursorLocation: CGPoint = .zero
    private var swapTargetOverlay: SwapTargetOverlay?
    private let surfaceCoordinator: SurfaceCoordinator
    private let previews: PreviewCaptureCoordinator
    private let captureAccessAllowed: @MainActor () -> Bool
    private let captureImage: ImageCapture

    init(
        surfaceCoordinator: SurfaceCoordinator = .shared,
        previews: PreviewCaptureCoordinator = .shared,
        captureAccessAllowed: @escaping @MainActor () -> Bool = { ScreenCapturePermissionMonitor.shared.isGranted },
        captureImage: ImageCapture? = nil
    ) {
        self.surfaceCoordinator = surfaceCoordinator
        self.previews = previews
        self.captureAccessAllowed = captureAccessAllowed
        self.captureImage = captureImage ?? { token, pixelSize in
            await Self.captureWindowImage(token: token, pixelSize: pixelSize, previews: previews)
        }
    }

    isolated deinit {
        destroy()
    }

    func beginDrag(token: WindowToken, originalFrame: CGRect, cursorLocation: CGPoint) {
        isActive = true
        self.cursorLocation = cursorLocation
        captureTask?.cancel()

        let size = CGSize(width: originalFrame.width * 0.5, height: originalFrame.height * 0.5)
        let scale = NSScreen.screen(containing: cursorLocation)?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if let shared = previews.sharedPreview(for: token)?.frame {
            show(shared.surface, contentsRect: shared.contentsRect, holding: shared, size: size)
        }
        guard captureAccessAllowed() else { return }
        captureTask = Task { [weak self, captureImage] in
            guard let image = await captureImage(token, pixelSize) else { return }
            guard let self, isActive, !Task.isCancelled else { return }
            show(image, contentsRect: Self.unitRect, holding: nil, size: size)
        }
    }

    func updatePosition(cursorLocation: CGPoint) {
        guard isActive else { return }
        self.cursorLocation = cursorLocation
        ghostWindow?.moveTo(cursorLocation: cursorLocation)
    }

    func endDrag() {
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        ghostWindow?.hideGhost()
        hideSwapTarget()
    }

    func showSwapTarget(frame: CGRect) {
        guard isActive else { return }
        if swapTargetOverlay == nil {
            swapTargetOverlay = SwapTargetOverlay(surfaceCoordinator: surfaceCoordinator)
        }
        swapTargetOverlay?.show(at: frame)
    }

    func hideSwapTarget() {
        swapTargetOverlay?.hide()
    }

    func destroy() {
        endDrag()
        ghostWindow?.destroy()
        ghostWindow = nil
        swapTargetOverlay?.destroy()
        swapTargetOverlay = nil
    }

    private func show(_ contents: Any, contentsRect: CGRect, holding preview: OverviewPreviewFrame?, size: CGSize) {
        if ghostWindow == nil {
            ghostWindow = DragGhostWindow(surfaceCoordinator: surfaceCoordinator)
        }
        ghostWindow?.setContents(contents, contentsRect: contentsRect, holding: preview, size: size)
        ghostWindow?.showAt(cursorLocation: cursorLocation)
    }

    private static func captureWindowImage(
        token: WindowToken,
        pixelSize: CGSize,
        previews: PreviewCaptureCoordinator
    ) async -> CGImage? {
        guard let window = await previews.window(for: token).window else {
            FallbackFiringRecorder.shared.note(.capture, "dragGhostWindowMapMiss")
            return nil
        }
        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
        } catch {
            ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
            FallbackFiringRecorder.shared.note(.capture, "dragGhostCaptureException")
            return nil
        }
    }
}
