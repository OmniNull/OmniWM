// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

final class OverviewStructuralMotionTests: XCTestCase {
    @MainActor
    func testStructuralUpdateAnimatesFromDisplayedGeometryAndCommitsDestination() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let start = card.root.position
        let destination = fixture.layout(x: 330, width: 250)

        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .structural)

        let animation = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((animation.fromValue as? NSValue)?.pointValue, start)
        XCTAssertEqual(card.root.frame, destination.window(for: fixture.handle)?.overviewFrame)
        XCTAssertEqual(animation.damping, 2 * sqrt(animation.stiffness * animation.mass))
        XCTAssertTrue(fixture.renderer.isReflowing)
        XCTAssertNil(fixture.renderer.activeTransition)
    }

    @MainActor
    func testRetargetBeforeFirstCompositorCommitRetainsInitialDisplayedPosition() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let start = card.root.position
        fixture.renderer.updateLayout(
            fixture.layout(x: 330),
            state: fixture.state,
            caretAnimated: false,
            update: .structural
        )
        fixture.renderer.updateLayout(
            fixture.layout(x: 460),
            state: fixture.state,
            caretAnimated: false,
            update: .structural
        )

        let animation = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((animation.fromValue as? NSValue)?.pointValue, start)
        XCTAssertEqual((animation.toValue as? NSValue)?.pointValue, card.root.position)
        XCTAssertTrue(card.root.position.x.isFinite)
    }

    @MainActor
    func testPreservedLayoutHoverAndPreviewDoNotRestartCardMotion() throws {
        let fixture = Fixture()
        let layout = fixture.layout(x: 330, width: 250)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let before = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false)
        fixture.renderer.updatePresentation(layout, state: fixture.state)
        fixture.renderer.updateHover(from: nil, layout: layout, state: fixture.state)
        fixture.renderer.updatePreview(try makeOverviewPreviewFrame(), for: fixture.handle)

        let after = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual(after.beginTime, before.beginTime)
        XCTAssertEqual(after.duration, before.duration)
        XCTAssertEqual((after.fromValue as? NSValue)?.pointValue, (before.fromValue as? NSValue)?.pointValue)
        XCTAssertTrue(fixture.renderer.isReflowing)
    }

    @MainActor
    func testImmediateUpdateAndReduceMotionCancelStructuralMotion() throws {
        for reduceMotion in [false, true] {
            let fixture = Fixture()
            let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
            let layout = fixture.layout(x: 330)
            fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
            fixture.renderer.updateLayout(
                layout,
                state: fixture.state,
                caretAnimated: false,
                update: reduceMotion ? .preserve : .immediate,
                animationsEnabled: !reduceMotion
            )
            fixture.renderer.updatePresentation(layout, state: fixture.state)

            XCTAssertFalse(fixture.renderer.isReflowing)
            XCTAssertNil(card.root.animation(forKey: "overview.position"))
            XCTAssertEqual(card.root.frame, layout.window(for: fixture.handle)?.overviewFrame)
        }
    }

    @MainActor
    func testIncomingCardFadesAtDestinationWithoutFlyingAcrossDisplays() throws {
        let fixture = Fixture()
        let handle = WindowHandle(id: WindowToken(pid: 2, windowId: 2))
        let layout = fixture.layout(x: 330, handle: handle)
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[handle])
        let fade = try XCTUnwrap(card.root.animation(forKey: "overview.opacity") as? CASpringAnimation)

        XCTAssertEqual((fade.fromValue as? NSNumber)?.floatValue, 0)
        XCTAssertEqual((fade.toValue as? NSNumber)?.floatValue, 1)
        XCTAssertNil(card.root.animation(forKey: "overview.position"))
        XCTAssertNil(card.root.animation(forKey: "overview.bounds"))
        XCTAssertEqual(card.root.frame, layout.window(for: handle)?.overviewFrame)
        XCTAssertNil(fixture.renderer.windowLayers[fixture.handle])
    }

    @MainActor
    func testReflowMaskAndHitTargetsRemainClippedToStationaryRibbon() throws {
        let fixture = Fixture()
        let layout = fixture.layout(x: 430, width: 230)
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let mask = try XCTUnwrap(card.root.mask)
        let displayed = OverviewLayerMotion.displayedFrame(of: mask).offsetBy(
            dx: card.displayedFrame.minX,
            dy: card.displayedFrame.minY
        )

        XCTAssertEqual(displayed, fixture.ribbon)
        XCTAssertEqual(mask.frame.offsetBy(dx: card.root.frame.minX, dy: card.root.frame.minY), fixture.ribbon)
        XCTAssertEqual(
            fixture.renderer.windowHit(at: CGPoint(x: 150, y: 150), layout: layout)?.window.handle,
            fixture.handle
        )
        XCTAssertNil(fixture.renderer.windowHit(at: CGPoint(x: 80, y: 150), layout: layout))
        XCTAssertNil(fixture.renderer.windowHit(at: CGPoint(x: 600, y: 150), layout: layout))
    }

    @MainActor
    func testTabControlMovesAndHitsWithItsClippedCard() throws {
        let fixture = Fixture()
        var initial = fixture.layout(x: 70, tabbed: true)
        initial.scrollOffset = 40
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let oldControl = try XCTUnwrap(initial.tabControls(for: initial.workspaceSections[0]).first)
        let controlLayer = try XCTUnwrap(fixture.renderer.tabControlLayers[fixture.handle])
        let displayedFrame = oldControl.frame.offsetBy(dx: 0, dy: -initial.scrollOffset)
        let point = CGPoint(x: displayedFrame.midX, y: displayedFrame.midY)
        var destination = fixture.layout(x: 330, tabbed: true)
        destination.scrollOffset = 140
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .structural)

        XCTAssertTrue(fixture.renderer.tabControlLayers[fixture.handle] === controlLayer)
        let hit = try XCTUnwrap(fixture.renderer.tabControl(at: point, layout: destination))
        XCTAssertEqual(hit.frame, displayedFrame)
        XCTAssertTrue(hit.handle === fixture.handle)
        XCTAssertNil(fixture.renderer.tabControl(at: CGPoint(x: 400, y: point.y), layout: destination))
        let frozen = fixture.renderer.freezingReflow(in: destination)
        fixture.renderer.cancelAnimation()
        fixture.renderer.updatePresentation(frozen, state: fixture.state)
        XCTAssertEqual(fixture.renderer.tabControl(at: point, layout: frozen)?.frame, displayedFrame)
    }

    @MainActor
    func testRenderedChevronsKeepTheirHitTargetsWhileControlResizesAndFreezes() throws {
        for shrinking in [true, false] {
            let fixture = Fixture()
            var initial = fixture.layout(x: shrinking ? 330 : 400, tabbed: true)
            initial.scrollOffset = 40
            fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
            fixture.renderer.updatePresentation(initial, state: fixture.state)
            let expected = try XCTUnwrap(initial.tabControls(for: initial.workspaceSections[0]).first)
            var destination = fixture.layout(x: shrinking ? 400 : 330, tabbed: true)
            destination.scrollOffset = 60
            fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .structural)
            let control = try XCTUnwrap(fixture.renderer.tabControlLayers[fixture.handle])
            let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
            for _ in 0 ..< 2 {
                for symbol in ["‹", "›"] {
                    let text = try XCTUnwrap(control.sublayers?.compactMap { $0 as? CATextLayer }
                        .first { $0.string as? String == symbol })
                    let glyph = OverviewLayerMotion.displayedFrame(of: text)
                    let frame = OverviewLayerMotion.displayedFrame(of: control)
                    let content = OverviewLayerMotion.displayedFrame(of: fixture.renderer.content)
                    let point = CGPoint(
                        x: content.minX + card.displayedFrame.minX + frame.minX + glyph.midX,
                        y: content.minY + card.displayedFrame.minY + frame.minY + glyph.midY
                    )
                    let hit = try XCTUnwrap(fixture.renderer.tabControl(at: point, layout: destination))
                    XCTAssertEqual(
                        hit.steppedHandle(at: point),
                        symbol == "‹" ? expected.previousHandle : expected.nextHandle
                    )
                }
                destination = fixture.renderer.freezingReflow(in: destination)
                fixture.renderer.cancelAnimation()
                fixture.renderer.updatePresentation(destination, state: fixture.state)
            }
        }
    }

    @MainActor
    func testInteractiveTakeoverFreezesDisplayedOverviewEndpoint() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let displayed = card.root.frame
        let layout = fixture.layout(x: 330, width: 250)
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let frozen = fixture.renderer.freezingReflow(in: layout)
        fixture.renderer.cancelAnimation()
        fixture.renderer.updatePresentation(frozen, state: fixture.state)

        XCTAssertEqual(card.root.frame, displayed)
        XCTAssertEqual(frozen.window(for: fixture.handle)?.overviewFrame, displayed)
        XCTAssertFalse(fixture.renderer.isReflowing)
        let interactive = fixture.state(progress: 0.5)
        fixture.renderer.updatePresentation(frozen, state: interactive)
        XCTAssertEqual(card.root.frame, frozen.window(for: fixture.handle)?.interpolatedFrame(progress: 0.5))
    }

    @MainActor
    func testStructuralScrollRetargetAndGestureFreezeKeepScreenPosition() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let start = card.root.frame
        var layout = fixture.layout(x: 330)
        layout.scrollOffset = 140
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let displayedContent = OverviewLayerMotion.displayedFrame(of: fixture.renderer.content)
        let displayedCard = card.displayedFrame.offsetBy(dx: displayedContent.minX, dy: displayedContent.minY)

        XCTAssertEqual(displayedCard, start)
        XCTAssertEqual(
            fixture.renderer.windowHit(at: CGPoint(x: 150, y: 150), layout: layout)?.window.handle,
            fixture.handle
        )
        let chromePoint = fixture.renderer.layoutPoint(at: CGPoint(x: 150, y: 320), layout: layout)
        XCTAssertEqual(layout.ribbonSection(at: chromePoint)?.workspaceId, fixture.workspaceId)
        let frozen = fixture.renderer.freezingReflow(in: layout)
        XCTAssertEqual(frozen.scrollOffset, 0)
        fixture.renderer.cancelAnimation()
        fixture.renderer.updatePresentation(frozen, state: fixture.state)
        XCTAssertEqual(card.root.frame, start)
        XCTAssertEqual(fixture.renderer.content.frame.minY, 0)
    }

    @MainActor
    func testStructuralScrollKeepsCardsAndChromeVisibleAlongPresentationPath() throws {
        let fixture = Fixture()
        var layout = fixture.layout(x: 70)
        layout.scrollOffset = -500
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let chrome = try XCTUnwrap(fixture.renderer.chromeSections[fixture.workspaceId])

        XCTAssertFalse(card.root.isHidden)
        XCTAssertFalse(chrome.isHidden)
        XCTAssertTrue(fixture.renderer.visibleContentRect(for: layout, state: fixture.state)
            .contains(card.displayedFrame))
    }

    @MainActor
    func testCloseSpringStartsFromReflowPresentation() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let displayed = card.root.position
        let layout = fixture.layout(x: 330, width: 250)
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        let item = try XCTUnwrap(layout.window(for: fixture.handle))
        let close = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 1, to: 0)
        let state = fixture.state(progress: 0)
        card.updateGeometry(item, frame: item.originalFrame, state: state, transition: close, replacing: true)

        let animation = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((animation.fromValue as? NSValue)?.pointValue, displayed)
        XCTAssertEqual(card.root.frame, item.originalFrame)
    }

    @MainActor
    func testNativeCompletionAndRemovalEndReflowWithoutScheduledWork() throws {
        let fixture = Fixture()
        let layout = fixture.layout(x: 330)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        fixture.renderer.updateLayout(layout, state: fixture.state, caretAnimated: false, update: .structural)
        card.cancelAnimation()
        for layer in fixture.renderer.ribbonMotionLayers { OverviewLayerMotion.remove(from: layer) }
        XCTAssertFalse(fixture.renderer.isReflowing)
        fixture.renderer.updatePresentation(layout, state: fixture.state)
        XCTAssertNil(card.root.animation(forKey: "overview.position"))
        fixture.renderer.updateLayout(
            fixture.layout(x: 460),
            state: fixture.state,
            caretAnimated: false,
            update: .structural
        )
        fixture.renderer.updateLayout(.init(), state: fixture.state, caretAnimated: false, update: .immediate)
        XCTAssertFalse(fixture.renderer.isReflowing)
        XCTAssertTrue(fixture.renderer.windowLayers.isEmpty)
        XCTAssertNil(card.root.superlayer)
    }

    @MainActor
    func testReducedMotionFinishesAndDisablesPreviewReveal() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        fixture.renderer.updatePreview(try makeOverviewPreviewFrame(), for: fixture.handle)
        XCTAssertNotNil(card.thumbnail.animation(forKey: "overview.previewReveal"))
        fixture.renderer.updateLayout(
            fixture.layout(x: 70), state: fixture.state, caretAnimated: false, animationsEnabled: false
        )
        XCTAssertNil(card.thumbnail.animation(forKey: "overview.previewReveal"))
        fixture.renderer.updatePreview(nil, for: fixture.handle)
        fixture.renderer.updatePreview(try makeOverviewPreviewFrame(), for: fixture.handle)
        XCTAssertNil(card.thumbnail.animation(forKey: "overview.previewReveal"))
    }

    @MainActor
    func testViewportPanMovesColumnChromeWithCardsInBothOrientations() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            let fixture = Fixture()
            let initial = fixture.layout(x: 120, tabbed: true, orientation: orientation)
            fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
            fixture.renderer.updatePresentation(initial, state: fixture.state)
            let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
            let start = card.displayedFrame
            let column = try XCTUnwrap(fixture.renderer.columnLayers[fixture.workspaceId]?[0])
            let destination = fixture.layout(
                x: orientation == .horizontal ? 330 : 120,
                y: orientation == .vertical ? 280 : 120,
                tabbed: true,
                orientation: orientation
            )
            fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)

            XCTAssertTrue(fixture.renderer.columnLayers[fixture.workspaceId]?[0] === column)
            let columnFrame = OverviewLayerMotion.displayedFrame(of: column)
                .offsetBy(dx: fixture.ribbon.minX, dy: fixture.ribbon.minY)
            XCTAssertEqual(columnFrame, start)
            XCTAssertEqual(card.displayedFrame, start)
            XCTAssertTrue(try XCTUnwrap(column.superlayer).masksToBounds)
            XCTAssertEqual(column.superlayer?.frame, fixture.ribbon)
            XCTAssertNil(card.root.animation(forKey: "overview.opacity"))
            let spring = try XCTUnwrap(column.animation(forKey: "overview.position") as? CASpringAnimation)
            XCTAssertEqual(spring.stiffness, pow(2 * .pi / 0.25, 2), accuracy: 0.0001)
            XCTAssertEqual(spring.damping, 2 * sqrt(spring.stiffness * spring.mass))
            fixture.renderer.cancelReflow()
            XCTAssertNil(column.animation(forKey: "overview.position"))
        }
    }

    @MainActor
    func testViewportEntrySlidesAnExistingCardWithoutStructuralArrivalFade() throws {
        let fixture = Fixture()
        let initial = fixture.layout(x: 650)
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        XCTAssertTrue(card.root.isHidden)
        fixture.renderer.updateLayout(
            fixture.layout(x: 150), state: fixture.state, caretAnimated: false, update: .viewport
        )
        let motion = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CABasicAnimation)
        XCTAssertEqual((motion.fromValue as? NSValue)?.pointValue.x, 750)
        XCTAssertFalse(card.root.isHidden)
        XCTAssertNil(card.root.animation(forKey: "overview.opacity"))
    }

    @MainActor
    func testViewportRetargetPreservesHitsAndCloseStartsAtDisplayedPosition() throws {
        let fixture = Fixture()
        let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
        let start = card.root.position
        var destination = fixture.layout(x: 330)
        destination.scrollOffset = 100
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        destination = fixture.layout(x: 200)
        destination.scrollOffset = 40
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        let motion = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CABasicAnimation)
        XCTAssertEqual((motion.fromValue as? NSValue)?.pointValue, start)
        XCTAssertEqual(
            fixture.renderer.windowHit(at: CGPoint(x: 150, y: 150), layout: destination)?.window.handle,
            fixture.handle
        )
        let frozen = fixture.renderer.freezingReflow(in: destination)
        XCTAssertEqual(frozen.scrollOffset, 0)
        XCTAssertEqual(frozen.window(for: fixture.handle)?.overviewFrame, card.displayedFrame)
        let close = OverviewNativeTransition(generation: 2, startTime: CACurrentMediaTime(), from: 1, to: 0)
        let item = try XCTUnwrap(destination.window(for: fixture.handle))
        card.updateGeometry(
            item,
            frame: item.originalFrame,
            state: fixture.state(progress: 0),
            transition: close,
            replacing: true
        )
        let closing = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CABasicAnimation)
        XCTAssertEqual((closing.fromValue as? NSValue)?.pointValue, start)
    }

    @MainActor
    func testRibbonBackgroundReflowsAndRetargetsFromDisplayedBounds() throws {
        let fixture = Fixture()
        let base = CGRect(x: 200, y: 100, width: 200, height: 250)
        let initial = fixture.layout(x: 220, width: 160, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let retained = try XCTUnwrap(fixture.renderer.ribbonLayers[fixture.workspaceId])
        for destination in [
            fixture.layout(x: 70, tabbed: true, visibleFrame: base),
            fixture.layout(x: 410, width: 240, tabbed: true, visibleFrame: base)
        ] {
            fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
            let current = try XCTUnwrap(fixture.renderer.ribbonLayers[fixture.workspaceId])
            XCTAssertTrue(current.wallpaper === retained.wallpaper)
            XCTAssertTrue(current.shade === retained.shade)
            for layer in [current.wallpaper, current.shade] {
                XCTAssertEqual(OverviewLayerMotion.displayedFrame(of: layer), base)
                XCTAssertEqual(layer.frame, destination.backgroundFrame(for: destination.workspaceSections[0]))
                let spring = try XCTUnwrap(layer.animation(forKey: "overview.bounds") as? CASpringAnimation)
                XCTAssertEqual((spring.fromValue as? NSValue)?.rectValue.size, base.size)
                XCTAssertEqual(spring.stiffness, pow(2 * .pi / 0.25, 2), accuracy: 0.0001)
            }
        }
        fixture.renderer.cancelReflow()
        let narrow = fixture.layout(x: 220, width: 160, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(narrow, state: fixture.state, caretAnimated: false, update: .structural)
        XCTAssertEqual(retained.wallpaper.frame, base)
        XCTAssertNotNil(retained.wallpaper.animation(forKey: "overview.bounds"))
    }

    @MainActor
    func testRibbonTakeoverFreezesBackgroundCardsAndColumnsTogether() throws {
        let fixture = Fixture()
        let base = CGRect(x: 200, y: 100, width: 200, height: 250)
        let initial = fixture.layout(x: 120, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let background = try XCTUnwrap(fixture.renderer.ribbonLayers[fixture.workspaceId]).wallpaper
        let displayed = background.frame
        let destination = fixture.layout(x: 410, width: 240, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        let frozen = fixture.renderer.freezingReflow(in: destination)
        fixture.renderer.cancelAnimation()
        fixture.renderer.updateLayout(frozen, state: fixture.state, caretAnimated: false)
        fixture.renderer.updatePresentation(frozen, state: fixture.state)

        XCTAssertEqual(background.frame, displayed)
        XCTAssertEqual(
            frozen.niriColumnsByWorkspace[fixture.workspaceId]?.first?.frame,
            initial.niriColumnsByWorkspace[fixture.workspaceId]?.first?.frame
        )
        XCTAssertEqual(
            frozen.window(for: fixture.handle)?.overviewFrame,
            initial.window(for: fixture.handle)?.overviewFrame
        )
        XCTAssertFalse(fixture.renderer.isReflowing)
        XCTAssertNil(background.animation(forKey: "overview.position"))
        XCTAssertNil(background.animation(forKey: "overview.bounds"))
    }

    @MainActor
    func testAnimatedWallpaperCoversCardsWhileCrossingEitherRibbonEdgeAndShrinking() throws {
        for (start, end) in [
            (CGRect(x: 120, y: 120, width: 200, height: 180), CGRect(x: 410, y: 120, width: 240, height: 180)),
            (CGRect(x: 410, y: 120, width: 240, height: 180), CGRect(x: 120, y: 120, width: 200, height: 180)),
            (CGRect(x: 330, y: 120, width: 200, height: 180), CGRect(x: -80, y: 120, width: 240, height: 180)),
            (CGRect(x: -80, y: 120, width: 240, height: 180), CGRect(x: 330, y: 120, width: 200, height: 180))
        ] {
            let fixture = Fixture()
            let base = CGRect(x: 200, y: 100, width: 200, height: 250)
            let initial = fixture.layout(x: start.minX, width: start.width, tabbed: true, visibleFrame: base)
            fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
            fixture.renderer.updatePresentation(initial, state: fixture.state)
            let destination = fixture.layout(x: end.minX, width: end.width, tabbed: true, visibleFrame: base)
            fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
            let card = try XCTUnwrap(fixture.renderer.windowLayers[fixture.handle])
            let column = try XCTUnwrap(fixture.renderer.columnLayers[fixture.workspaceId]?[0])
            for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let cardFrame = interpolatedAnimationFrame(card.root, fraction: fraction).intersection(fixture.ribbon)
                let columnFrame = interpolatedAnimationFrame(column, fraction: fraction)
                    .offsetBy(dx: fixture.ribbon.minX, dy: fixture.ribbon.minY).intersection(fixture.ribbon)
                for background in fixture.renderer.ribbonMotionLayers {
                    let clip = try XCTUnwrap(background.superlayer)
                    XCTAssertTrue(clip.masksToBounds)
                    XCTAssertEqual(clip.cornerRadius, OverviewRenderStyle.Metrics.ribbonCornerRadius)
                    let frame = interpolatedAnimationFrame(background, fraction: fraction).intersection(clip.bounds)
                    XCTAssertTrue(frame.contains(cardFrame), "Background \(frame) must contain card \(cardFrame)")
                    XCTAssertTrue(frame.contains(columnFrame))
                    XCTAssertTrue(fixture.ribbon.contains(frame))
                }
            }
        }
    }

    @MainActor
    private func interpolatedAnimationFrame(_ layer: CALayer, fraction: CGFloat) -> CGRect {
        let position = layer.animation(forKey: "overview.position") as? CABasicAnimation
        let bounds = layer.animation(forKey: "overview.bounds") as? CABasicAnimation
        let fromPosition = (position?.fromValue as? NSValue)?.pointValue ?? layer.position
        let fromBounds = (bounds?.fromValue as? NSValue)?.rectValue ?? layer.bounds
        let width = fromBounds.width + (layer.bounds.width - fromBounds.width) * fraction
        let height = fromBounds.height + (layer.bounds.height - fromBounds.height) * fraction
        return CGRect(
            x: fromPosition.x + (layer.position.x - fromPosition.x) * fraction - width * layer.anchorPoint.x,
            y: fromPosition.y + (layer.position.y - fromPosition.y) * fraction - height * layer.anchorPoint.y,
            width: width, height: height
        )
    }

    @MainActor
    func testRibbonTakeoverPreservesIntermediateBoundsWhenContentCrossesDesktopEdges() throws {
        let fixture = Fixture()
        let base = CGRect(x: 200, y: 100, width: 200, height: 250)
        let initial = fixture.layout(x: 120, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let destination = fixture.layout(x: 410, width: 240, tabbed: true, visibleFrame: base)
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        let intermediateCard = CGRect(x: 265, y: 120, width: 220, height: 180)
        let intermediateBackground = CGRect(x: 160, y: 100, width: 365, height: 250)
        for card in fixture.renderer.windowLayers.values {
            setDisplayedFrame(intermediateCard, on: card.root)
        }
        let column = try XCTUnwrap(fixture.renderer.columnLayers[fixture.workspaceId]?[0])
        setDisplayedFrame(intermediateCard.offsetBy(dx: -fixture.ribbon.minX, dy: -fixture.ribbon.minY), on: column)
        for layer in fixture.renderer.ribbonMotionLayers { setDisplayedFrame(intermediateBackground, on: layer) }

        let frozen = fixture.renderer.freezingReflow(in: destination)
        fixture.renderer.cancelAnimation()
        fixture.renderer.updatePresentation(frozen, state: fixture.state)

        XCTAssertEqual(frozen.window(for: fixture.handle)?.overviewFrame, intermediateCard)
        XCTAssertEqual(frozen.niriColumnsByWorkspace[fixture.workspaceId]?.first?.frame, intermediateCard)
        for layer in fixture.renderer.ribbonMotionLayers {
            XCTAssertEqual(layer.frame, intermediateBackground)
            let clip = try XCTUnwrap(layer.superlayer)
            XCTAssertTrue(clip.masksToBounds)
            XCTAssertEqual(clip.frame, fixture.ribbon)
            XCTAssertEqual(clip.bounds, fixture.ribbon)
            XCTAssertTrue(layer.frame.intersection(clip.bounds).contains(intermediateCard.intersection(fixture.ribbon)))
            XCTAssertNil(layer.animation(forKey: "overview.position"))
            XCTAssertNil(layer.animation(forKey: "overview.bounds"))
        }
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        for layer in fixture.renderer.ribbonMotionLayers {
            XCTAssertEqual(OverviewLayerMotion.displayedFrame(of: layer), intermediateBackground)
            XCTAssertEqual(layer.frame, destination.backgroundFrame(for: destination.workspaceSections[0]))
        }
    }

    @MainActor
    private func setDisplayedFrame(_ frame: CGRect, on layer: CALayer) {
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
        position.toValue = NSValue(point: layer.position)
        layer.add(position, forKey: "overview.position")
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: CGRect(origin: .zero, size: frame.size))
        bounds.toValue = NSValue(rect: layer.bounds)
        layer.add(bounds, forKey: "overview.bounds")
    }

    @MainActor
    func testRibbonMotionCancelsForImmediateAndReducedMotionUpdatesAndWorkspaceRemoval() throws {
        for reducedMotion in [false, true] {
            let fixture = Fixture()
            let base = CGRect(x: 200, y: 100, width: 200, height: 250)
            let initial = fixture.layout(x: 220, width: 160, visibleFrame: base)
            fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
            fixture.renderer.updatePresentation(initial, state: fixture.state)
            let destination = fixture.layout(x: 70, visibleFrame: base)
            fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
            let layers = try XCTUnwrap(fixture.renderer.ribbonLayers[fixture.workspaceId])
            fixture.renderer.updateLayout(
                destination, state: fixture.state, caretAnimated: false,
                update: reducedMotion ? .preserve : .immediate, animationsEnabled: !reducedMotion
            )
            XCTAssertFalse(fixture.renderer.isReflowing)
            for layer in [layers.wallpaper, layers.shade] {
                XCTAssertNil(layer.animation(forKey: "overview.position"))
                XCTAssertNil(layer.animation(forKey: "overview.bounds"))
                XCTAssertEqual(layer.frame, destination.backgroundFrame(for: destination.workspaceSections[0]))
            }
            fixture.renderer.updateLayout(.init(), state: fixture.state, caretAnimated: false, update: .immediate)
            XCTAssertTrue(fixture.renderer.ribbonLayers.isEmpty)
            XCTAssertNil(layers.wallpaper.superlayer?.superlayer?.superlayer)
        }
    }

    @MainActor
    func testBackgroundOnlyMotionKeepsReflowAliveUntilNativeCompletion() throws {
        let fixture = Fixture()
        let base = CGRect(x: 200, y: 100, width: 200, height: 250)
        let initial = fixture.layout(x: 220, width: 160, visibleFrame: base)
        fixture.renderer.updateLayout(initial, state: fixture.state, caretAnimated: false, update: .immediate)
        fixture.renderer.updatePresentation(initial, state: fixture.state)
        let destination = fixture.layout(x: 70, visibleFrame: base)
        fixture.renderer.updateLayout(destination, state: fixture.state, caretAnimated: false, update: .viewport)
        for card in fixture.renderer.windowLayers.values { card.cancelAnimation() }
        XCTAssertTrue(fixture.renderer.isReflowing)
        for layer in fixture.renderer.ribbonMotionLayers { OverviewLayerMotion.remove(from: layer) }
        XCTAssertFalse(fixture.renderer.isReflowing)
        fixture.renderer.updatePresentation(destination, state: fixture.state)
        XCTAssertNil(fixture.renderer.reflowTransition)
    }

    @MainActor
    private struct Fixture {
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let tabHandle = WindowHandle(id: WindowToken(pid: 1, windowId: 2))
        let workspaceId = UUID()
        let renderer = OverviewLayerRenderer()
        let ribbon = CGRect(x: 100, y: 100, width: 400, height: 250)
        let state = OverviewRenderState(
            searchQuery: "",
            selectedWindowHandle: nil,
            hoveredWindowHandle: nil,
            closeButtonHovered: false,
            progress: 1,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            palette: .default
        )

        init() {
            let layout = layout(x: 70)
            renderer.updateLayout(layout, state: state, caretAnimated: false)
            renderer.updatePresentation(layout, state: state)
        }

        func state(progress: Double) -> OverviewRenderState {
            OverviewRenderState(
                searchQuery: state.searchQuery,
                selectedWindowHandle: state.selectedWindowHandle,
                hoveredWindowHandle: state.hoveredWindowHandle,
                closeButtonHovered: state.closeButtonHovered,
                progress: progress,
                bounds: state.bounds,
                palette: state.palette
            )
        }

        func layout(
            x: CGFloat,
            y: CGFloat = 120,
            width: CGFloat = 200,
            handle: WindowHandle? = nil,
            tabbed: Bool = false,
            orientation: Monitor.Orientation = .horizontal,
            visibleFrame: CGRect? = nil
        ) -> OverviewLayout {
            var item = OverviewWindowItem(
                handle: handle ?? self.handle,
                windowId: 1,
                workspaceId: workspaceId,
                title: "Window",
                appName: "App",
                appIcon: nil,
                originalFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
                overviewFrame: CGRect(x: x, y: y, width: width, height: 180),
                matchesSearch: true
            )
            item.isTiled = true
            var section = OverviewWorkspaceSection(
                workspaceId: workspaceId,
                name: "Workspace",
                windows: [item],
                sectionFrame: ribbon,
                labelFrame: .zero,
                gridFrame: ribbon,
                isActive: true,
                visibleFrame: visibleFrame ?? ribbon,
                ribbonFrame: ribbon,
                orientation: orientation
            )
            var layout = OverviewLayout()
            if tabbed {
                var inactive = self.layout(x: x, y: y, width: width, handle: tabHandle).allWindows[0]
                inactive.isDisplayed = false
                section.windows.append(inactive)
                layout.niriColumnsByWorkspace[workspaceId] = [OverviewNiriColumn(
                    workspaceId: workspaceId,
                    columnIndex: 0,
                    frame: item.overviewFrame,
                    windowHandles: [self.handle, tabHandle],
                    isTabbed: true
                )]
            }
            layout.replaceWorkspaceSections([section])
            return layout
        }
    }
}
