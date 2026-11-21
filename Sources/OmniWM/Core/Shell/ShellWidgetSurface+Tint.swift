// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetSurface {
    func tinted(_ image: CGImage, _ color: CGColor) -> CGImage {
        guard let context = Self.imageContext(for: image) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage() ?? image
    }

    func faded(_ image: CGImage, _ alpha: CGFloat) -> CGImage {
        guard alpha < 1, let context = Self.imageContext(for: image) else { return image }
        context.setAlpha(alpha)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func imageContext(for image: CGImage) -> CGContext? {
        CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}
