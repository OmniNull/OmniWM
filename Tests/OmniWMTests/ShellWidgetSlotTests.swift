// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class ShellWidgetSlotTests: XCTestCase {
    func testSlotHostsTheReplacementSurfaceView() {
        let widget = WorkspaceBarShellWidget(id: "clock", size: CGSize(width: 40, height: 20), lane: .trailing)
        let first = NSView()
        let replacement = NSView()
        let host = NSHostingView(rootView: ShellWidgetSlot(widget: widget, view: first))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 24)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.isDescendant(of: host))

        host.rootView = ShellWidgetSlot(widget: widget, view: replacement)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(replacement.isDescendant(of: host))
        XCTAssertFalse(first.isDescendant(of: host))
    }

    func testACutSlotClipsItsWidgetAndKeepsTheStartOrEndOfItsLane() throws {
        let size = CGSize(width: 40, height: 20)
        let visible = size.width / 2
        for lane in [ShellLane.leading, .center, .trailing] {
            let view = NSView()
            let host = NSHostingView(rootView: ShellWidgetSlot(
                widget: WorkspaceBarShellWidget(id: "clock", size: size, lane: lane),
                view: view,
                cuttable: true
            ).frame(width: visible, height: size.height))
            host.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
            host.layoutSubtreeIfNeeded()
            let clip = try XCTUnwrap(view.superview as? ShellWidgetClipView)
            XCTAssertEqual(clip.frame.size, CGSize(width: visible, height: size.height), "\(lane)")
            XCTAssertTrue(clip.clipsToBounds, "\(lane)")
            XCTAssertEqual(
                view.frame,
                CGRect(origin: CGPoint(x: lane == .trailing ? visible - size.width : 0, y: 0), size: size),
                "\(lane)"
            )
        }
    }

    func testASlotOutsideTheLaneLayoutKeepsItsWidthUnderANarrowProposal() throws {
        let size = CGSize(width: 40, height: 20)
        let view = NSView()
        let host = NSHostingView(rootView: ShellWidgetSlot(
            widget: WorkspaceBarShellWidget(id: "clock", size: size, lane: .leading),
            view: view
        ).frame(width: size.width / 2, height: size.height))
        host.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
        host.layoutSubtreeIfNeeded()
        let clip = try XCTUnwrap(view.superview as? ShellWidgetClipView)
        XCTAssertEqual(clip.frame.size, size)
        XCTAssertFalse(clip.clipsToBounds)
    }

    func testAFailingSlotClipsItsBadgeWithItsWidgetAndHidesBothWithoutRoom() throws {
        let size = CGSize(width: 40, height: 20)
        let failure = ShellWidgetFailure(message: "boom", source: URL(fileURLWithPath: "/tmp/clock/init.luau"))
        var hosts: [NSView] = []
        func place(lane: ShellLane, width: CGFloat?) throws -> (clip: ShellWidgetClipView, view: NSView) {
            let view = NSView()
            let slot = ShellWidgetSlot(
                widget: WorkspaceBarShellWidget(id: "clock", size: size, lane: lane, failure: failure),
                view: view,
                cuttable: true
            )
            let host: NSView = if let width {
                NSHostingView(rootView: slot.frame(width: width, height: size.height))
            } else {
                NSHostingView(rootView: slot)
            }
            host.frame = CGRect(x: 0, y: 0, width: size.width * 4, height: size.height)
            host.layoutSubtreeIfNeeded()
            hosts.append(host)
            return (try XCTUnwrap(view.superview as? ShellWidgetClipView), view)
        }

        let whole = try place(lane: .leading, width: nil)
        let badge = try XCTUnwrap(whole.clip.badgeView)
        let mark = badge.fittingSize
        let natural = mark.width + ShellWidgetClipView.badgeGap + size.width
        XCTAssertEqual(badge.frame.size, mark)
        XCTAssertEqual(whole.clip.frame.width, natural)
        XCTAssertFalse(whole.clip.clipsToBounds)
        XCTAssertEqual(badge.frame.minX, 0)
        XCTAssertEqual(whole.view.frame.minX, mark.width + ShellWidgetClipView.badgeGap)

        let partial = natural - size.width / 2
        let start = try place(lane: .leading, width: partial)
        XCTAssertEqual(start.clip.frame.width, partial)
        XCTAssertTrue(start.clip.clipsToBounds)
        XCTAssertEqual(try XCTUnwrap(start.clip.badgeView).frame.minX, 0)
        XCTAssertEqual(start.view.frame.minX, mark.width + ShellWidgetClipView.badgeGap)

        let end = try place(lane: .trailing, width: partial)
        XCTAssertTrue(end.clip.clipsToBounds)
        XCTAssertEqual(try XCTUnwrap(end.clip.badgeView).frame.minX, partial - natural)
        XCTAssertEqual(end.view.frame.maxX, partial)

        let none = try place(lane: .leading, width: 0)
        XCTAssertEqual(none.clip.frame.width, 0)
        XCTAssertTrue(none.clip.clipsToBounds)
        let container = try XCTUnwrap(none.clip.superview)
        for x in [mark.width / 2, mark.width + ShellWidgetClipView.badgeGap + size.width / 2] {
            XCTAssertNil(none.clip.hitTest(container.convert(CGPoint(x: x, y: size.height / 2), from: none.clip)))
        }
        withExtendedLifetime(hosts) {}
    }

    func testACutSlotTellsItsSurfaceWhichPartIsVisible() throws {
        let widget = try ShellRenderedWidget(
            name: "wide",
            source: "function render(ctx) return ui.box{ w = 40, h = 20 } end"
        )
        widget.render(ShellBarData())
        let size = widget.surface.size
        var hosts: [NSView] = []
        func place(_ lane: ShellLane, width: CGFloat?) {
            let slot = ShellWidgetSlot(
                widget: WorkspaceBarShellWidget(id: "wide", size: size, lane: lane),
                view: widget.surface.view,
                cuttable: true
            )
            let host: NSView = if let width {
                NSHostingView(rootView: slot.frame(width: width, height: size.height))
            } else {
                NSHostingView(rootView: slot)
            }
            host.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
            host.layoutSubtreeIfNeeded()
            hosts.append(host)
        }
        let shown = size.width / 2
        place(.leading, width: shown)
        XCTAssertEqual(widget.surface.visibleBounds, CGRect(x: 0, y: 0, width: shown, height: size.height))
        place(.trailing, width: shown)
        XCTAssertEqual(
            widget.surface.visibleBounds,
            CGRect(x: size.width - shown, y: 0, width: shown, height: size.height)
        )
        place(.leading, width: nil)
        XCTAssertNil(widget.surface.visibleBounds)
        withExtendedLifetime(hosts) {}
    }

    func testAnUncutSlotLeavesItsWidgetUnclippedAndFollowsItsHostsMoves() throws {
        let size = CGSize(width: 40, height: 20)
        let view = NSView()
        let host = NSHostingView(rootView: ShellWidgetSlot(
            widget: WorkspaceBarShellWidget(id: "clock", size: size, lane: .trailing),
            view: view
        ))
        host.frame = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height)
        host.layoutSubtreeIfNeeded()
        let clip = try XCTUnwrap(view.superview as? ShellWidgetClipView)
        XCTAssertFalse(clip.clipsToBounds)
        XCTAssertEqual(view.frame, CGRect(origin: .zero, size: size))

        let moves = MoveCounter()
        NotificationCenter.default.addObserver(
            moves,
            selector: #selector(MoveCounter.moved),
            name: NSView.frameDidChangeNotification,
            object: clip
        )
        defer { NotificationCenter.default.removeObserver(moves) }
        let container = try XCTUnwrap(clip.superview)
        container.setFrameOrigin(CGPoint(x: container.frame.minX + size.width, y: container.frame.minY))
        XCTAssertEqual(moves.count, 1)
    }
}

@MainActor
private final class MoveCounter: NSObject {
    var count = 0

    @objc func moved() {
        count += 1
    }
}
