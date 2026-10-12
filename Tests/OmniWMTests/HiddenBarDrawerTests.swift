// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class HiddenBarDrawerTests: XCTestCase {
    func testRevealStartsTuckedUnderItsAttachmentEdge() {
        let size = CGSize(width: 240, height: 40)
        let cases: [(PopupAttachment.Edge, CGPoint)] = [
            (.above, CGPoint(x: 0, y: -40)),
            (.below, CGPoint(x: 0, y: 40)),
            (.left, CGPoint(x: 240, y: 0)),
            (.right, CGPoint(x: -240, y: 0))
        ]
        for (edge, offset) in cases {
            XCTAssertEqual(HiddenBarDrawerView.collapsedOffset(edge: edge, size: size, flipped: false), offset)
            let flipped = HiddenBarDrawerView.collapsedOffset(edge: edge, size: size, flipped: true)
            XCTAssertEqual(flipped, CGPoint(x: offset.x, y: -offset.y))
        }
    }

    func testReducedMotionCancelsPendingAnimationAndCompletesImmediately() throws {
        let drawer = makeDrawer()
        let policy = MotionPolicy(animationSpeed: 2)
        drawer.setVisible(true, edge: .below, motion: policy.snapshot())
        let opening = drawer.generation
        let animation = try XCTUnwrap(drawer.layer?.mask?.animation(forKey: "hiddenBar.reveal"))
        XCTAssertEqual(animation.duration, 0.11, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(drawer.layer?.animation(forKey: "hiddenBar.fade")).duration, 0.06, accuracy: 1e-9)
        XCTAssertEqual(drawer.layer?.mask?.position, .zero)

        policy.systemReducesMotion = true
        var completions = 0
        drawer.setVisible(false, edge: .below, motion: policy.snapshot()) { completions += 1 }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(drawer.layer?.opacity, 0)
        XCTAssertNil(drawer.layer?.mask?.animation(forKey: "hiddenBar.reveal"))
        XCTAssertNil(drawer.layer?.animation(forKey: "hiddenBar.fade"))
        drawer.complete(generation: opening)
        drawer.complete(generation: drawer.generation)
        XCTAssertEqual(completions, 1)
    }

    func testRevealUsesResetPositionAfterEdgeOrSizeChange() throws {
        for (edge, size) in [
            (PopupAttachment.Edge.right, CGSize(width: 60, height: 40)),
            (.below, CGSize(width: 120, height: 60))
        ] {
            let window = NSWindow(
                contentRect: CGRect(x: -10000, y: -10000, width: 60, height: 40),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let drawer = HiddenBarDrawerView(contentView: NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 40)))
            window.contentView = drawer
            drawer.setVisible(false, edge: .below, motion: .disabled)
            window.displayIfNeeded()
            CATransaction.flush()
            let mask = try XCTUnwrap(drawer.layer?.mask)
            let previous = try XCTUnwrap(mask.presentation()).position

            drawer.setFrameSize(size)
            drawer.setVisible(false, edge: edge, motion: .disabled)
            let reset = mask.position
            XCTAssertNotEqual(previous, reset)
            drawer.setVisible(true, edge: edge, motion: .enabled)

            let reveal = try XCTUnwrap(mask.animation(forKey: "hiddenBar.reveal") as? CABasicAnimation)
            XCTAssertEqual(reveal.fromValue as? CGPoint, reset)
            XCTAssertEqual(reveal.toValue as? CGPoint, .zero)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testReversingActiveRevealKeepsPresentationPosition() throws {
        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 60, height: 40),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let drawer = HiddenBarDrawerView(contentView: NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 40)))
        window.contentView = drawer
        drawer.setVisible(false, edge: .below, motion: .disabled)
        window.displayIfNeeded()
        CATransaction.flush()
        drawer.setVisible(true, edge: .below, motion: .enabled)
        CATransaction.flush()
        let mask = try XCTUnwrap(drawer.layer?.mask)
        let previous = try XCTUnwrap(mask.presentation()).position
        XCTAssertNotEqual(previous, mask.position)

        drawer.setVisible(false, edge: .below, motion: .enabled)

        let reveal = try XCTUnwrap(mask.animation(forKey: "hiddenBar.reveal") as? CABasicAnimation)
        XCTAssertEqual(reveal.fromValue as? CGPoint, previous)
        XCTAssertFalse(window.isVisible)
    }

    func testReopeningInvalidatesClosingCompletion() throws {
        let drawer = makeDrawer()
        var closes = 0
        drawer.setVisible(false, edge: .below, motion: .enabled) { closes += 1 }
        let closing = drawer.generation
        drawer.setVisible(true, edge: .below, motion: .enabled)

        drawer.complete(generation: closing)

        XCTAssertEqual(closes, 0)
        XCTAssertEqual(drawer.layer?.opacity, 1)
        let reveal = try XCTUnwrap(drawer.layer?.mask?.animation(forKey: "hiddenBar.reveal") as? CABasicAnimation)
        XCTAssertEqual(reveal.toValue as? CGPoint, .zero)
        XCTAssertEqual(reveal.duration, HiddenBarDrawerView.opening.duration)
    }

    func testContentHitRegionExcludesShadowMarginAndKeepsJoinedShoulders() {
        for edge in [PopupAttachment.Edge.below, .above, .left, .right] {
            let vertical = edge == .left || edge == .right
            let bar = CGRect(x: 300, y: 300, width: vertical ? 24 : 300, height: vertical ? 300 : 24)
            let placement = HiddenBarPanelPlacement(
                attachment: PopupAttachment(sourceFrame: bar, edge: edge),
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                    monitorId: .init(displayId: 92_200), frame: bar,
                    backgroundStyle: .material, backgroundOpacity: 0.6
                )
            )
            let layout = placement.layout(size: vertical ? CGSize(width: 24, height: 80) : CGSize(
                width: 80,
                height: 24
            ))
            let drawer = HiddenBarDrawerView(contentView: NSView(frame: CGRect(origin: .zero, size: layout.frame.size)))
            drawer.setRevealShape(layout.contour(edge: edge).cgPath, spread: HiddenBarPanelPlacement.liftMargin)
            let body = layout.body
            let shoulder: CGPoint
            let margin: CGPoint
            switch edge {
            case .below:
                shoulder = CGPoint(x: body.minX - 1, y: body.minY + 1)
                margin = CGPoint(x: body.midX, y: body.maxY + 5)
            case .above:
                shoulder = CGPoint(x: body.minX - 1, y: body.maxY - 1)
                margin = CGPoint(x: body.midX, y: body.minY - 5)
            case .right:
                shoulder = CGPoint(x: body.minX + 1, y: body.minY - 1)
                margin = CGPoint(x: body.maxX + 5, y: body.midY)
            case .left:
                shoulder = CGPoint(x: body.maxX - 1, y: body.minY - 1)
                margin = CGPoint(x: body.minX - 5, y: body.midY)
            }
            for point in [CGPoint(x: body.midX, y: body.midY), shoulder] {
                XCTAssertTrue(
                    drawer.containsContent(at: CGPoint(x: point.x, y: layout.frame.height - point.y)),
                    "\(edge)"
                )
            }
            XCTAssertFalse(
                drawer.containsContent(at: CGPoint(x: margin.x, y: layout.frame.height - margin.y)),
                "\(edge)"
            )
        }
    }

    func testRevealKeepsIconDrawingAndHitRegionsAligned() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
        let first = NSView(frame: CGRect(x: 20, y: 0, width: 24, height: 40))
        let second = NSView(frame: CGRect(x: 60, y: 0, width: 24, height: 40))
        content.addSubview(first)
        content.addSubview(second)
        let drawer = HiddenBarDrawerView(contentView: content)
        drawer.setVisible(false, edge: .right, motion: .disabled)
        drawer.setVisible(true, edge: .right, motion: .enabled)

        XCTAssertTrue(drawer.hitTest(CGPoint(x: 25, y: 15)) === first)
        XCTAssertTrue(drawer.hitTest(CGPoint(x: 65, y: 15)) === second)
        XCTAssertEqual(first.convert(first.bounds, to: drawer), first.frame)
        XCTAssertEqual(second.convert(second.bounds, to: drawer), second.frame)
    }

    func testPanelCloseWaitsForCompletionAndReopenRejectsStaleCompletion() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.toggle(placement: placement, items: [])
        let panel = try XCTUnwrap(controller.panel)
        let drawer = try XCTUnwrap(panel.contentView as? HiddenBarDrawerView)

        controller.dismiss()
        let closing = drawer.generation
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(OwnedWindowRegistry.shared.isCaptureEligible(windowNumber: panel.windowNumber))
        XCTAssertFalse(OwnedWindowRegistry.shared.visibleSurfaceIDs(suppressesManagedFocusRecovery: true)
            .contains("hidden-bar-panel"))

        controller.toggle(placement: placement, items: [])
        drawer.complete(generation: closing)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)

        controller.dismiss()
        drawer.complete(generation: drawer.generation)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: panel))
    }

    func testActivationHidesPanelBeforeOpeningNativeItemAndIgnoresClosingActions() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.toggle(placement: placement, items: [])
        let panel = try XCTUnwrap(controller.panel)
        var activations = 0
        controller.onActivate = { _ in
            activations += 1
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: panel))
        }
        let key = MenuBarItemKey(bundleID: "test.hidden", ordinal: 0)

        controller.activate(key)

        XCTAssertEqual(activations, 1)
        controller.toggle(placement: placement, items: [])
        controller.dismiss()
        controller.activate(key)
        XCTAssertEqual(activations, 1)
    }

    func testTeardownDuringCloseCannotAffectReplacementPanel() throws {
        let controller = makeController()
        defer { controller.teardown() }
        controller.toggle(placement: placement, items: [])
        let oldPanel = try XCTUnwrap(controller.panel)
        let oldDrawer = try XCTUnwrap(oldPanel.contentView as? HiddenBarDrawerView)
        controller.dismiss()
        let closing = oldDrawer.generation

        controller.teardown()
        XCTAssertFalse(oldPanel.isVisible)
        controller.toggle(placement: placement, items: [])
        oldDrawer.complete(generation: closing)

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.panel?.isVisible == true)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: controller.panel))
    }

    func testAttachedPanelFollowsSourceBarAndDismissesWhenItDisappears() throws {
        let controller = makeController()
        defer { controller.teardown() }
        let bar = CGRect(x: -7600, y: 700, width: 200, height: 24)
        var attached = HiddenBarPanelPlacement(
            attachment: PopupAttachment(sourceFrame: bar, edge: .below), visibleFrame: placement.visibleFrame,
            workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                monitorId: .init(displayId: 92_200), frame: bar,
                backgroundStyle: .material, backgroundOpacity: 0.6
            )
        )
        controller.toggle(placement: attached, items: [])
        let panel = try XCTUnwrap(controller.panel)
        let firstFrame = panel.frame
        XCTAssertFalse(panel.hasShadow)
        let movedBar = bar.offsetBy(dx: 150, dy: -20)
        attached = HiddenBarPanelPlacement(
            attachment: PopupAttachment(sourceFrame: movedBar, edge: .below), visibleFrame: placement.visibleFrame,
            workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                monitorId: .init(displayId: 92_200), frame: movedBar,
                backgroundStyle: .solidBlack, backgroundOpacity: 1
            )
        )

        controller.updateWorkspaceBarPlacement { monitorId in
            XCTAssertEqual(monitorId, .init(displayId: 92_200))
            return attached
        }

        XCTAssertNotEqual(panel.frame, firstFrame)
        XCTAssertEqual(panel.frame.minX, firstFrame.minX + 150)
        XCTAssertEqual(panel.frame.maxY, movedBar.minY)
        XCTAssertTrue(controller.isVisible)
        controller.updateWorkspaceBarPlacement { _ in nil }
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(panel.isVisible)
    }

    func testJoinedDrawerSquaresBarUntilItsOwnDismissalCompletes() throws {
        let controller = makeController()
        var joins: [HiddenBarPanelPlacement.Join?] = []
        controller.onWorkspaceBarJoin = { joins.append($0) }
        let narrowBar = CGRect(x: -7600, y: 700, width: 116, height: 24)
        let merged = attachedPlacement(bar: narrowBar)
        let joined = try XCTUnwrap(merged.join)

        controller.toggle(placement: merged, items: [])
        let drawer = try XCTUnwrap(controller.panel?.contentView as? HiddenBarDrawerView)
        XCTAssertEqual(joins.last, joined)
        controller.dismiss()
        let closing = drawer.generation
        XCTAssertEqual(joins.last, joined)

        controller.toggle(placement: merged, items: [])
        drawer.complete(generation: closing)
        XCTAssertEqual(joins.last, joined)

        controller.dismiss()
        drawer.complete(generation: drawer.generation)
        XCTAssertEqual(joins.last, .some(nil))

        controller.toggle(placement: attachedPlacement(bar: narrowBar.insetBy(dx: -100, dy: 0)), items: [])
        XCTAssertEqual(joins.last, .some(nil))
        controller.toggle(placement: merged, items: [])
        controller.toggle(placement: merged, items: [])
        controller.teardown()
        XCTAssertEqual(joins.last, .some(nil))
    }

    func testDetachedOrClosedPanelDoesNotReadWorkspaceBarPlacement() {
        let controller = makeController()
        defer { controller.teardown() }
        controller.updateWorkspaceBarPlacement { _ in
            XCTFail("Closed panel must not query workspace bars")
            return nil
        }
        controller.toggle(placement: placement, items: [])
        controller.updateWorkspaceBarPlacement { _ in
            XCTFail("Detached panel must not query workspace bars")
            return nil
        }
    }

    private var placement: HiddenBarPanelPlacement {
        HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: -7500, y: 700)),
            visibleFrame: CGRect(x: -8000, y: 0, width: 1200, height: 800)
        )
    }

    private func attachedPlacement(bar: CGRect) -> HiddenBarPanelPlacement {
        HiddenBarPanelPlacement(
            attachment: PopupAttachment(sourceFrame: bar, edge: .below), visibleFrame: placement.visibleFrame,
            workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                monitorId: .init(displayId: 92_200), frame: bar,
                backgroundStyle: .material, backgroundOpacity: 0.6
            )
        )
    }

    private func makeController() -> HiddenBarPanelController {
        _ = NSApplication.shared
        let controller = HiddenBarPanelController()
        controller.motionPolicy = MotionPolicy()
        return controller
    }

    private func makeDrawer() -> HiddenBarDrawerView {
        HiddenBarDrawerView(contentView: NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40)))
    }
}
