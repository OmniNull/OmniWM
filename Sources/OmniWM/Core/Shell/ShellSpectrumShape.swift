// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellSpectrumShapeRecipe: Equatable, Sendable {
    struct Spring: Hashable, Sendable {
        let response: Double
        let bounce: Double
    }

    struct Swell: Equatable, Sendable {
        let width: Double
        let height: Double
    }

    let band: Double
    let gain: Double
    let taper: Double
    let inset: Double
    let threshold: Double
    let spring: Spring
    let swell: Swell?

    init?(_ source: String) {
        guard let record = ShellRecipeFields(source, prefix: "spectrum", count: 8, limit: 256, allowed: ["swell"]),
              let band = ShellRecipeFields.number(record.base[1], in: 0 ... 1),
              let gain = ShellRecipeFields.number(record.base[2], in: 0 ... 10),
              let taper = ShellRecipeFields.number(record.base[3], in: 0 ... 1),
              let inset = ShellRecipeFields.number(record.base[4], in: 0 ... 256),
              let threshold = ShellRecipeFields.number(record.base[5], in: 0 ... 256),
              let response = ShellRecipeFields.number(record.base[6], in: 0.05 ... 2.5),
              let bounce = ShellRecipeFields.number(record.base[7], in: 0 ... 0.95) else { return nil }
        self.band = band
        self.gain = gain
        self.taper = taper
        self.inset = inset
        self.threshold = threshold
        spring = Spring(response: response, bounce: bounce)
        if let fields = record.sections["swell"] {
            guard fields.count == 2, let width = ShellRecipeFields.number(fields[0], in: 0 ... 256),
                  let height = ShellRecipeFields.number(fields[1], in: 0 ... 256) else { return nil }
            swell = Swell(width: width, height: height)
        } else { swell = nil }
    }

    static func bass(_ bands: InlineArray<24, Float>) -> Double {
        (Double(bands[0]) + Double(bands[1]) + Double(bands[2])) / 3
    }

    func shape(_ base: ShellGlassShape, bands: InlineArray<24, Float>) -> (shape: ShellGlassShape, visible: Bool) {
        if let swell {
            let level = min(1, gain * Self.bass(bands))
            let rect = CGRect(
                x: base.rect.minX - swell.width * level / 2,
                y: base.rect.minY,
                width: base.rect.width + swell.width * level,
                height: base.rect.height + swell.height * level
            )
            return (base.with(rect: rect, radius: base.radius), true)
        }
        let position = band * 23
        let lower = min(22, Int(position))
        let fraction = position - Double(lower)
        let sample = max(0, Double(bands[lower]) + Double(bands[lower + 1] - bands[lower]) * fraction)
        let height = min(1, pow(sample, 1.4) * gain) * taper * max(0, Double(base.rect.height) - inset)
        let visible = height > threshold
        let length = height + min(inset, Double(base.rect.height))
        let direction = CGPoint(x: sin(base.rotation), y: -cos(base.rotation))
        let distance = (length - Double(base.rect.height)) / 2
        let center = CGPoint(
            x: base.rect.midX + direction.x * distance + (visible ? 0 : 30000),
            y: base.rect.midY + direction.y * distance
        )
        return (base.with(
            rect: CGRect(
                x: center.x - base.rect.width / 2,
                y: center.y - length / 2,
                width: base.rect.width,
                height: max(0.001, length)
            ),
            radius: base.radius
        ), visible)
    }

    static func resample(_ source: ShellSpectrumBands.Bars) -> InlineArray<24, Float> {
        var result = InlineArray<24, Float>(repeating: 0)
        for index in 0 ..< 24 {
            let left = Double(index) * 2.5
            let right = left + 2.5
            var sum: Double = 0
            for sample in Int(left.rounded(.down)) ..< Int(right.rounded(.up)) {
                let value = source[sample]
                let weight = max(0, min(right, Double(sample + 1)) - max(left, Double(sample)))
                sum += Double(value.isFinite ? min(1, max(0, value)) : 0) * weight
            }
            result[index] = Float(sum / 2.5)
        }
        return result
    }
}

final class ShellSpectrumShapeBinding {
    var base: ShellGlassShape
    var recipe: ShellSpectrumShapeRecipe
    var body: Int32?
    var targets: [ShellGlassBody.Track: [CALayer]] = [:]
    var target: ShellGlassShape?
    var visible = false

    init(base: ShellGlassShape, recipe: ShellSpectrumShapeRecipe) {
        self.base = base
        self.recipe = recipe
    }
}

final class ShellSpectrumShapeStore {
    var bindings: [Int32: ShellSpectrumShapeBinding] = [:]
    var bands = ShellSpectrumBands.live
    var motion = MotionSnapshot.enabled
    var visible = true
    var automatic = true
    var timer: (any DispatchSourceTimer)?

    deinit {
        timer?.cancel()
    }
}
