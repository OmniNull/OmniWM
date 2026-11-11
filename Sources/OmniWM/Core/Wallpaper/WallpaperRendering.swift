// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import ImageIO

struct WallpaperFileStamp: Hashable, Sendable {
    let path: String
    let modified: Double
    let bytes: Int64

    init(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        path = url.standardizedFileURL.path
        modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

struct WallpaperSampleKey: Hashable, Sendable {
    let file: WallpaperFileStamp

    init(_ url: URL) {
        file = WallpaperFileStamp(url)
    }
}

enum WallpaperRendering {
    static func source(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func canvas(aspect: Double, longSide: Int) -> (width: Int, height: Int) {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9.0
        if aspect >= 1 {
            return (longSide, max(1, Int((Double(longSide) / aspect).rounded())))
        }
        return (max(1, Int((Double(longSide) * aspect).rounded())), longSide)
    }

    static func render(
        _ image: CGImage, width: Int, height: Int, placement: WallpaperPlacement, opaque: Bool
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                      : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let scale = placement == .fill
            ? max(Double(width) / imageWidth, Double(height) / imageHeight)
            : min(Double(width) / imageWidth, Double(height) / imageHeight)
        let drawn = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        if opaque {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        ))
        return context.makeImage()
    }

    static func sample(_ key: WallpaperSampleKey) -> [UInt32]? {
        let pixels = ShellWallpaperPalette.read(URL(fileURLWithPath: key.file.path))
            .map(ShellWallpaperPalette.pixels(of:)) ?? []
        return pixels.isEmpty ? nil : pixels
    }

    static func preview(_ url: URL, width: Int, aspect: Double, placement: WallpaperPlacement) -> CGImage? {
        let size = canvas(aspect: aspect, longSide: width)
        guard let image = source(url, maxPixelSize: max(size.width, size.height) * 2) else { return nil }
        return render(image, width: size.width, height: size.height, placement: placement, opaque: true)
    }
}
