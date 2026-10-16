// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension SurfaceCore {
    mutating func allocateSlot() -> Int32 {
        liveCount += 1
        if let slot = freeSlots.popLast() {
            return slot
        }
        let slot = Int32(generation.count)
        generation.append(0)
        kind.append(.group)
        parent.append(-1)
        firstChild.append(-1)
        lastChild.append(-1)
        nextSibling.append(-1)
        key.append(0)
        layout.append(LayoutStyle())
        paint.append(.none)
        content.append(Content())
        frame.append(.zero)
        measured.append(Size2(width: 0, height: 0))
        scrollOffset.append(0)
        scrollLimit.append(0)
        flags.append(0)
        return slot
    }

    mutating func appendChild(_ slot: Int32, to parentSlot: Int32) {
        parent[Int(slot)] = parentSlot
        nextSibling[Int(slot)] = -1
        guard parentSlot >= 0 else { return }
        let tail = lastChild[Int(parentSlot)]
        if tail >= 0 {
            nextSibling[Int(tail)] = slot
        } else {
            firstChild[Int(parentSlot)] = slot
        }
        lastChild[Int(parentSlot)] = slot
    }

    mutating func create(
        at index: Int,
        parentSlot: Int32,
        after previousSlot: Int32,
        tree: UnsafeBufferPointer<TreeNode>,
        patches: inout PatchBuffer
    ) -> Int32 {
        let node = tree[index]
        let slot = allocateSlot()
        let slotIndex = Int(slot)
        kind[slotIndex] = node.kind
        key[slotIndex] = node.key
        layout[slotIndex] = node.layout
        paint[slotIndex] = node.paint
        content[slotIndex] = node.content
        frame[slotIndex] = Rect(x: .nan, y: .nan, width: .nan, height: .nan)
        scrollOffset[slotIndex] = 0
        scrollLimit[slotIndex] = 0
        flags[slotIndex] = flagAlive | flagMeasureDirty | flagLayoutDirty
        firstChild[slotIndex] = -1
        lastChild[slotIndex] = -1
        appendChild(slot, to: parentSlot)
        let parentHandle = parentSlot >= 0 ? handle(parentSlot) : .none
        let previousHandle = previousSlot >= 0 ? handle(previousSlot) : .none
        patches.ops.append(.insert(handle(slot), parent: parentHandle, kind: node.kind, after: previousHandle))
        if node.content.scrolls {
            patches.ops.append(.setScroll(handle(slot), offset: 0, vertical: node.layout.axis == .column))
        }
        emitContent(
            slot: slot,
            changes: ContentChanges(
                paint: node.paint != .none,
                text: node.content.text != 0 || node.content.iconRef != 0 || node.content.placeholder != 0 || node
                    .content.resourceImageRef != 0,
                value: true,
                shader: true
            ),
            patches: &patches
        )
        var child = index + 1
        let end = Int(node.subtreeEnd)
        var previousChild: Int32 = -1
        while child < end {
            previousChild = create(at: child, parentSlot: slot, after: previousChild, tree: tree, patches: &patches)
            child = Int(tree[child].subtreeEnd)
        }
        return slot
    }

    struct ContentChanges {
        var paint: Bool
        var text: Bool
        var value: Bool
        var shader: Bool
    }

    mutating func emitContent(slot: Int32, changes: ContentChanges, patches: inout PatchBuffer) {
        let slotIndex = Int(slot)
        let elementHandle = handle(slot)
        if changes.paint {
            patches.ops.append(.setPaint(elementHandle, paint[slotIndex]))
        }
        let current = content[slotIndex]
        if kind[slotIndex] == .shader {
            if changes.text || changes.shader {
                patches.ops.append(.setShader(elementHandle))
            }
            return
        }
        if kind[slotIndex] == .path {
            if changes.text || changes.shader {
                patches.ops.append(.setPath(elementHandle))
            }
            return
        }
        if changes.text {
            patches.ops.append(.setText(
                elementHandle,
                text: current.text,
                style: current.style,
                color: current.color,
                maxWidth: current.maxWidth,
                lines: current.lines
            ))
        }
        if changes.value, kind[slotIndex] == .progress || kind[slotIndex] == .slider {
            patches.ops.append(.setValue(elementHandle, value: current.value, color: current.color))
        }
    }

    mutating func update(slot: Int32, node: TreeNode, patches: inout PatchBuffer) {
        let slotIndex = Int(slot)
        if layout[slotIndex] != node.layout {
            layout[slotIndex] = node.layout
            markMeasureDirty(slot)
        }
        var paintChanged = false
        if paint[slotIndex] != node.paint {
            paint[slotIndex] = node.paint
            paintChanged = true
        }
        let old = content[slotIndex]
        let new = node.content
        if old.scrolls != new.scrolls {
            scrollOffset[slotIndex] = 0
            patches.ops.append(.setScroll(handle(slot), offset: 0, vertical: node.layout.axis == .column))
        }
        let textChanged = old.text != new.text || old.style != new.style || old.color != new.color
            || old.maxWidth != new.maxWidth || old.lines != new.lines || old.iconSource != new.iconSource
            || old.iconRef != new.iconRef
            || old.placeholder != new.placeholder
            || old.evenOdd != new.evenOdd
            || old.textureRef != new.textureRef
            || old.resourceImageRef != new.resourceImageRef || old.thumbnail != new.thumbnail
        let needsMeasure = old.reserve != new.reserve
            || old.style != new.style
            || old.maxWidth != new.maxWidth
            || old.lines != new.lines
            || (old.text != new.text && new.reserve == 0)
            || (kind[slotIndex] == .path && old.params != new.params)
        content[slotIndex] = new
        if needsMeasure {
            markMeasureDirty(slot)
        }
        emitContent(
            slot: slot,
            changes: ContentChanges(
                paint: paintChanged,
                text: textChanged,
                value: old.value != new.value || old.color != new.color,
                shader: old.params != new.params || old.rate != new.rate
            ),
            patches: &patches
        )
    }

    mutating func markMeasureDirty(_ slot: Int32) {
        var current = slot
        while current >= 0, flags[Int(current)] & flagMeasureDirty == 0 {
            flags[Int(current)] |= flagMeasureDirty | flagLayoutDirty
            current = parent[Int(current)]
        }
    }

    mutating func freeSubtree(_ slot: Int32) {
        let base = freeStack.count
        freeStack.append(slot)
        while freeStack.count > base {
            let current = freeStack.removeLast()
            var child = firstChild[Int(current)]
            while child >= 0 {
                freeStack.append(child)
                child = nextSibling[Int(child)]
            }
            let slotIndex = Int(current)
            flags[slotIndex] = 0
            generation[slotIndex] = generation[slotIndex] &+ 1
            firstChild[slotIndex] = -1
            lastChild[slotIndex] = -1
            nextSibling[slotIndex] = -1
            parent[slotIndex] = -1
            freeSlots.append(current)
            liveCount -= 1
        }
    }
}
