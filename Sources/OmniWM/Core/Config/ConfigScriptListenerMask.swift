// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptListenerMask: Equatable, ExpressibleByArrayLiteral {
    private var occupied: UInt64 = 0
    private var words = InlineArray<64, UInt64>(repeating: 0)

    init() {}

    init(arrayLiteral elements: Int...) {
        for index in elements { insert(index) }
    }

    var isEmpty: Bool {
        occupied == 0
    }

    func contains(_ index: Int) -> Bool {
        words[index / UInt64.bitWidth] & (1 << (index % UInt64.bitWidth)) != 0
    }

    mutating func insert(_ index: Int) {
        let word = index / UInt64.bitWidth
        occupied |= 1 << word
        words[word] |= 1 << (index % UInt64.bitWidth)
    }

    mutating func formUnion(_ other: borrowing Self) {
        var remaining = other.occupied
        occupied |= remaining
        while remaining != 0 {
            let word = remaining.trailingZeroBitCount
            words[word] |= other.words[word]
            remaining &= remaining - 1
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.occupied == rhs.occupied else { return false }
        var remaining = lhs.occupied
        while remaining != 0 {
            let word = remaining.trailingZeroBitCount
            if lhs.words[word] != rhs.words[word] { return false }
            remaining &= remaining - 1
        }
        return true
    }
}
