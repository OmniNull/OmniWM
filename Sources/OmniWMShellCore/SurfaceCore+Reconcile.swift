// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ChildRanges {
    var newBase = 0
    var newCount = 0
    var oldBase = 0
    var oldCount = 0
    var claimedBase = 0
    var matchBase = 0
    var stableBase = 0
}

extension SurfaceCore {
    func matchKey(kind nodeKind: ElementKind, key nodeKey: UInt64, ordinals: inout InlineArray<16, UInt32>) -> UInt64 {
        if nodeKey != 0 {
            return nodeKey & ~unkeyedMarker
        }
        let kindIndex = Int(nodeKind.rawValue)
        let ordinal = ordinals[kindIndex]
        ordinals[kindIndex] = ordinal + 1
        return unkeyedMarker | (UInt64(nodeKind.rawValue) << 32) | UInt64(ordinal)
    }

    func hashIndex(_ value: UInt64, mask: Int) -> Int {
        var mixed = value ^ (value >> 31)
        mixed = mixed &* 0xBF58_476D_1CE4_E5B9
        mixed ^= mixed >> 29
        return Int(truncatingIfNeeded: mixed) & mask
    }

    mutating func reconcileChildren(
        of parentSlot: Int32,
        at treeIndex: Int,
        tree: UnsafeBufferPointer<TreeNode>,
        patches: inout PatchBuffer
    ) {
        var ranges = ChildRanges()
        ranges.newBase = newChildren.count
        var child = treeIndex + 1
        let end = Int(tree[treeIndex].subtreeEnd)
        while child < end {
            newChildren.append(Int32(child))
            child = Int(tree[child].subtreeEnd)
        }
        ranges.newCount = newChildren.count - ranges.newBase
        ranges.oldBase = oldChildren.count
        var existing = firstChild[Int(parentSlot)]
        while existing >= 0 {
            oldChildren.append(existing)
            existing = nextSibling[Int(existing)]
        }
        ranges.oldCount = oldChildren.count - ranges.oldBase
        if ranges.newCount > 0 || ranges.oldCount > 0 {
            reconcileNonEmpty(of: parentSlot, ranges: &ranges, tree: tree, patches: &patches)
        }
        oldChildren.truncate(to: ranges.oldBase)
        newChildren.truncate(to: ranges.newBase)
    }

    mutating func reconcileNonEmpty(
        of parentSlot: Int32,
        ranges: inout ChildRanges,
        tree: UnsafeBufferPointer<TreeNode>,
        patches: inout PatchBuffer
    ) {
        let mask = indexOldChildren(ranges)
        ranges.claimedBase = marks.count
        for _ in 0 ..< ranges.oldCount {
            marks.append(0)
        }
        ranges.matchBase = matches.count
        let structural = matchNewChildren(ranges, mask: mask, tree: tree) || ranges.newCount != ranges.oldCount
        for index in 0 ..< ranges.oldCount where marks[ranges.claimedBase + index] == 0 {
            let slot = oldChildren[ranges.oldBase + index]
            patches.ops.append(.remove(handle(slot)))
            freeSubtree(slot)
        }
        ranges.stableBase = marks.count
        for _ in 0 ..< ranges.newCount {
            marks.append(0)
        }
        if structural {
            markStable(ranges)
        } else {
            for index in 0 ..< ranges.newCount {
                marks[ranges.stableBase + index] = 1
            }
        }
        relinkChildren(of: parentSlot, ranges: ranges, tree: tree, patches: &patches)
        if structural {
            markMeasureDirty(parentSlot)
        }
        marks.truncate(to: ranges.claimedBase)
        matches.truncate(to: ranges.matchBase)
    }

    mutating func indexOldChildren(_ ranges: ChildRanges) -> Int {
        var capacity = 8
        while capacity < ranges.oldCount * 2 {
            capacity *= 2
        }
        let mask = capacity - 1
        hashKeys.fill(count: capacity, with: 0)
        hashValues.fill(count: capacity, with: -1)
        var ordinals = InlineArray<16, UInt32>(repeating: 0)
        for index in 0 ..< ranges.oldCount {
            let slot = Int(oldChildren[ranges.oldBase + index])
            let matchValue = matchKey(kind: kind[slot], key: key[slot], ordinals: &ordinals)
            var probe = hashIndex(matchValue, mask: mask)
            while hashValues[probe] >= 0 {
                probe = (probe + 1) & mask
            }
            hashKeys[probe] = matchValue
            hashValues[probe] = Int32(index)
        }
        return mask
    }

    mutating func matchNewChildren(_ ranges: ChildRanges, mask: Int, tree: UnsafeBufferPointer<TreeNode>) -> Bool {
        var ordinals = InlineArray<16, UInt32>(repeating: 0)
        var structural = false
        for index in 0 ..< ranges.newCount {
            let node = tree[Int(newChildren[ranges.newBase + index])]
            let matchValue = matchKey(kind: node.kind, key: node.key, ordinals: &ordinals)
            let found = claimOldChild(matchValue, kind: node.kind, ranges: ranges, mask: mask)
            matches.append(found)
            if found != Int32(index) {
                structural = true
            }
        }
        return structural
    }

    func claimOldChild(_ matchValue: UInt64, kind nodeKind: ElementKind, ranges: ChildRanges, mask: Int) -> Int32 {
        var probe = hashIndex(matchValue, mask: mask)
        while hashValues[probe] != -1 {
            if hashKeys[probe] == matchValue, hashValues[probe] >= 0 {
                let candidate = hashValues[probe]
                guard kind[Int(oldChildren[ranges.oldBase + Int(candidate)])] == nodeKind,
                      marks[ranges.claimedBase + Int(candidate)] == 0
                else {
                    return -1
                }
                marks[ranges.claimedBase + Int(candidate)] = 1
                return candidate
            }
            probe = (probe + 1) & mask
        }
        return -1
    }

    mutating func relinkChildren(
        of parentSlot: Int32,
        ranges: ChildRanges,
        tree: UnsafeBufferPointer<TreeNode>,
        patches: inout PatchBuffer
    ) {
        firstChild[Int(parentSlot)] = -1
        lastChild[Int(parentSlot)] = -1
        let parentHandle = handle(parentSlot)
        var previous: Int32 = -1
        for index in 0 ..< ranges.newCount {
            let nodeIndex = Int(newChildren[ranges.newBase + index])
            let matched = matches[ranges.matchBase + index]
            if matched >= 0 {
                let slot = oldChildren[ranges.oldBase + Int(matched)]
                appendChild(slot, to: parentSlot)
                if marks[ranges.stableBase + index] == 0 {
                    let after = previous >= 0 ? handle(previous) : .none
                    patches.ops.append(.move(handle(slot), parent: parentHandle, after: after))
                }
                update(slot: slot, node: tree[nodeIndex], patches: &patches)
                reconcileChildren(of: slot, at: nodeIndex, tree: tree, patches: &patches)
                previous = slot
            } else {
                previous = create(at: nodeIndex, parentSlot: parentSlot, after: previous, tree: tree, patches: &patches)
            }
        }
    }

    mutating func markStable(_ ranges: ChildRanges) {
        let tailsBase = lisTails.count
        let previousBase = lisPrevious.count
        for _ in 0 ..< ranges.newCount {
            lisPrevious.append(-1)
        }
        var length = 0
        for index in 0 ..< ranges.newCount {
            let value = matches[ranges.matchBase + index]
            guard value >= 0 else { continue }
            var low = 0
            var high = length
            while low < high {
                let middle = (low + high) / 2
                if matches[ranges.matchBase + Int(lisTails[tailsBase + middle])] < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 {
                lisPrevious[previousBase + index] = lisTails[tailsBase + low - 1]
            }
            if low == length {
                lisTails.append(Int32(index))
                length += 1
            } else {
                lisTails[tailsBase + low] = Int32(index)
            }
        }
        if length > 0 {
            var cursor = lisTails[tailsBase + length - 1]
            while cursor >= 0 {
                marks[ranges.stableBase + Int(cursor)] = 1
                cursor = lisPrevious[previousBase + Int(cursor)]
            }
        }
        lisTails.truncate(to: tailsBase)
        lisPrevious.truncate(to: previousBase)
    }
}
