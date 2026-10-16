// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import OmniWMShellCore
import QuartzCore

extension ShellLayerScene {
    func replaceContents(_ slot: Int32, _ contents: CGImage?, preset: ShellAnimation?, animated: Bool) {
        guard let layer = layers[slot] else { return }
        exitAnimations[slot] = preset
        if animated, let animation = preset, framed.contains(slot) {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = animation.fadeDuration
            layer.add(fade, forKey: "contents")
        }
        layer.contents = contents
    }

    func rasterize(_ text: String, style: UInt32, color: CGColor, maxWidth: CGFloat, lines: Int) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let font = fonts[style] ?? ShellTextStyle.font(for: style)
        fonts[style] = font
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        if lines > 1, maxWidth > 0 {
            return rasterize(
                ShellTextStyle.wrappedLines(
                    NSAttributedString(string: text, attributes: attributes),
                    width: maxWidth,
                    limit: lines
                ),
                font: font
            )
        }
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if maxWidth > 0, CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pixelWidth = Int((width * scale).rounded(.up))
        let pixelHeight = Int(((ascent + descent) * scale).rounded(.up))
        guard let context = textBitmapContext(width: pixelWidth, height: pixelHeight) else {
            return nil
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    func rasterize(_ lines: [CTLine], font: CTFont) -> CGImage? {
        let size = ShellTextStyle.wrappedSize(of: lines, font: font)
        guard size.width > 0, size.height > 0,
              let context = textBitmapContext(
                  width: Int((size.width * scale).rounded(.up)),
                  height: Int((size.height * scale).rounded(.up))
              )
        else {
            return nil
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: 0, y: size.height - ascent - CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    func textBitmapContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        if let context = textContext, context.width == width, context.height == height {
            context.beginPath()
            context.textMatrix = .identity
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            return context
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            return nil
        }
        if context.bytesPerRow <= 1_048_576 / height {
            textContext = context
        }
        return context
    }
}
