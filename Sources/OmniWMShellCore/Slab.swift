// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct Slab<Element: BitwiseCopyable>: ~Copyable {
    var base: UnsafeMutablePointer<Element>
    private(set) var count: Int
    var capacity: Int

    init(capacity: Int) {
        let initial = Swift.max(capacity, 4)
        base = UnsafeMutablePointer<Element>.allocate(capacity: initial)
        count = 0
        self.capacity = initial
    }

    deinit {
        base.deallocate()
    }

    subscript(index: Int) -> Element {
        get { base[index] }
        nonmutating set { base[index] = newValue }
    }

    mutating func append(_ element: Element) {
        if count == capacity {
            grow(to: capacity * 2)
        }
        (base + count).initialize(to: element)
        count += 1
    }

    mutating func removeAll() {
        count = 0
    }

    mutating func truncate(to newCount: Int) {
        count = newCount
    }

    mutating func removeLast() -> Element {
        count -= 1
        return base[count]
    }

    mutating func popLast() -> Element? {
        guard count >= 1 else { return nil }
        count -= 1
        return base[count]
    }

    mutating func fill(count newCount: Int, with element: Element) {
        if newCount > capacity {
            var target = capacity
            while target < newCount {
                target *= 2
            }
            grow(to: target)
        }
        base.update(repeating: element, count: Swift.min(count, newCount))
        if newCount > count {
            (base + count).initialize(repeating: element, count: newCount - count)
        }
        count = newCount
    }

    mutating func grow(to newCapacity: Int) {
        let newBase = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        newBase.moveInitialize(from: base, count: count)
        base.deallocate()
        base = newBase
        capacity = newCapacity
    }
}
