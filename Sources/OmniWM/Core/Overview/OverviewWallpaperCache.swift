// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO

@MainActor
final class OverviewWallpaperCache {
    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    private final class Capture {
        let frame: CGRect
        var unavailable = false
        var thumbnails: [Int: CGImage] = [:]

        init(frame: CGRect) {
            self.frame = frame
        }
    }

    private var images: [Key: CGImage] = [:]
    private var urlsByDisplay: [CGDirectDisplayID: URL] = [:]
    private var capturesByDisplay: [CGDirectDisplayID: Capture] = [:]
    var captureWallpaper: (CGRect) -> CGImage? = { frame in
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return SkyLight.shared.captureWallpaper(in: frame)
    }

    var desktopImageURL: (CGDirectDisplayID) -> URL? = { displayId in
        NSScreen.screens.first { $0.displayId == displayId }
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    static func bucketedPixelSize(_ pixelSize: CGFloat) -> Int {
        let sizes = [64, 512, 1024, 2048, 4096]
        return sizes.first { CGFloat($0) >= pixelSize } ?? 4096
    }

    func image(for displayId: CGDirectDisplayID, maxPixelSize: Int, frame: CGRect? = nil) -> CGImage? {
        let frame = frame ?? CGDisplayBounds(displayId)
        if !frame.isEmpty, let image = capturedImage(for: displayId, frame: frame, maxPixelSize: maxPixelSize) {
            return image
        }
        return fileImage(for: displayId, maxPixelSize: maxPixelSize)
    }

    // Retain only requested thumbnails, not a second full-size copy of each desktop.
    private func capturedImage(for displayId: CGDirectDisplayID, frame: CGRect, maxPixelSize: Int) -> CGImage? {
        if capturesByDisplay[displayId]?.frame != frame {
            capturesByDisplay[displayId] = Capture(frame: frame)
        }
        guard let capture = capturesByDisplay[displayId] else { return nil }
        if let thumbnail = capture.thumbnails[maxPixelSize] { return thumbnail }
        guard !capture.unavailable else { return nil }
        guard let image = captureWallpaper(frame),
              image.width >= Int(ceil(frame.width)), image.height >= Int(ceil(frame.height)),
              let thumbnail = Self.thumbnail(image, maxPixelSize: maxPixelSize)
        else {
            capture.unavailable = true
            return nil
        }
        capture.thumbnails[maxPixelSize] = thumbnail
        return thumbnail
    }

    private static func thumbnail(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // File URLs remain a fallback when Screen Recording or wallpaper-window capture is unavailable.
    private func fileImage(for displayId: CGDirectDisplayID, maxPixelSize: Int) -> CGImage? {
        let url = desktopImageURL(displayId)
        let previousURL = urlsByDisplay[displayId]
        urlsByDisplay[displayId] = url
        if let previousURL, previousURL != url, !urlsByDisplay.values.contains(previousURL) {
            images = images.filter { $0.key.url != previousURL }
        }
        guard let url else { return nil }
        let key = Key(url: url, maxPixelSize: maxPixelSize)
        if let cached = images[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        images[key] = image
        return image
    }

    func clear() {
        images.removeAll()
        urlsByDisplay.removeAll()
        capturesByDisplay.removeAll()
    }
}
