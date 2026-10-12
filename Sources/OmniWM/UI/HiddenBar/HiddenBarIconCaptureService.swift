// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import ScreenCaptureKit

struct CapturedIcon: Sendable {
    let image: CGImage
    let scale: CGFloat
}

enum HiddenBarIconCaptureService {
    static let captureDeadline: Duration = .milliseconds(500)

    static func captureVisible(_ items: [ResolvedMenuBarItem]) async -> [MenuBarItemKey: CapturedIcon] {
        guard !items.isEmpty else { return [:] }
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        guard let icons = await captureMenuBarBand(items) else {
            FallbackFiringRecorder.shared.note(.capture, "hiddenBarVisibleCaptureFailed")
            return [:]
        }
        return icons
    }

    static func captureVisible(
        _ items: [ResolvedMenuBarItem],
        timeout: Duration
    ) async -> [MenuBarItemKey: CapturedIcon] {
        let state = RunLoopResumeState<[MenuBarItemKey: CapturedIcon]>()
        let captureTask = Task {
            let icons = await captureVisible(items)
            guard let continuation = state.takeContinuation(orStore: .success(icons)) else { return }
            continuation.resume(returning: icons)
        }

        return (try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingResult = state.install(continuation) {
                    continuation.resume(with: pendingResult)
                    return
                }
                Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    captureTask.cancel()
                    guard let continuation = state.takeContinuation(orStore: .success([:])) else { return }
                    continuation.resume(returning: [:])
                }
            }
        } onCancel: {
            captureTask.cancel()
            guard let continuation = state.takeContinuation(orStore: .failure(CancellationError())) else { return }
            continuation.resume(throwing: CancellationError())
        }) ?? [:]
    }

    private static func captureMenuBarBand(
        _ items: [ResolvedMenuBarItem]
    ) async -> [MenuBarItemKey: CapturedIcon]? {
        let bounds = items.map(\.bounds)
        let union = bounds.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return nil }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else { return nil }

        let display = content.displays
            .map { ($0, $0.frame.intersection(union)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
        guard let display else { return nil }

        let window = content.windows.lazy.filter {
            isMenuBarHostingWindow(
                bundleIdentifier: $0.owningApplication?.bundleIdentifier,
                layer: $0.windowLayer,
                frame: $0.frame,
                displayFrame: display.frame,
                itemBounds: union
            )
        }.max { $0.windowID < $1.windowID }
        guard let window else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())

        guard let composite = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }

        var result: [MenuBarItemKey: CapturedIcon] = [:]
        let rects = cropRects(bounds: bounds, union: window.frame, scale: scale)
        let imageBounds = CGRect(x: 0, y: 0, width: composite.width, height: composite.height)
        for (item, rect) in zip(items, rects) {
            let rect = rect.intersection(imageBounds)
            guard !rect.isNull, !rect.isEmpty,
                  let cropped = isolatedCrop(composite, to: rect),
                  !isEffectivelyTransparent(cropped)
            else { continue }
            result[item.key] = CapturedIcon(image: cropped, scale: scale)
        }
        return result.isEmpty ? nil : result
    }

    static func isolatedCrop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let cropped = image.cropping(to: rect),
              let context = CGContext(
                  data: nil,
                  width: cropped.width,
                  height: cropped.height,
                  bitsPerComponent: 8,
                  bytesPerRow: cropped.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    static func isMenuBarHostingWindow(
        bundleIdentifier: String?,
        layer: Int,
        frame: CGRect,
        displayFrame: CGRect,
        itemBounds: CGRect
    ) -> Bool {
        bundleIdentifier == "com.apple.MenuBarAgent"
            && layer == Int(CGWindowLevelForKey(.mainMenuWindow))
            && frame.minX == displayFrame.minX
            && frame.minY == displayFrame.minY
            && frame.width == displayFrame.width
            && frame.height > 0
            && frame.height <= 40
            && frame.contains(itemBounds)
    }

    static func cropRects(bounds: [CGRect], union: CGRect, scale: CGFloat) -> [CGRect] {
        bounds.map { rect in
            CGRect(
                x: (rect.origin.x - union.origin.x) * scale,
                y: (rect.origin.y - union.origin.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
        }
    }

    static func isEffectivelyTransparent(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }
        switch image.alphaInfo {
        case .none,
             .noneSkipFirst,
             .noneSkipLast:
            return false
        default:
            break
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel[3] == 0
    }
}
