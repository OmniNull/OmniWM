// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMShellCore

struct ShellManipulationRecipe: Equatable, Sendable {
    struct NativeOutline: Equatable, Sendable {
        let enabled: Bool
        let color: Color
    }

    enum Mode: String, Sendable {
        case move
        case resize
        case scale
    }

    let mode: Mode
    let target: UInt64
    let bounds: CGRect
    let minimum: CGSize
    let maximum: CGSize
    let resizeMask: UInt8
    let inset: CGSize
    let outline: NativeOutline?

    init?(
        mode: Mode,
        target: UInt64,
        bounds: CGRect,
        minimum: CGSize,
        maximum: CGSize,
        resizeMask: UInt8,
        inset: CGSize = .zero,
        outline: NativeOutline? = nil
    ) {
        guard target != 0, (0 ..< 0.5).contains(inset.width), (0 ..< 0.5).contains(inset.height),
              Self.coordinate(bounds.origin.x), Self.coordinate(bounds.origin.y),
              Self.extent(bounds.size.width), Self.extent(bounds.size.height),
              Self.extent(minimum.width), Self.extent(minimum.height),
              Self.extent(maximum.width), Self.extent(maximum.height),
              minimum.width <= maximum.width, minimum.height <= maximum.height,
              maximum.width <= bounds.size.width, maximum.height <= bounds.size.height
        else { return nil }
        switch mode {
        case .move:
            guard resizeMask == 0 else { return nil }
        case .resize:
            guard inset == .zero else { return nil }
            switch resizeMask {
            case 1,
                 2,
                 4,
                 8,
                 5,
                 6,
                 9,
                 10: break
            default: return nil
            }
        case .scale:
            switch resizeMask {
            case 5,
                 6,
                 9,
                 10: break
            default: return nil
            }
        }
        self.mode = mode
        self.target = target
        self.bounds = bounds
        self.minimum = minimum
        self.maximum = maximum
        self.resizeMask = resizeMask
        self.inset = inset
        self.outline = outline
    }

    init?(_ source: String) {
        guard let record = ShellRecipeFields(source, prefix: "manip", count: 14, limit: 512, allowed: ["outline"])
        else {
            return nil
        }
        let fields = record.base
        guard
            let mode = Mode(rawValue: String(fields[1])),
            let target = UInt64(fields[2]),
            let bx = Double(fields[3]), let by = Double(fields[4]),
            let bw = Double(fields[5]), let bh = Double(fields[6]),
            let minW = Double(fields[7]), let minH = Double(fields[8]),
            let maxW = Double(fields[9]), let maxH = Double(fields[10]),
            let resizeMask = UInt8(fields[11]),
            let insetX = Double(fields[12]), let insetY = Double(fields[13])
        else { return nil }
        let outline: NativeOutline?
        if let values = record.sections["outline"] {
            guard values.count == 3, let enabled = ShellRecipeFields.flag(values[0]),
                  let packed = UInt32(values[1]), let role = UInt16(values[2]),
                  enabled || (packed == 0 && role == 0)
            else { return nil }
            outline = NativeOutline(enabled: enabled, color: Color(packed: packed, role: role))
        } else {
            outline = nil
        }
        self.init(
            mode: mode,
            target: target,
            bounds: CGRect(x: bx, y: by, width: bw, height: bh),
            minimum: CGSize(width: minW, height: minH),
            maximum: CGSize(width: maxW, height: maxH),
            resizeMask: resizeMask,
            inset: CGSize(width: insetX, height: insetY),
            outline: outline
        )
    }

    private static func coordinate(_ value: CGFloat) -> Bool {
        value.isFinite && abs(value) <= 1_000_000
    }

    private static func extent(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value <= 1_000_000
    }
}
