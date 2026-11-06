// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class OverviewDragPreviewTests: XCTestCase {
    func testGhostPreservesDragGeometryAndRegistersExcludedPassthroughPanel() {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }

        XCTAssertEqual(ghost.frame.size, CGSize(width: 400, height: 332))
        XCTAssertEqual(ghost.alphaValue, 1)
        XCTAssertEqual(ghost.thumbnail.opacity, 0.5)
        XCTAssertGreaterThan(ghost.level.rawValue, NSWindow.Level.screenSaver.rawValue)
        XCTAssertFalse(ghost.canBecomeKey)
        XCTAssertFalse(ghost.canBecomeMain)
        XCTAssertTrue(ghost.ignoresMouseEvents)
        XCTAssertTrue(registry.contains(window: ghost))
        XCTAssertFalse(registry.isCaptureEligible(windowNumber: ghost.windowNumber))
        XCTAssertNotNil(ghost.contentView?.layer?.backgroundColor)
        XCTAssertNil(ghost.thumbnail.contents)

        let screens = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let cursors = [
            CGPoint(x: screens.maxX + 1_000, y: screens.maxY + 1_000),
            CGPoint(x: screens.minX - 1_000, y: screens.minY - 1_000)
        ]
        for cursor in cursors {
            ghost.moveTo(cursorLocation: cursor)
            XCTAssertEqual(ghost.frame, CGRect(x: cursor.x + 10, y: cursor.y - 342, width: 400, height: 332))
        }
    }

    func testGhostUsesLiveSurfaceCropAndRefitsEachPreviewWithoutChangingPanelSize() throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }
        let cropped = try makeOverviewPreviewFrame(
            width: 200,
            height: 100,
            contentRect: CGRect(x: 25, y: 10, width: 100, height: 50)
        )
        ghost.updatePreview(cropped)

        XCTAssertTrue(ghost.preview === cropped)
        XCTAssertTrue((ghost.thumbnail.contents as? IOSurface) === cropped.surface)
        XCTAssertEqual(ghost.thumbnail.contentsRect, CGRect(x: 0.125, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 0, y: 82, width: 400, height: 200))

        let portrait = try makeOverviewPreviewFrame(width: 100, height: 200)
        ghost.updatePreview(portrait)
        ghost.moveTo(cursorLocation: CGPoint(x: 500, y: 500))

        XCTAssertTrue(ghost.preview === portrait)
        XCTAssertTrue((ghost.thumbnail.contents as? IOSurface) === portrait.surface)
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 125, y: 32, width: 150, height: 300))
        XCTAssertEqual(ghost.frame.size, CGSize(width: 400, height: 332))
        XCTAssertNil(ghost.thumbnail.animationKeys())

        ghost.updatePreview(nil)
        XCTAssertNil(ghost.preview)
        XCTAssertNil(ghost.thumbnail.contents)
        XCTAssertEqual(ghost.thumbnail.frame, CGRect(x: 0, y: 32, width: 400, height: 300))
    }

    func testFeedbackStaysReadableAndGhostStaysOnPointerDisplay() throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 300, height: 200), ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }
        let label = try XCTUnwrap(ghost.contentView?.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first)
        ghost.updateFeedback("New column", isValid: true)
        XCTAssertEqual(label.string as? String, "New column")
        XCTAssertEqual(label.foregroundColor, OverviewRenderStyle.Colors.textWhite)
        ghost.updateFeedback("Can’t drop here", isValid: false)
        XCTAssertEqual(label.string as? String, "Can’t drop here")
        XCTAssertEqual(label.foregroundColor, NSColor.systemRed.cgColor)
        for screen in NSScreen.screens {
            ghost.moveTo(cursorLocation: CGPoint(x: screen.frame.maxX - 1, y: screen.frame.minY + 1))
            XCTAssertTrue(screen.frame.contains(ghost.frame))
        }
    }

    func testReplacedPreviewRemainsPinnedUntilLayerTransactionCompletes() async throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        defer { ghost.destroy() }
        var first: OverviewPreviewFrame? = try makeOverviewPreviewFrame()
        weak let firstLifetime = first
        ghost.updatePreview(first)
        let replacement = try makeOverviewPreviewFrame(width: 160, height: 120)
        let committed = expectation(description: "Replacement layer transaction completed")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { committed.fulfill() }
        ghost.updatePreview(replacement)
        first = nil
        XCTAssertNotNil(firstLifetime)
        CATransaction.commit()
        CATransaction.flush()

        await fulfillment(of: [committed], timeout: failureBound)
        XCTAssertNil(firstLifetime)
        XCTAssertTrue(ghost.preview === replacement)
    }

    func testDestroyRetiresPreviewAndIgnoresLateUpdatesIdempotently() throws {
        let scene = SurfaceScene()
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator(scene: scene))
        let ghost = OverviewDragGhost(
            originalFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            ownedWindowRegistry: registry
        )
        ghost.updatePreview(try makeOverviewPreviewFrame())
        ghost.destroy()
        let retiredFrame = ghost.frame
        ghost.destroy()
        ghost.updatePreview(try makeOverviewPreviewFrame())
        ghost.moveTo(cursorLocation: CGPoint(x: 2000, y: 2000))

        XCTAssertNil(ghost.preview)
        XCTAssertNil(ghost.thumbnail.contents)
        XCTAssertEqual(ghost.frame, retiredFrame)
        XCTAssertFalse(ghost.isVisible)
        XCTAssertFalse(registry.contains(window: ghost))
        XCTAssertEqual(scene.runtimeSnapshot().total, 0)
        XCTAssertEqual(scene.runtimeSnapshot().orphanReverseEntries, 0)
    }
}
