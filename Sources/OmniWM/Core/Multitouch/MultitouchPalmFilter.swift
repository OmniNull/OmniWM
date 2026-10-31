// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

private let multitouchUnclassifiedFingerId: Int32 = 0
private let multitouchFingerIds: ClosedRange<Int32> = 1 ... 5
private let multitouchPalmMajorAxisMillimeters: Float = 20
private let multitouchTrackedPathCount: Int32 = 64

struct MultitouchPalmFilter: Equatable, Sendable {
    private var generation: UInt = 0
    private var palmPaths: UInt64 = 0
    private var framePaths: UInt64 = 0

    mutating func beginFrame(generation: UInt) {
        guard generation != self.generation else { return }
        self = MultitouchPalmFilter()
        self.generation = generation
    }

    mutating func isPalm(pathId: Int32, fingerId: Int32, majorAxis: Float) -> Bool {
        let looksLikePalm = majorAxis > multitouchPalmMajorAxisMillimeters
            || (fingerId != multitouchUnclassifiedFingerId && !multitouchFingerIds.contains(fingerId))
        guard pathId >= 0, pathId < multitouchTrackedPathCount else { return looksLikePalm }
        let path: UInt64 = 1 << UInt64(pathId)
        framePaths |= path
        if looksLikePalm {
            palmPaths |= path
        }
        return palmPaths & path != 0
    }

    mutating func finishFrame() {
        palmPaths &= framePaths
        framePaths = 0
    }
}

struct MultitouchPalmFilters: Sendable {
    private var filters = InlineArray<64, MultitouchPalmFilter>(repeating: MultitouchPalmFilter())

    mutating func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double,
        token: MultitouchGestureSource.RegistrationToken
    ) -> MultitouchGestureSource.RawFrame {
        guard token.slot >= 0, token.slot < filters.count else {
            var unattributed = MultitouchPalmFilter()
            return MultitouchGestureSource.buildRawFrame(
                fingers: fingers,
                count: count,
                timestamp: timestamp,
                palmFilter: &unattributed
            )
        }
        filters[token.slot].beginFrame(generation: token.generation)
        return MultitouchGestureSource.buildRawFrame(
            fingers: fingers,
            count: count,
            timestamp: timestamp,
            palmFilter: &filters[token.slot]
        )
    }
}
