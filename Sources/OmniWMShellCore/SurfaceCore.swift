// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public struct PatchBuffer: ~Copyable {
    var ops: Slab<PatchOp>

    public init(capacity: Int) {
        ops = Slab(capacity: capacity)
    }

    deinit {}

    public var count: Int {
        ops.count
    }

    public func op(at index: Int) -> PatchOp {
        ops[index]
    }

    public mutating func removeAll() {
        ops.removeAll()
    }
}

let flagAlive: UInt8 = 1
let flagMeasureDirty: UInt8 = 2
let flagLayoutDirty: UInt8 = 4
let unkeyedMarker: UInt64 = 1 << 63

public struct SurfaceCore: ~Copyable {
    var generation: Slab<UInt32>
    var kind: Slab<ElementKind>
    var parent: Slab<Int32>
    var firstChild: Slab<Int32>
    var lastChild: Slab<Int32>
    var nextSibling: Slab<Int32>
    var key: Slab<UInt64>
    var layout: Slab<LayoutStyle>
    var paint: Slab<Paint>
    var content: Slab<Content>
    var frame: Slab<Rect>
    var measured: Slab<Size2>
    var scrollOffset: Slab<Float>
    var scrollLimit: Slab<Float>
    var flags: Slab<UInt8>
    var freeSlots: Slab<Int32>
    var root: Int32
    var newChildren: Slab<Int32>
    var oldChildren: Slab<Int32>
    var matches: Slab<Int32>
    var marks: Slab<UInt8>
    var hashKeys: Slab<UInt64>
    var hashValues: Slab<Int32>
    var lisTails: Slab<Int32>
    var lisPrevious: Slab<Int32>
    var freeStack: Slab<Int32>
    var measureFunction: MeasureText?
    var measureContext: UnsafeMutableRawPointer?
    public internal(set) var liveCount: Int
    public private(set) var rootBleed: Insets
    public private(set) var rootLimit: Size2

    public init(capacity: Int) {
        generation = Slab(capacity: capacity)
        kind = Slab(capacity: capacity)
        parent = Slab(capacity: capacity)
        firstChild = Slab(capacity: capacity)
        lastChild = Slab(capacity: capacity)
        nextSibling = Slab(capacity: capacity)
        key = Slab(capacity: capacity)
        layout = Slab(capacity: capacity)
        paint = Slab(capacity: capacity)
        content = Slab(capacity: capacity)
        frame = Slab(capacity: capacity)
        measured = Slab(capacity: capacity)
        scrollOffset = Slab(capacity: capacity)
        scrollLimit = Slab(capacity: capacity)
        flags = Slab(capacity: capacity)
        freeSlots = Slab(capacity: capacity)
        root = -1
        newChildren = Slab(capacity: 256)
        oldChildren = Slab(capacity: 256)
        matches = Slab(capacity: 256)
        marks = Slab(capacity: 512)
        hashKeys = Slab(capacity: 256)
        hashValues = Slab(capacity: 256)
        lisTails = Slab(capacity: 256)
        lisPrevious = Slab(capacity: 256)
        freeStack = Slab(capacity: 256)
        measureFunction = nil
        measureContext = nil
        liveCount = 0
        rootBleed = Insets()
        rootLimit = Size2(width: .infinity, height: .infinity)
    }

    deinit {}

    public var rootFrame: Rect {
        root >= 0 ? frame[Int(root)] : .zero
    }

    public var rootSize: Size2 {
        root >= 0 ? measured[Int(root)] : Size2(width: 0, height: 0)
    }

    public var rootHandle: ElementHandle {
        root >= 0 ? handle(root) : .none
    }

    public mutating func apply(
        _ tree: UnsafeBufferPointer<TreeNode>,
        measure measureText: MeasureText,
        context: UnsafeMutableRawPointer?,
        into patches: inout PatchBuffer
    ) {
        measureFunction = measureText
        measureContext = context
        if tree.isEmpty {
            if root >= 0 {
                patches.ops.append(.remove(handle(root)))
                freeSubtree(root)
                root = -1
            }
            return
        }
        let rootNode = tree[0]
        if root >= 0, kind[Int(root)] == rootNode.kind, key[Int(root)] == rootNode.key {
            update(slot: root, node: rootNode, patches: &patches)
            reconcileChildren(of: root, at: 0, tree: tree, patches: &patches)
        } else {
            if root >= 0 {
                patches.ops.append(.remove(handle(root)))
                freeSubtree(root)
            }
            root = create(at: 0, parentSlot: -1, after: -1, tree: tree, patches: &patches)
        }
        arrange(slot: root, to: rootRect(measure(slot: root)), patches: &patches)
    }

    func rootRect(_ size: Size2) -> Rect {
        Rect(
            x: 0,
            y: 0,
            width: Swift.min(size.width, rootLimit.width),
            height: Swift.min(size.height, rootLimit.height)
        )
    }

    public func layoutFrame(of handle: ElementHandle) -> Rect {
        frame[Int(handle.slot)]
    }

    public func layoutStyle(of handle: ElementHandle) -> LayoutStyle {
        layout[Int(handle.slot)]
    }

    public func key(of handle: ElementHandle) -> UInt64 {
        key[Int(handle.slot)]
    }

    public func kind(of handle: ElementHandle) -> ElementKind {
        kind[Int(handle.slot)]
    }

    public func paint(of handle: ElementHandle) -> Paint {
        paint[Int(handle.slot)]
    }

    public func content(of handle: ElementHandle) -> Content {
        content[Int(handle.slot)]
    }

    public func parent(of handle: ElementHandle) -> ElementHandle {
        let slot = parent[Int(handle.slot)]
        return slot >= 0 ? self.handle(slot) : .none
    }

    public func absoluteFrame(of handle: ElementHandle) -> Rect {
        var rect = frame[Int(handle.slot)]
        var current = parent[Int(handle.slot)]
        while current >= 0 {
            let shift = scrollShift(current)
            rect.x += frame[Int(current)].x - shift.x
            rect.y += frame[Int(current)].y - shift.y
            current = parent[Int(current)]
        }
        return rect
    }

    public func scrollShift(_ slot: Int32) -> (x: Float, y: Float) {
        let slotIndex = Int(slot)
        guard content[slotIndex].scrolls else { return (0, 0) }
        return layout[slotIndex].axis == .column ? (0, scrollOffset[slotIndex]) : (scrollOffset[slotIndex], 0)
    }

    public mutating func scroll(_ handle: ElementHandle, by delta: Float) -> Float? {
        guard contains(handle) else { return nil }
        let slotIndex = Int(handle.slot)
        let next = Swift.min(Swift.max(scrollOffset[slotIndex] + delta, 0), scrollLimit[slotIndex])
        guard next != scrollOffset[slotIndex] else { return nil }
        scrollOffset[slotIndex] = next
        return next
    }

    public func contains(_ handle: ElementHandle) -> Bool {
        handle.slot >= 0 && Int(handle.slot) < generation.count && generation[Int(handle.slot)] == handle.generation
    }

    public mutating func setRootLimit(_ limit: Size2, into patches: inout PatchBuffer) {
        guard limit != rootLimit else { return }
        rootLimit = limit
        guard root >= 0 else { return }
        flags[Int(root)] |= flagLayoutDirty
        arrange(slot: root, to: rootRect(measured[Int(root)]), patches: &patches)
    }

    public mutating func setRootBleed(_ bleed: Insets, into patches: inout PatchBuffer) {
        guard bleed != rootBleed else { return }
        rootBleed = bleed
        guard root >= 0 else { return }
        flags[Int(root)] |= flagLayoutDirty
        arrange(slot: root, to: frame[Int(root)], patches: &patches)
    }

    func handle(_ slot: Int32) -> ElementHandle {
        ElementHandle(slot: slot, generation: generation[Int(slot)])
    }
}
