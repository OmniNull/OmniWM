// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct NiriScrollTracker {
    let tick: CGFloat
    var last: CGFloat = 0.0
    var accumulator: CGFloat = 0.0

    mutating func accumulate(_ amount: CGFloat) -> Int {
        let changedDirection = (last > 0 && amount < 0) || (last < 0 && amount > 0)
        if changedDirection {
            accumulator = 0.0
        }

        last = amount
        accumulator += amount

        guard abs(accumulator) >= tick else { return 0 }

        let clamped = accumulator.clamped(to: (-127 * tick) ... (127 * tick))
        let ticks = Int(clamped / tick)
        accumulator.formTruncatingRemainder(dividingBy: tick)
        return ticks
    }

    mutating func reset() {
        last = 0.0
        accumulator = 0.0
    }
}
