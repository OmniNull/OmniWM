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

    @MainActor
    private final class JoinLog {
        var joins: [HiddenBarPanelPlacement.Join?] = []
    }

    func testAttachedDrawerFollowsItsBarWithoutAShadow() throws {
        let log = JoinLog()
        let chrome = ShellDrawerChrome(
            content: NSView(),
            placement: attachedPlacement(bar: CGRect(x: -7600, y: 700, width: 200, height: 24)),
            motion: MotionPolicy(animationsEnabled: false)
        ) { log.joins.append($0) }
        defer { chrome.close(animated: false) }
        chrome.show(size: CGSize(width: 120, height: 24), level: .popUpMenu)
        let firstFrame = chrome.panel.frame
        XCTAssertFalse(chrome.panel.hasShadow)

        let movedBar = CGRect(x: -7450, y: 680, width: 200, height: 24)
        chrome.move(to: attachedPlacement(bar: movedBar))
        XCTAssertEqual(chrome.panel.frame.minX, firstFrame.minX + 150, accuracy: 1)
        XCTAssertEqual(chrome.panel.frame.maxY, movedBar.minY, accuracy: 1)
        XCTAssertTrue(chrome.panel.isVisible)

        chrome.move(to: placement)
        XCTAssertTrue(chrome.panel.hasShadow)
    }

    func testJoinedDrawerSquaresTheBarUntilItsOwnCloseCompletes() async throws {
        let log = JoinLog()
        let merged = attachedPlacement(bar: CGRect(x: -7600, y: 700, width: 116, height: 24))
        let joined = try XCTUnwrap(merged.join)
        let chrome = ShellDrawerChrome(
            content: NSView(),
            placement: merged,
            motion: MotionPolicy(animationsEnabled: true)
        ) { log.joins.append($0) }
        chrome.show(size: CGSize(width: 140, height: 24), level: .popUpMenu)
        XCTAssertEqual(log.joins.last, joined)

        chrome.close(animated: true)
        XCTAssertEqual(log.joins.last, joined)
        XCTAssertTrue(chrome.panel.isVisible)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !chrome.panel.isVisible }, object: nil)
        await fulfillment(of: [closed], timeout: 10)
        XCTAssertEqual(log.joins.last, .some(nil))
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

    private func makeDrawer() -> HiddenBarDrawerView {
        HiddenBarDrawerView(contentView: NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40)))
    }
}
