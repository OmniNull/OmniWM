// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

final class EdgeScrollAnimation {
    private(set) var from: Double
    private(set) var to: Double
    let speed: Double
    let startTime: TimeInterval

    init(from: Double, to: Double, speed: Double, startTime: TimeInterval) {
        let from = from.isFinite ? from : 0
        self.from = from
        self.to = to.isFinite ? to : from
        self.speed = speed.isFinite ? abs(speed) : 0
        self.startTime = startTime.isFinite ? startTime : 0
    }

    private var direction: Double {
        to >= from ? 1 : -1
    }

    private var duration: TimeInterval {
        speed > 0 ? abs(to - from) / speed : 0
    }

    func value(at time: TimeInterval) -> Double {
        guard time.isFinite else { return to }
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return to }
        return from + direction * speed * elapsed
    }

    func velocity(at time: TimeInterval) -> Double {
        isComplete(at: time) ? 0 : direction * speed
    }

    func isComplete(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return true }
        return time - startTime >= duration
    }

    func offsetBy(_ delta: Double) {
        guard delta.isFinite else { return }
        from += delta
        to += delta
    }
}
