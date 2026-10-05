// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class TabRailIconTests: XCTestCase {
    func testIconClickHoverAndAccessibilityAgreeAcrossCountsAndSelections() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let visibleFrame = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        var selected: Int?
        manager.onSelect = { _, index, _ in selected = index }
        for count in [2, 5, 6, 10] {
            for active in [0, count / 2, count - 1] {
                let info = makeInfo(
                    count: count, active: active, height: visibleFrame.height, origin: visibleFrame.origin
                )
                manager.updateRails([info], style: .appIcons)
                let (window, view, icons) = try views(manager, info)
                XCTAssertEqual(window.frame.width, 28)
                XCTAssertEqual(window.frame.minX, info.tileFrame.minX)
                XCTAssertEqual(icons.rows.count, count)
                for (index, row) in icons.rows.enumerated() where index != active {
                    XCTAssertEqual(row.selectionLayer.fillColor?.alpha, 0)
                }
                for scale: CGFloat in [1, 2] {
                    icons.layer?.contentsScale = scale
                    icons.viewDidChangeBackingProperties()
                    let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
                    for item in icons.railLayout(in: view).items {
                        XCTAssertEqual(item.pillRect.size, CGSize(width: 20, height: 20))
                        XCTAssertEqual(item.hitRect.size, CGSize(width: 28, height: 28))
                        XCTAssertEqual(item.pillRect.minX * scale, (item.pillRect.minX * scale).rounded())
                        let center = CGPoint(x: item.pillRect.midX, y: item.pillRect.midY)
                        XCTAssertEqual(view.item(at: center)?.visualIndex, item.visualIndex)
                        selected = nil
                        let hitView = try XCTUnwrap(view.hitTest(center))
                        hitView.mouseDown(with: try event(.leftMouseDown, at: center, in: window))
                        XCTAssertEqual(selected, item.visualIndex)
                        view.mouseMoved(with: try event(.mouseMoved, at: center, in: window))
                        XCTAssertTrue(window.hoverCard.isVisible)
                        XCTAssertEqual(
                            children[item.visualIndex].accessibilityFrame(),
                            window.convertToScreen(item.hitRect)
                        )
                    }
                }
            }
        }
    }

    func testNativeScrollPreservesOffsetAndRevealsAccessibilitySelection() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let info = makeInfo(count: 10, height: 56)
        manager.updateRails([info], style: .appIcons)
        let (window, view, icons) = try views(manager, info)
        let clip = icons.scrollView.contentView
        try showHover(window, view, icons)
        clip.scroll(to: CGPoint(x: 0, y: 84))
        XCTAssertEqual(clip.bounds.minY, 84)
        XCTAssertFalse(window.hoverCard.isVisible)
        manager.updateRails([info], style: .appIcons)
        XCTAssertEqual(clip.bounds.minY, 84)
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children.count, 10)
        XCTAssertEqual(children[0].accessibilityFrame(), .zero)
        XCTAssertEqual(view.item(at: CGPoint(x: 14, y: 42))?.visualIndex, 3)
        try showHover(window, view, icons)
        children[9].setAccessibilityFocused(true)
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertEqual(clip.bounds.minY, 224)
        XCTAssertFalse(children[9].accessibilityFrame().isEmpty)
        var selected: Int?
        manager.onSelect = { _, index, _ in selected = index }
        XCTAssertTrue(children[0].accessibilityPerformPress())
        XCTAssertEqual(selected, 0)
        XCTAssertEqual(clip.bounds.minY, 0)
        manager.updateRails([makeInfo(count: 10, active: 5, height: 56, key: info.key)], style: .appIcons)
        XCTAssertEqual(clip.bounds.minY, 112)
        XCTAssertTrue(icons.railLayout(in: view).items[5].hitRect.height == 28)
    }

    func testIconRowsAndAccessibilitySurviveGeometryOnlyMovement() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let info = makeInfo(count: 5, height: 84)
        manager.updateRails([info], style: .appIcons)
        let (window, view, icons) = try views(manager, info)
        let rows = icons.rows.map(ObjectIdentifier.init)
        let images = icons.rows.map { $0.imageView.image }
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        let frames = children.map { $0.accessibilityFrame() }
        try showHover(window, view, icons)
        let moved = info.tileFrame.offsetBy(dx: 40, dy: 20)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: moved, visibleTileFrame: moved)])
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertEqual(icons.rows.map(ObjectIdentifier.init), rows)
        XCTAssertEqual(children.map { $0.accessibilityFrame() }, frames)
        XCTAssertTrue(zip(images, icons.rows).allSatisfy { $0 === $1.imageView.image })
        XCTAssertEqual(
            (view.accessibilityChildren() as? [NSAccessibilityElement])?.map(ObjectIdentifier.init),
            children.map(ObjectIdentifier.init)
        )
        manager.updateRails([makeInfo(count: 5, height: 84, key: info.key, origin: moved.origin)], style: .appIcons)
        XCTAssertNotEqual(children.map { $0.accessibilityFrame() }, frames)
        XCTAssertEqual(icons.rows.map(ObjectIdentifier.init), rows)
    }

    func testWheelInputScrollsOnlyTheRailAndClampsAtItsEnds() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let info = makeInfo(count: 10, height: 56)
        manager.updateRails([info], style: .appIcons)
        let (window, view, icons) = try views(manager, info)
        var selections = 0
        manager.onSelect = { _, _, _ in selections += 1 }
        window.displayIfNeeded()
        icons.scrollView.layoutSubtreeIfNeeded()
        try showHover(window, view, icons)
        func scroll(_ delta: Int32) throws {
            let cgEvent = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
            ))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cgEvent.setIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                value: Int64(window.windowNumber)
            )
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            view.scrollWheel(with: event)
        }
        try scroll(-3)
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertGreaterThan(icons.scrollView.contentView.bounds.minY, 0)
        try scroll(-10000)
        XCTAssertEqual(icons.scrollView.contentView.bounds.minY, 224)
        try scroll(10000)
        XCTAssertEqual(icons.scrollView.contentView.bounds.minY, 0)
        XCTAssertEqual(selections, 0)
    }

    func testResizeMembershipAndStyleChangesClampScrollAndDismissHover() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let info = makeInfo(count: 10, active: 9, height: 56)
        manager.updateRails([info], style: .appIcons)
        let (window, view, icons) = try views(manager, info)
        XCTAssertEqual(icons.scrollView.contentView.bounds.minY, 224)
        try showHover(window, view, icons)
        let resized = CGRect(origin: info.tileFrame.origin, size: CGSize(width: 400, height: 112))
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resized, visibleTileFrame: resized)])
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertEqual(icons.scrollView.contentView.bounds.minY, 168)
        try showHover(window, view, icons)
        let fewer = makeInfo(count: 2, height: 112, key: info.key)
        manager.updateRails([fewer], style: .appIcons)
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertEqual(icons.scrollView.contentView.bounds.minY, 0)
        XCTAssertEqual(icons.rows.count, 2)
        try showHover(window, view, icons)
        manager.updateRails([fewer])
        XCTAssertFalse(window.hoverCard.isVisible)
        XCTAssertEqual(window.frame.width, 22)
        XCTAssertFalse(view.subviews.contains { $0 is TabRailIconView })
        manager.updateRails([fewer], style: .appIcons)
        let (_, _, restoredIcons) = try views(manager, fewer)
        try showHover(window, view, restoredIcons)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resized, visibleTileFrame: .null)])
        XCTAssertFalse(window.hoverCard.isVisible)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resized, visibleTileFrame: resized)])
        try showHover(window, view, restoredIcons)
        window.close()
        XCTAssertFalse(window.hoverCard.isVisible)
    }

    func testPartialMetadataHasFallbackIconsAndClosedRailsDismissHover() throws {
        let manager = TabRailManager()
        defer { manager.removeAll() }
        let info = TabRailInfo(
            workspaceId: UUID(), owner: .dwindleTile(UUID()), plannedSeq: 1,
            tileFrame: CGRect(x: 200, y: 200, width: 400, height: 100),
            tabCount: 5, activeVisualIndex: 2, activeWindowId: nil,
            tabs: [.init(visualIndex: 2, token: nil, windowId: nil, appName: "Example", title: "Title", isActive: true)]
        )
        manager.updateRails([info], style: .appIcons)
        let (window, view, icons) = try views(manager, info)
        XCTAssertEqual(icons.rows.count, 5)
        XCTAssertTrue(icons.rows.allSatisfy { $0.imageView.image != nil })
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(children[2].accessibilityLabel(), "Tab 3, Title, Example")
        XCTAssertEqual(children[0].accessibilityLabel(), "Tab 1")
        try showHover(window, view, icons)
        manager.updateRails([], style: .appIcons)
        XCTAssertFalse(window.hoverCard.isVisible)
    }

    func testIconSelectionAnimationUsesSharedMotionPolicy() throws {
        let policy = MotionPolicy(animationsEnabled: true)
        let manager = TabRailManager(motionPolicy: policy)
        defer { manager.removeAll() }
        let info = makeInfo(count: 2)
        manager.updateRails([info], style: .appIcons)
        let (_, _, icons) = try views(manager, info)
        manager.updateRails([makeInfo(count: 2, active: 1, key: info.key)], style: .appIcons)
        XCTAssertTrue(icons.rows.allSatisfy { $0.selectionLayer.animation(forKey: "selection.color") != nil })
        manager.updateRails([makeInfo(count: 2, active: 1, key: info.key)], style: .appIcons)
        XCTAssertTrue(icons.rows.allSatisfy { $0.selectionLayer.animation(forKey: "selection.color") != nil })
        policy.userAnimationsEnabled = false
        manager.updateRails([info], style: .appIcons)
        XCTAssertTrue(icons.rows.allSatisfy { $0.selectionLayer.animationKeys()?.isEmpty != false })
        policy.userAnimationsEnabled = true
        policy.systemReducesMotion = true
        manager.updateRails([makeInfo(count: 2, active: 1, key: info.key)], style: .appIcons)
        XCTAssertTrue(icons.rows.allSatisfy { $0.selectionLayer.animationKeys()?.isEmpty != false })
        XCTAssertNotNil(icons.rows[1].selectionLayer.strokeColor)
        XCTAssertNil(icons.rows[0].selectionLayer.strokeColor)
    }

    private func makeInfo(
        count: Int, active: Int = 0, height: CGFloat = 800, key: TabRailKey? = nil,
        origin: CGPoint = CGPoint(x: 300, y: 300)
    ) -> TabRailInfo {
        TabRailInfo(
            workspaceId: key?.workspaceId ?? UUID(), owner: key?.owner ?? .niriColumn(NodeId()), plannedSeq: 1,
            tileFrame: CGRect(origin: origin, size: CGSize(width: 400, height: height)),
            tabCount: count, activeVisualIndex: active, activeWindowId: nil,
            tabs: (0 ..< count).map { index in
                TabRailTabInfo(
                    visualIndex: index, token: WindowToken(pid: getpid(), windowId: index), windowId: nil,
                    appName: "Same app", title: "Window \(index)", isActive: index == active
                )
            }
        )
    }

    private func views(
        _ manager: TabRailManager,
        _ info: TabRailInfo
    ) throws -> (TabRailWindow, TabRailView, TabRailIconView) {
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let icons = try XCTUnwrap(view.subviews.first { $0 is TabRailIconView } as? TabRailIconView)
        return (window, view, icons)
    }

    private func showHover(_ window: TabRailWindow, _ view: TabRailView, _ icons: TabRailIconView) throws {
        let item = try XCTUnwrap(icons.railLayout(in: view).items.first { !$0.hitRect.isEmpty })
        let point = CGPoint(x: item.hitRect.midX, y: item.hitRect.midY)
        view.mouseMoved(with: try event(.mouseMoved, at: point, in: window))
        XCTAssertTrue(window.hoverCard.isVisible)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
    }
}
