// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct ShellEdgeHover {
    enum Action: Equatable {
        case open(drawer: String, monitor: Monitor.ID)
        case close
    }

    struct Open {
        let drawer: ShellDrawerConfig
        let region: CGRect?
    }

    private var armed = true
    private var held: (drawer: String, entered: Bool)?

    mutating func update(
        pointer: CGPoint,
        drawers: [ShellDrawerConfig],
        monitors: [Monitor],
        buttonsDown: Bool,
        open: Open?
    ) -> Action? {
        let frames = monitors.map(\.frame)
        if let open, open.drawer.closesOnLeave {
            guard let region = open.region else { return nil }
            let inside = region.contains(pointer) || open.drawer.hover && monitors.contains {
                $0.frame.insetBy(dx: -1, dy: -1).contains(pointer) && Self.touches(
                    pointer,
                    open.drawer,
                    $0.frame,
                    frames
                )
            }
            if held?.drawer != open.drawer.id {
                held = (open.drawer.id, inside)
            } else if inside {
                held?.entered = true
            }
            guard !inside, !buttonsDown, held?.entered == true else { return nil }
            held = nil
            armed = false
            return .close
        }
        if open == nil {
            held = nil
        }
        guard let monitor = monitors.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(pointer) }),
              let drawer = drawers.first(where: { $0.hover && Self.touches(pointer, $0, monitor.frame, frames) })
        else {
            armed = true
            return nil
        }
        guard armed else { return nil }
        armed = false
        guard !buttonsDown, open?.drawer.id != drawer.id else { return nil }
        held = (drawer.id, true)
        return .open(drawer: drawer.id, monitor: monitor.id)
    }

    static func touches(
        _ pointer: CGPoint,
        _ drawer: ShellDrawerConfig,
        _ frame: CGRect,
        _ frames: [CGRect]
    ) -> Bool {
        let reach = drawer.reach
        let beyond: CGPoint
        let along: (position: CGFloat, middle: CGFloat)
        switch drawer.edge {
        case .left:
            guard pointer.x <= frame.minX + reach else { return false }
            beyond = CGPoint(x: frame.minX - 2, y: pointer.y)
            along = (pointer.y, frame.midY)
        case .right:
            guard pointer.x >= frame.maxX - reach else { return false }
            beyond = CGPoint(x: frame.maxX + 2, y: pointer.y)
            along = (pointer.y, frame.midY)
        case .top:
            guard pointer.y >= frame.maxY - reach else { return false }
            beyond = CGPoint(x: pointer.x, y: frame.maxY + 2)
            along = (pointer.x, frame.midX)
        case .bottom:
            guard pointer.y <= frame.minY + reach else { return false }
            beyond = CGPoint(x: pointer.x, y: frame.minY - 2)
            along = (pointer.x, frame.midX)
        }
        if let width = drawer.width, abs(along.position - along.middle) > width / 2 {
            return false
        }
        return !frames.contains { $0.contains(beyond) }
    }
}
