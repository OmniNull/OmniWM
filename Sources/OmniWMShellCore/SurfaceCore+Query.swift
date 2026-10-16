// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public struct ElementPathStep: Equatable, Sendable, BitwiseCopyable {
    public var kind: ElementKind
    public var key: UInt64
    public var child: Int

    public init(kind: ElementKind, key: UInt64, child: Int) {
        self.kind = kind
        self.key = key
        self.child = child
    }
}

extension SurfaceCore {
    public func resolve(path: [ElementPathStep]) -> ElementHandle {
        guard !path.isEmpty, path.count <= 65, path[0].child == 0, root >= 0 else { return .none }
        var slot = root
        for (depth, step) in path.enumerated() {
            if depth > 0 {
                guard step.child >= 0, step.child < liveCount else { return .none }
                slot = firstChild[Int(slot)]
                var offset = 0
                while slot >= 0, offset < step.child {
                    slot = nextSibling[Int(slot)]
                    offset += 1
                }
            }
            guard slot >= 0, kind[Int(slot)] == step.kind, key[Int(slot)] == step.key else { return .none }
        }
        return handle(slot)
    }

    public func firstDescendant(of handle: ElementHandle, matching predicate: (Content) -> Bool) -> ElementHandle {
        guard contains(handle) else { return .none }
        var slot = firstChild[Int(handle.slot)]
        while slot >= 0 {
            if predicate(content[Int(slot)]) {
                return self.handle(slot)
            }
            if firstChild[Int(slot)] >= 0 {
                slot = firstChild[Int(slot)]
                continue
            }
            while slot != handle.slot, nextSibling[Int(slot)] < 0 {
                slot = parent[Int(slot)]
            }
            guard slot != handle.slot else { return .none }
            slot = nextSibling[Int(slot)]
        }
        return .none
    }

    public func elements(matching predicate: (Content) -> Bool) -> [ElementHandle] {
        var found: [ElementHandle] = []
        var stack: [Int32] = root >= 0 ? [root] : []
        while let slot = stack.popLast() {
            if predicate(content[Int(slot)]) {
                found.append(handle(slot))
            }
            var child = firstChild[Int(slot)]
            while child >= 0 {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
        }
        return found
    }

    public func hitPath(
        x: Float,
        y: Float,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> [ElementHandle] {
        var path: [ElementHandle] = []
        hitPath(x: x, y: y, matching: predicate, clip: clip, into: &path)
        return path
    }

    public func hitPath(
        x: Float,
        y: Float,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool,
        into path: inout [ElementHandle]
    ) {
        var slot = root
        var localX = x
        var localY = y
        while slot >= 0 {
            let rect = frame[Int(slot)]
            localX -= rect.x
            localY -= rect.y
            guard localX >= 0, localY >= 0, localX < rect.width, localY < rect.height,
                  clip(handle(slot), localX, localY)
            else {
                break
            }
            if predicate(content[Int(slot)]) {
                path.append(handle(slot))
            }
            let shift = scrollShift(slot)
            localX += shift.x
            localY += shift.y
            var top: Int32 = -1
            var child = firstChild[Int(slot)]
            while child >= 0 {
                let childRect = frame[Int(child)]
                if localX >= childRect.x, localY >= childRect.y,
                   localX < childRect.x + childRect.width, localY < childRect.y + childRect.height
                {
                    top = child
                }
                child = nextSibling[Int(child)]
            }
            slot = top
        }
    }

    public func covers(
        x: Float,
        y: Float,
        where predicate: (ElementHandle) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> Bool {
        root >= 0 && covers(root, x: x, y: y, where: predicate, clip: clip)
    }

    func covers(
        _ slot: Int32,
        x: Float,
        y: Float,
        where predicate: (ElementHandle) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool
    ) -> Bool {
        let rect = frame[Int(slot)]
        guard clip(handle(slot), x - rect.x, y - rect.y) else { return false }
        let inside = x - rect.x >= 0 && y - rect.y >= 0 && x - rect.x < rect.width && y - rect.y < rect.height
        if inside, predicate(handle(slot)) {
            return true
        }
        guard inside || !content[Int(slot)].scrolls else { return false }
        let shift = scrollShift(slot)
        var child = firstChild[Int(slot)]
        while child >= 0 {
            if covers(child, x: x - rect.x + shift.x, y: y - rect.y + shift.y, where: predicate, clip: clip) {
                return true
            }
            child = nextSibling[Int(child)]
        }
        return false
    }

    public func hitTest(
        x: Float,
        y: Float,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> ElementHandle {
        root >= 0 ? hit(root, x: x, y: y, matching: predicate, clip: clip) : .none
    }

    func hit(
        _ slot: Int32,
        x: Float,
        y: Float,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool
    ) -> ElementHandle {
        let rect = frame[Int(slot)]
        let shift = scrollShift(slot)
        guard x - rect.x >= 0, y - rect.y >= 0, x - rect.x < rect.width, y - rect.y < rect.height,
              clip(handle(slot), x - rect.x, y - rect.y)
        else {
            return .none
        }
        let localX = x - rect.x + shift.x
        let localY = y - rect.y + shift.y
        var found = ElementHandle.none
        var child = firstChild[Int(slot)]
        while child >= 0 {
            let candidate = hit(child, x: localX, y: localY, matching: predicate, clip: clip)
            if candidate.slot >= 0 {
                found = candidate
            }
            child = nextSibling[Int(child)]
        }
        if found.slot < 0, predicate(content[Int(slot)]) {
            return handle(slot)
        }
        return found
    }
}
