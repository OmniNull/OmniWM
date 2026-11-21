// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMShellCore

extension ShellWidgetSurface {
    var hasMarquee: Bool {
        layout.hasMarquee
    }

    static let scrollFade: CGFloat = 24

    var followedItem: ElementHandle? {
        guard let followedTarget, let text, layout.rootScroll != nil else { return nil }
        return layout.core.elements(matching: { $0.target != 0 && text.string($0.target) == followedTarget }).first
    }

    func contentFrame(of item: ElementHandle) -> Rect {
        var frame = layout.core.layoutFrame(of: item)
        var parent = layout.core.parent(of: item)
        while layout.core.contains(parent) {
            let outer = layout.core.layoutFrame(of: parent)
            frame.x += outer.x
            frame.y += outer.y
            parent = layout.core.parent(of: parent)
        }
        return frame
    }

    func revealFollowedTarget() {
        let item = followedItem
        followedFrame = item.map(contentFrame)
        guard let item else { return }
        reveal(item, within: layout.core.rootHandle, margin: Float(Self.scrollFade))
    }

    var rootScroll: (offset: CGFloat, limit: CGFloat)? {
        let root = layout.core.rootHandle
        guard layout.rootScroll != nil else { return nil }
        return (CGFloat(layout.core.scrollOffset(of: root)), CGFloat(layout.core.scrollLimit(of: root)))
    }
}

extension ShellWidgetLayout {
    var hasMarquee: Bool {
        let root = core.rootHandle
        return core.contains(root) && (core.content(of: root).marquee
            || core.firstDescendant(of: root) { $0.marquee } != .none)
    }

    var rootScroll: Axis? {
        let root = core.rootHandle
        guard core.contains(root), core.content(of: root).scrolls else { return nil }
        return core.layoutStyle(of: root).axis
    }

    func scrolls(cutTo size: CGSize) -> Bool {
        rootScroll == .row && naturalSize.width - size.width >= 1
    }

    var parts: ShellWidgetParts {
        var parts = ShellWidgetParts(marquee: hasMarquee, scroll: rootScroll)
        let root = core.rootHandle
        guard core.contains(root) else { return parts }
        let paint = core.paint(of: root)
        let content = core.content(of: root)
        guard !paint.fill.isVisible, !paint.stroke.isVisible, paint.material == 0,
              content.action == 0, !content.opensPopout
        else { return parts }
        core.forEachChild(of: root) { child, _ in
            let frame = core.layoutFrame(of: child)
            parts.frames.append(CGRect(
                x: CGFloat(frame.x),
                y: CGFloat(frame.y),
                width: CGFloat(frame.width),
                height: CGFloat(frame.height)
            ))
        }
        return parts
    }
}

struct ShellWidgetParts: Equatable {
    var frames: [CGRect] = []
    var marquee = false
    var scroll: Axis?

    func stops(in size: CGSize, vertical: Bool, keepsEnd: Bool) -> [CGFloat]? {
        guard !vertical, scroll != .row, !marquee || keepsEnd else { return nil }
        let ranges = frames.map { $0.minX ... $0.maxX }
        return ranges.compactMap { range in
            let edge = keepsEnd ? range.lowerBound : range.upperBound
            guard !ranges.contains(where: { edge - $0.lowerBound > 0.5 && $0.upperBound - edge > 0.5 })
            else { return nil }
            let stop = keepsEnd ? size.width - edge : edge
            return stop > 0.5 && size.width - stop > 0.5 ? stop : nil
        }.sorted()
    }
}
