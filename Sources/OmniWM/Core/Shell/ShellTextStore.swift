// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import OmniWMScriptHost
import OmniWMShellCore

enum ShellTextStyle {
    private static let weights: [NSFont.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black
    ]

    static func font(for style: UInt32) -> CTFont {
        let base = style & OMNI_STYLE_BASE_MASK
        let defaultSize: CGFloat = base == 3 || base == 4 ? 10 : 12
        let defaultWeight: NSFont.Weight = switch base {
        case 1: .bold
        case 4: .medium
        default: .regular
        }
        let size = self.size(of: style).map { CGFloat($0) } ?? defaultSize
        if let family = ShellFontFamily(style: style) {
            let index = weightIndex(of: style) ?? weights.firstIndex(of: defaultWeight) ?? 3
            return family.font(size: size, weight: CGFloat(index + 1) * 100, filled: style & OMNI_STYLE_FILLED != 0)
        }
        let weight = self.weight(of: style) ?? defaultWeight
        let font: NSFont = switch base {
        case 2: .monospacedDigitSystemFont(ofSize: size, weight: weight)
        case 4: .monospacedSystemFont(ofSize: size, weight: weight)
        case 5: rounded(.monospacedDigitSystemFont(ofSize: size, weight: weight))
        default: .systemFont(ofSize: size, weight: weight)
        }
        return font as CTFont
    }

    private static func rounded(_ font: NSFont) -> NSFont {
        font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    static func wrappedLines(_ text: NSAttributedString, width: CGFloat, limit: Int) -> [CTLine] {
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let length = text.length
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < limit {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            guard lines.count == limit - 1, start + count < length else {
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                start += count
                continue
            }
            let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(
                string: "…",
                attributes: text.attributes(at: 0, effectiveRange: nil)
            ))
            lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest)
            break
        }
        return lines
    }

    static func wrappedSize(of lines: [CTLine], font: CTFont) -> CGSize {
        let width = lines.reduce(0.0) { widest, line in
            max(widest, CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        }
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent + CTFontGetLeading(font)
        let height = lines.isEmpty ? 0 : CGFloat(lines.count - 1) * lineHeight + ascent + descent
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    static func symbolSize(for style: UInt32) -> Float {
        size(of: style) ?? ShellWireDecoder.symbolSize
    }

    static func symbolWeight(for style: UInt32) -> NSFont.Weight {
        weight(of: style) ?? .regular
    }

    private static func size(of style: UInt32) -> Float? {
        let hundredths = style >> OMNI_STYLE_SIZE_SHIFT
        return hundredths > 0 ? Float(hundredths) / 100 : nil
    }

    private static func weight(of style: UInt32) -> NSFont.Weight? {
        weightIndex(of: style).map { weights[$0] }
    }

    private static func weightIndex(of style: UInt32) -> Int? {
        let index = Int((style & OMNI_STYLE_WEIGHT_MASK) >> OMNI_STYLE_WEIGHT_SHIFT)
        return index > 0 && index <= weights.count ? index - 1 : nil
    }
}

enum ShellFontFamily: UInt32 {
    case sans = 1
    case rubik
    case symbols

    private static let registered: Void = {
        for url in Bundle.module.urls(forResourcesWithExtension: nil, subdirectory: "Fonts") ?? [] {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                Log.shell.error("Failed to load the bundled font \(url.lastPathComponent)")
            }
        }
    }()

    init?(style: UInt32) {
        self.init(rawValue: (style & OMNI_STYLE_FONT_MASK) >> OMNI_STYLE_FONT_SHIFT)
    }

    func font(size: CGFloat, weight: CGFloat, filled: Bool) -> CTFont {
        _ = Self.registered
        var axes = [Self.tag("wght"): weight, Self.tag("opsz"): size]
        switch self {
        case .sans: axes[Self.tag("ROND")] = 25
        case .rubik: break
        case .symbols: axes[Self.tag("FILL")] = filled ? 1 : 0
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: familyName,
            kCTFontVariationAttribute: axes
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private var familyName: String {
        switch self {
        case .sans: "Google Sans Flex"
        case .rubik: "Rubik"
        case .symbols: "Material Symbols Rounded"
        }
    }

    private static func tag(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

struct ShellMeasureTable {
    var keys: UnsafeMutablePointer<UInt64>
    var widths: UnsafeMutablePointer<Float>
    var heights: UnsafeMutablePointer<Float>
    var mask: Int
    var count: Int
    var owner: Unmanaged<ShellTextStore>?
}

final class ShellTextStore {
    private struct WrapKey: Hashable {
        let id: UInt32
        let style: UInt32
        let width: Float
        let lines: UInt8
    }

    private(set) var strings: [String] = [""]
    let table: UnsafeMutablePointer<ShellMeasureTable>
    private var fonts: [UInt32: CTFont] = [:]
    private var wrapped: [WrapKey: Size2] = [:]

    init() {
        table = .allocate(capacity: 1)
        table.initialize(to: Self.makeTable(capacity: 256))
        table.pointee.owner = Unmanaged.passUnretained(self)
    }

    deinit {
        Self.release(table.pointee)
        table.deinitialize(count: 1)
        table.deallocate()
    }

    func string(_ id: UInt32) -> String {
        Int(id) < strings.count ? strings[Int(id)] : ""
    }

    func ingest(_ records: [UInt8], count: Int) {
        records.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            for _ in 0 ..< count {
                guard offset + MemoryLayout<omni_wire_string>.size <= buffer.count else { return }
                let record = (base + offset).loadUnaligned(as: omni_wire_string.self)
                let start = offset + MemoryLayout<omni_wire_string>.size
                let end = start + Int(record.length)
                guard end <= buffer.count else { return }
                let id = Int(record.id)
                while strings.count <= id {
                    strings.append("")
                }
                strings[id] = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[start ..< end]), as: UTF8.self)
                offset = (end + 3) & ~3
            }
        }
    }

    func measureMiss(_ id: UInt32, style: UInt32) -> Size2 {
        let font = fonts[style] ?? ShellTextStyle.font(for: style)
        fonts[style] = font
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: string(id),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let size = Self.turned(
            Size2(width: Float(width.rounded(.up)), height: Float((ascent + descent).rounded(.up))),
            style: style
        )
        insert(key: Self.key(id, style), size: size)
        return size
    }

    func measureWrapped(_ id: UInt32, style: UInt32, width: Float, lines: UInt8) -> Size2 {
        let key = WrapKey(id: id, style: style, width: width, lines: lines)
        if let size = wrapped[key] {
            return size
        }
        let font = fonts[style] ?? ShellTextStyle.font(for: style)
        fonts[style] = font
        let text = NSAttributedString(
            string: string(id),
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let laid = ShellTextStyle.wrappedLines(text, width: CGFloat(width), limit: Int(lines))
        let measured = ShellTextStyle.wrappedSize(of: laid, font: font)
        let size = Self.turned(Size2(width: Float(measured.width), height: Float(measured.height)), style: style)
        wrapped[key] = size
        return size
    }

    private static func turned(_ size: Size2, style: UInt32) -> Size2 {
        style & OMNI_STYLE_QUARTER == 0 ? size : Size2(width: size.height, height: size.width)
    }

    static func key(_ id: UInt32, _ style: UInt32) -> UInt64 {
        (UInt64(id) << 32) | UInt64(style)
    }

    static func slot(_ key: UInt64, mask: Int) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
    }

    private func insert(key: UInt64, size: Size2) {
        if (table.pointee.count + 1) * 2 > table.pointee.mask {
            grow()
        }
        let mask = table.pointee.mask
        var slot = Self.slot(key, mask: mask)
        while table.pointee.keys[slot] != 0 {
            slot = (slot + 1) & mask
        }
        table.pointee.keys[slot] = key
        table.pointee.widths[slot] = size.width
        table.pointee.heights[slot] = size.height
        table.pointee.count += 1
    }

    private func grow() {
        let old = table.pointee
        var next = Self.makeTable(capacity: (old.mask + 1) * 2)
        next.owner = old.owner
        for index in 0 ... old.mask where old.keys[index] != 0 {
            var slot = Self.slot(old.keys[index], mask: next.mask)
            while next.keys[slot] != 0 {
                slot = (slot + 1) & next.mask
            }
            next.keys[slot] = old.keys[index]
            next.widths[slot] = old.widths[index]
            next.heights[slot] = old.heights[index]
            next.count += 1
        }
        table.pointee = next
        Self.release(old)
    }

    private static func makeTable(capacity: Int) -> ShellMeasureTable {
        let keys = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        keys.initialize(repeating: 0, count: capacity)
        let widths = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        widths.initialize(repeating: 0, count: capacity)
        let heights = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        heights.initialize(repeating: 0, count: capacity)
        return ShellMeasureTable(keys: keys, widths: widths, heights: heights, mask: capacity - 1, count: 0, owner: nil)
    }

    private static func release(_ table: ShellMeasureTable) {
        table.keys.deallocate()
        table.widths.deallocate()
        table.heights.deallocate()
    }
}

let shellMeasureText: MeasureText = { context, text, style, maxWidth, lines, width, height in
    guard let table = context?.assumingMemoryBound(to: ShellMeasureTable.self) else { return }
    if lines > 1, maxWidth > 0, let owner = table.pointee.owner {
        let size = owner.takeUnretainedValue().measureWrapped(text, style: style, width: maxWidth, lines: lines)
        width.pointee = size.width
        height.pointee = size.height
        return
    }
    let key = ShellTextStore.key(text, style)
    let mask = table.pointee.mask
    var slot = ShellTextStore.slot(key, mask: mask)
    while table.pointee.keys[slot] != 0 {
        if table.pointee.keys[slot] == key {
            width.pointee = table.pointee.widths[slot]
            height.pointee = table.pointee.heights[slot]
            return
        }
        slot = (slot + 1) & mask
    }
    guard let owner = table.pointee.owner else { return }
    let size = owner.takeUnretainedValue().measureMiss(text, style: style)
    width.pointee = size.width
    height.pointee = size.height
}
