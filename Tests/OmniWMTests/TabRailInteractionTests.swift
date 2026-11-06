// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class TabRailInteractionTests: XCTestCase {
    func testPackedMarkerCentersRemainInsideTheirFullWidthHitRegions() {
        for count in [2, 5, 6, 10] {
            for activeIndex in [0, count / 2, count - 1] {
                for scale: CGFloat in [1, 2] {
                    let height = TabRailLayout.fittedHeight(tabCount: count, availableHeight: 800)
                    let layout = TabRailLayout(
                        tabCount: count,
                        bounds: CGRect(x: 0, y: 0, width: 22, height: height),
                        activeVisualIndex: activeIndex,
                        scale: scale
                    )
                    XCTAssertEqual(layout.items.count, count)
                    for item in layout.items {
                        let center = CGPoint(x: item.pillRect.midX, y: item.pillRect.midY)
                        XCTAssertTrue(
                            item.hitRect.contains(center),
                            "count=\(count), active=\(activeIndex), item=\(item.visualIndex)"
                        )
                        XCTAssertEqual(
                            layout.items.filter { $0.hitRect.contains(center) }.map(\.visualIndex),
                            [item.visualIndex]
                        )
                        XCTAssertEqual(item.hitRect.width, 22)
                        XCTAssertTrue(layout.railRect.contains(item.hitRect))
                    }
                }
            }
        }
    }

    func testClickHoverAndAccessibilityUsePackedMarkerGeometry() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        var selected: Int?
        manager.onSelect = { _, index, _ in selected = index }
        for count in [2, 5, 6, 10] {
            var info = makeInfo(count: count)
            manager.updateRails([info])
            let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
            let view = try XCTUnwrap(window.contentView as? TabRailView)
            for activeIndex in [0, count / 2, count - 1] {
                info = replacing(info, activeIndex: activeIndex)
                manager.updateRails([info])
                window.displayIfNeeded()
                CATransaction.flush()
                let layout = TabRailLayout(
                    tabCount: count, bounds: view.bounds,
                    activeVisualIndex: activeIndex, scale: window.backingScaleFactor
                )
                let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
                XCTAssertEqual(children.count, count)
                for item in layout.items {
                    let center = CGPoint(x: item.pillRect.midX, y: item.pillRect.midY)
                    selected = nil
                    view.mouseDown(with: try event(.leftMouseDown, at: center, in: window))
                    XCTAssertEqual(selected, item.visualIndex)
                    view.mouseMoved(with: try event(.mouseMoved, at: center, in: window))
                    XCTAssertTrue(window.hoverCard.isVisible)
                    let cardLabels = window.hoverCard.contentView?.subviews
                        .compactMap { ($0 as? NSTextField)?.stringValue } ?? []
                    XCTAssertTrue(cardLabels.contains("Window \(item.visualIndex + 1)"))
                    let expectedFrame = window.convertToScreen(view.convert(item.hitRect, to: nil))
                    XCTAssertEqual(children[item.visualIndex].accessibilityFrame(), expectedFrame)
                }
            }
        }
    }

    func testPointerSelectionUsesFrozenPresentationDuringInterruptedAnimation() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: true))
        defer { manager.removeAll() }
        let info = makeInfo(count: 6)
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let overlay = try overlay(in: view)
        window.displayIfNeeded()
        CATransaction.flush()
        for layer in overlay.segmentLayers.values {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
        manager.updateRails([replacing(info, activeIndex: 5)])
        CATransaction.flush()
        let layer = try XCTUnwrap(overlay.segmentLayers[1])
        XCTAssertNotNil(layer.animation(forKey: "selection.path"))
        let presentedPath = try XCTUnwrap(layer.presentation()?.path)
        let presentedRect = overlay.convert(presentedPath.boundingBoxOfPath, to: view)
        let point = CGPoint(x: presentedRect.midX, y: presentedRect.minY + 1)
        let target = TabRailLayout(
            tabCount: 6,
            bounds: view.bounds,
            activeVisualIndex: 5,
            scale: window.backingScaleFactor
        )
        XCTAssertEqual(target.items.first { $0.hitRect.contains(point) }?.visualIndex, 2)
        XCTAssertEqual(view.item(at: point)?.visualIndex, 1)
        var selected: Int?
        manager.onSelect = { _, index, _ in selected = index }
        view.mouseDown(with: try event(.leftMouseDown, at: point, in: window))
        XCTAssertEqual(selected, 1)

        manager.updateRails([replacing(info, activeIndex: 3)])
        CATransaction.flush()
        let interrupted = try XCTUnwrap(layer.animation(forKey: "selection.path") as? CABasicAnimation)
        let fromPath = try XCTUnwrap(interrupted.fromValue) as CFTypeRef
        XCTAssertTrue(CFEqual(fromPath, presentedPath))
        XCTAssertEqual(view.item(at: point)?.visualIndex, 1)
    }

    func testSelectionAnimationHonorsSharedMotionPolicy() throws {
        let policy = MotionPolicy(animationsEnabled: true)
        let manager = TabRailManager(motionPolicy: policy)
        defer { manager.removeAll() }
        let info = makeInfo(count: 2)
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key))
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let overlay = try overlay(in: view)
        manager.updateRails([replacing(info, activeIndex: 1)])
        XCTAssertTrue(overlay.segmentLayers.values.allSatisfy { $0.animation(forKey: "selection.path") != nil })

        policy.userAnimationsEnabled = false
        manager.updateRails([info])
        XCTAssertTrue(overlay.segmentLayers.values.allSatisfy { $0.animationKeys()?.isEmpty != false })

        policy.userAnimationsEnabled = true
        policy.systemReducesMotion = true
        manager.updateRails([replacing(info, activeIndex: 1)])
        XCTAssertTrue(overlay.segmentLayers.values.allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    func testHoverDismissesAcrossNormalAndAnimationGeometryChanges() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        var info = makeInfo(count: 2)
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        try showHover(in: window)
        info = replacing(info, tileFrame: info.tileFrame.offsetBy(dx: 30, dy: 20))
        manager.updateRails([info])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)
        let expected = TabRailHoverCardPlacement.frame(
            railFrame: window.frame,
            itemRect: try XCTUnwrap(view.item(at: CGPoint(x: 17, y: view.bounds.midY))).pillRect,
            cardSize: TabRailMetrics.hoverCardSize,
            visibleFrame: try XCTUnwrap(window.screen).visibleFrame,
            gap: TabRailMetrics.hoverCardGap
        )
        XCTAssertEqual(window.hoverCard.frame, expected)

        info = replacing(info, tileFrame: CGRect(x: 300, y: 300, width: 400, height: 40))
        manager.updateRails([info])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)
        let animatedFrame = info.tileFrame.offsetBy(dx: 45, dy: 10)
        manager.applyAnimationGeometry([.init(
            key: info.key,
            tileFrame: animatedFrame,
            visibleTileFrame: animatedFrame
        )])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)
        let resizedFrame = CGRect(x: 300, y: 300, width: 400, height: 60)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resizedFrame, visibleTileFrame: resizedFrame)])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)

        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resizedFrame, visibleTileFrame: .null)])
        XCTAssertFalse(window.isOrderedIn)
        XCTAssertFalse(window.hoverCard.isVisible)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: resizedFrame, visibleTileFrame: resizedFrame)])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)
        manager.updateRails([])
        XCTAssertFalse(window.hoverCard.isVisible)
    }

    func testHoverDismissesOnInvalidFullUpdateAndManagerRemoval() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let info = makeInfo(count: 2)
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        try showHover(in: window)
        manager.updateRails([replacing(info, visibleTileFrame: .null)])
        XCTAssertFalse(window.hoverCard.isVisible)
        manager.updateRails([info])
        XCTAssertFalse(window.hoverCard.isVisible)
        try showHover(in: window)
        manager.removeAll()
        XCTAssertFalse(window.hoverCard.isVisible)
    }

    func testSettledUpdatesAfterAnimationMoveInWindowServerAndKeepGeometryReadersCurrent() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let tileFrame = CGRect(x: visibleFrame.minX + 100, y: visibleFrame.minY + 100, width: 400, height: 300)
        var info = replacing(makeInfo(count: 2), tileFrame: tileFrame)
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let realizedFrame = window.frame
        XCTAssertEqual(window.appliedFrame, realizedFrame)

        let animatedTile = tileFrame.offsetBy(dx: 45, dy: 10)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: animatedTile, visibleTileFrame: animatedTile)])
        info = replacing(info, tileFrame: animatedTile)
        manager.updateRails([info])
        XCTAssertEqual(window.frame, realizedFrame)
        try assertRailGeometry(window, view, info, railFrame: realizedFrame.offsetBy(dx: 45, dy: 10))

        let settledTile = animatedTile.offsetBy(dx: -20, dy: 30)
        info = replacing(info, tileFrame: settledTile)
        manager.updateRails([info])
        let settledFrame = realizedFrame.offsetBy(dx: 25, dy: 40)
        XCTAssertEqual(window.frame, realizedFrame)
        try assertRailGeometry(window, view, info, railFrame: settledFrame)

        try showHover(in: window)
        manager.updateRails([info])
        XCTAssertTrue(window.hoverCard.isVisible)
        let expectedCard = TabRailHoverCardPlacement.frame(
            railFrame: settledFrame,
            itemRect: try XCTUnwrap(view.item(at: CGPoint(x: 17, y: view.bounds.midY))).pillRect,
            cardSize: TabRailMetrics.hoverCardSize,
            visibleFrame: try XCTUnwrap(window.screen).visibleFrame,
            gap: TabRailMetrics.hoverCardGap
        )
        XCTAssertEqual(window.hoverCard.frame, expectedCard)

        info = replacing(info, tileFrame: CGRect(origin: settledTile.origin, size: CGSize(width: 400, height: 40)))
        manager.updateRails([info])
        XCTAssertNotEqual(window.frame.size, realizedFrame.size)
        XCTAssertEqual(window.frame.minX, settledFrame.minX)
        try assertRailGeometry(window, view, info, railFrame: window.frame)
    }

    private func assertRailGeometry(
        _ window: TabRailWindow, _ view: TabRailView, _ info: TabRailInfo, railFrame: CGRect
    ) throws {
        XCTAssertEqual(window.appliedFrame, railFrame)
        let surface = SurfaceCoordinator.shared.visibleSurfaceInfos().first {
            $0.kind == .tabRail && $0.id.contains(info.workspaceId.uuidString)
        }
        XCTAssertEqual(surface?.frame, railFrame)
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        let layout = TabRailLayout(
            tabCount: info.tabCount, bounds: view.bounds,
            activeVisualIndex: info.activeVisualIndex, scale: window.backingScaleFactor
        )
        XCTAssertEqual(children.count, layout.items.count)
        for (child, item) in zip(children, layout.items) {
            XCTAssertEqual(child.accessibilityFrame(), item.hitRect.offsetBy(dx: railFrame.minX, dy: railFrame.minY))
        }
    }

    private func showHover(in window: TabRailWindow) throws {
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 17, y: view.bounds.midY), in: window))
        XCTAssertTrue(window.hoverCard.isVisible)
    }

    private func overlay(in view: TabRailView) throws -> TabRailTrackOverlayView {
        let track = try XCTUnwrap(view.subviews.first as? TabRailTrackView)
        return try XCTUnwrap(track.subviews.first as? TabRailTrackOverlayView)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
    }

    private func makeInfo(count: Int) -> TabRailInfo {
        let info = TabRailInfo(
            workspaceId: WorkspaceDescriptor.ID(), owner: .niriColumn(NodeId()), plannedSeq: 1,
            tileFrame: CGRect(x: 300, y: 300, width: 400, height: 800),
            tabCount: count, activeVisualIndex: 0, activeWindowId: nil
        )
        return replacing(info, activeIndex: 0)
    }

    private func replacing(
        _ info: TabRailInfo, activeIndex: Int? = nil, tileFrame: CGRect? = nil, visibleTileFrame: CGRect? = nil
    ) -> TabRailInfo {
        let active = activeIndex ?? info.activeVisualIndex
        return TabRailInfo(
            workspaceId: info.workspaceId, owner: info.owner, plannedSeq: info.plannedSeq,
            tileFrame: tileFrame ?? info.tileFrame,
            visibleTileFrame: visibleTileFrame ?? tileFrame ?? info.visibleTileFrame,
            tabCount: info.tabCount, activeVisualIndex: active, activeWindowId: nil,
            tabs: (0 ..< info.tabCount).map { index in
                TabRailTabInfo(
                    visualIndex: index, token: nil, windowId: nil, appName: "Example",
                    title: "Window \(index + 1)", isActive: index == active
                )
            }
        )
    }
}
