// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

public struct SurfacePresentation: Sendable {
    public struct Group: Sendable {
        public let frame: Rect
        public let scale: Float
        public let visible: Bool

        public init(frame: Rect, scale: Float, visible: Bool) {
            self.frame = frame
            self.scale = scale
            self.visible = visible
        }
    }

    public let targets: [ElementHandle: Group]
    public let groups: [ElementHandle: Group]

    public init(targets: [ElementHandle: Group] = [:], groups: [ElementHandle: Group] = [:]) {
        self.targets = targets
        self.groups = groups
    }

    public func placement(of handle: ElementHandle) -> Group? {
        if !groups.isEmpty, let group = groups[handle] { return group }
        return targets.isEmpty ? nil : targets[handle]
    }

    public func raises(_ handle: ElementHandle) -> Bool {
        !targets.isEmpty && targets[handle] != nil
    }
}

struct SurfaceQueryPoint {
    let x: Float
    let y: Float
    let width: Float
    let height: Float
    var hidden = false

    var inside: Bool {
        !hidden && x >= 0 && y >= 0 && x < width && y < height
    }
}

extension SurfaceCore {
    func enter(_ slot: Int32, x: Float, y: Float, _ presentation: SurfacePresentation?) -> SurfaceQueryPoint {
        guard let placement = presentation?.placement(of: handle(slot)) else {
            let rect = frame[Int(slot)]
            return SurfaceQueryPoint(x: x - rect.x, y: y - rect.y, width: rect.width, height: rect.height)
        }
        guard placement.visible, placement.scale > 0 else {
            return SurfaceQueryPoint(x: 0, y: 0, width: 0, height: 0, hidden: true)
        }
        let rect = placement.frame
        let scale = placement.scale
        return SurfaceQueryPoint(
            x: (x - rect.x) / scale,
            y: (y - rect.y) / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

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
        presentation: SurfacePresentation? = nil,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> [ElementHandle] {
        var path: [ElementHandle] = []
        hitPath(x: x, y: y, presentation: presentation, matching: predicate, clip: clip, into: &path)
        return path
    }

    public func hitPath(
        x: Float,
        y: Float,
        presentation: SurfacePresentation? = nil,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool,
        into path: inout [ElementHandle]
    ) {
        var slot = root
        var localX = x
        var localY = y
        while slot >= 0 {
            let local = enter(slot, x: localX, y: localY, presentation)
            guard !content[Int(slot)].decorative, local.inside, clip(handle(slot), local.x, local.y) else {
                break
            }
            if predicate(content[Int(slot)]) {
                path.append(handle(slot))
            }
            let shift = scrollShift(slot)
            localX = local.x + shift.x
            localY = local.y + shift.y
            var top: Int32 = -1
            var raised = false
            var child = firstChild[Int(slot)]
            while child >= 0 {
                if !content[Int(child)].decorative, enter(child, x: localX, y: localY, presentation).inside {
                    let lifted = presentation?.raises(handle(child)) == true
                    if top < 0 || lifted || !raised {
                        top = child
                        raised = lifted
                    }
                }
                child = nextSibling[Int(child)]
            }
            slot = top
        }
    }

    public func covers(
        x: Float,
        y: Float,
        presentation: SurfacePresentation? = nil,
        where predicate: (ElementHandle) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> Bool {
        root >= 0 && covers(root, x: x, y: y, presentation: presentation, where: predicate, clip: clip)
    }

    func covers(
        _ slot: Int32,
        x: Float,
        y: Float,
        presentation: SurfacePresentation? = nil,
        where predicate: (ElementHandle) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool
    ) -> Bool {
        let local = enter(slot, x: x, y: y, presentation)
        guard !local.hidden, !content[Int(slot)].decorative, clip(handle(slot), local.x, local.y) else { return false }
        if local.inside, predicate(handle(slot)) {
            return true
        }
        guard local.inside || (!content[Int(slot)].scrolls && presentation?.raises(handle(slot)) != true) else {
            return false
        }
        let shift = scrollShift(slot)
        var child = firstChild[Int(slot)]
        while child >= 0 {
            if covers(
                child,
                x: local.x + shift.x,
                y: local.y + shift.y,
                presentation: presentation,
                where: predicate,
                clip: clip
            ) {
                return true
            }
            child = nextSibling[Int(child)]
        }
        return false
    }

    public func hitTest(
        x: Float,
        y: Float,
        presentation: SurfacePresentation? = nil,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool = { _, _, _ in true }
    ) -> ElementHandle {
        root >= 0 ? hit(root, x: x, y: y, presentation: presentation, matching: predicate, clip: clip) : .none
    }

    func hit(
        _ slot: Int32,
        x: Float,
        y: Float,
        presentation: SurfacePresentation? = nil,
        matching predicate: (Content) -> Bool,
        clip: (ElementHandle, Float, Float) -> Bool
    ) -> ElementHandle {
        let local = enter(slot, x: x, y: y, presentation)
        guard !content[Int(slot)].decorative, local.inside, clip(handle(slot), local.x, local.y) else {
            return .none
        }
        let shift = scrollShift(slot)
        let localX = local.x + shift.x
        let localY = local.y + shift.y
        var found = ElementHandle.none
        var raised = false
        var child = firstChild[Int(slot)]
        while child >= 0 {
            let lifted = presentation?.raises(handle(child)) == true
            if lifted || !raised {
                let candidate = hit(
                    child,
                    x: localX,
                    y: localY,
                    presentation: presentation,
                    matching: predicate,
                    clip: clip
                )
                if candidate.slot >= 0 {
                    found = candidate
                    raised = lifted
                }
            }
            child = nextSibling[Int(child)]
        }
        if found.slot < 0, predicate(content[Int(slot)]) {
            return handle(slot)
        }
        return found
    }
}
