// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ShellGlassRecipe: Equatable, Sendable {
    static let fittedRim: CGFloat = 0.1
    static let glassBandShare: CGFloat = 0.36

    let blend: CGFloat
    let light: CGPoint
    let shadowOffset: CGPoint
    let rim: CGFloat
    let flat: Bool
    let gradientAngle: CGFloat

    init?(_ source: String) {
        guard let record = ShellRecipeFields(source, prefix: "glass", count: 6, limit: 256, allowed: ["optics"]) else {
            return nil
        }
        let fields = record.base
        guard
            let blend = Double(fields[1]), let lx = Double(fields[2]), let ly = Double(fields[3]),
            let sx = Double(fields[4]), let sy = Double(fields[5]),
            [blend, lx, ly, sx, sy].allSatisfy(\.isFinite), (0 ... 256).contains(blend),
            abs(lx) <= 1, abs(ly) <= 1, abs(sx) <= 256, abs(sy) <= 256, hypot(lx, ly) > 0
        else { return nil }
        if let values = record.sections["optics"] {
            guard values.count == 3, let rim = ShellRecipeFields.number(values[0], in: 0 ... 1),
                  let flat = ShellRecipeFields.flag(values[1]),
                  let angle = ShellRecipeFields.number(values[2], in: -1_000_000 ... 1_000_000)
            else { return nil }
            self.rim = CGFloat(rim)
            self.flat = flat
            gradientAngle = CGFloat(angle)
        } else {
            rim = Self.fittedRim
            flat = false
            gradientAngle = 90
        }
        self.blend = CGFloat(blend)
        light = CGPoint(x: lx, y: ly)
        shadowOffset = CGPoint(x: sx, y: sy)
    }

    var band: CGFloat {
        flat ? rim : Self.glassBandShare * max(0, rim - Self.fittedRim)
    }
}
