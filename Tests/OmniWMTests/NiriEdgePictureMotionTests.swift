// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePictureMotionTests: XCTestCase {
    private let workspace = WorkspaceDescriptor.ID()
    private let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let tokens = [WindowToken(pid: 100, windowId: 200), WindowToken(pid: 100, windowId: 201)]

    @MainActor
    private final class State {
        var ordering: Int?
        var publishedFrame: CGRect
        var visible = true

        init(frame: CGRect, ordering: Int? = nil) {
            publishedFrame = frame
            self.ordering = ordering
        }
    }

    private final class Surface: NiriEdgePictureSurface {
        var isVisibleForCapture = false
        var orderingTargets: [Int?] = []
        var activation: (@MainActor () -> Void)?
        var destroyed = false

        func setOrderingTarget(_ windowId: Int?) {
            orderingTargets.append(windowId)
        }

        func update(
            geometry _: NiriEdgePictureGeometry, content _: NiriPictureContent,
            activate: @escaping @MainActor () -> Void
        ) {
            isVisibleForCapture = true
            activation = activate
        }

        func hide() {
            isVisibleForCapture = false
            activation = nil
        }

        func destroy() {
            hide()
            destroyed = true
        }
    }

    func testSettledPoolReusesHiddenSurfaceAndRefreshesOrderingAndExactActivation() throws {
        let image = try image()
        var created: [Surface] = []
        let state = State(frame: display, ordering: tokens[0].windowId)
        var selected: [WindowToken] = []
        let presenter = NiriEdgePictures(
            capture: { _, completion in completion(image)
                return nil
            },
            makeSurface: { let surface = Surface()
                created.append(surface)
                return surface
            },
            orderingWindowId: { state.ordering }, activate: { token, _ in selected.append(token) }
        )
        defer { presenter.reset() }
        var settled = plan()
        settled.diff.picturePreparation = NiriPicturePreparation(
            isSettled: true, warmCandidates: Dictionary(uniqueKeysWithValues: tokens.map { ($0, pictureFrame.size) })
        )
        presenter.reconcile(settled)
        XCTAssertEqual(created.count, tokens.count)
        XCTAssertTrue(created.allSatisfy { !$0.isVisibleForCapture && $0.orderingTargets.isEmpty })
        let warmedCount = created.count
        presenter.reconcile(plan(pictured: [tokens[0]: pictureFrame], moving: true))
        let first = try XCTUnwrap(presenter.pictures[tokens[0]]?.surface as? Surface)
        let oldActivation = try XCTUnwrap(first.activation)
        XCTAssertEqual(presenter.pictures[tokens[0]]?.isResting, false)
        XCTAssertEqual(first.orderingTargets, [tokens[0].windowId])
        XCTAssertEqual(created.count, warmedCount)
        presenter.reconcile(plan(moving: true))
        XCTAssertFalse(first.isVisibleForCapture)
        XCTAssertFalse(first.destroyed)
        state.ordering = tokens[1].windowId
        presenter.reconcile(plan(pictured: [tokens[1]: pictureFrame], moving: true))
        let reused = try XCTUnwrap(presenter.pictures[tokens[1]]?.surface as? Surface)
        XCTAssertTrue(reused === first)
        XCTAssertEqual(created.count, warmedCount)
        XCTAssertEqual(reused.orderingTargets, tokens.map { Optional($0.windowId) })
        oldActivation()
        XCTAssertTrue(selected.isEmpty)
        reused.activation?()
        XCTAssertEqual(selected, [tokens[1]])
    }

    func testPoolExhaustionStillDisplaysReadyPictureAndResetDestroysSpares() throws {
        let image = try image()
        var created: [Surface] = []
        let presenter = NiriEdgePictures(
            capture: { _, completion in completion(image)
                return nil
            },
            makeSurface: { let surface = Surface()
                created.append(surface)
                return surface
            }, activate: { _, _ in }
        )
        presenter.reconcile(plan(pictured: [tokens[0]: pictureFrame], moving: true))
        let surface = try XCTUnwrap(created.first)
        XCTAssertTrue(surface.isVisibleForCapture)
        presenter.reconcile(plan(moving: true))
        XCTAssertFalse(surface.isVisibleForCapture)
        XCTAssertFalse(surface.destroyed)
        presenter.reset()
        XCTAssertTrue(surface.destroyed)
        XCTAssertTrue(presenter.spareSurfaces.isEmpty)
    }

    func testFullPanelMovesWhenOverflowCannotReachAnotherDisplay() throws {
        let cornerNeighbor = display.offsetBy(dx: display.width, dy: display.height)
        let sideNeighbor = display.offsetBy(dx: display.width, dy: 0)
        for neighbors in [[], [cornerNeighbor], [sideNeighbor]] {
            let geometry = try XCTUnwrap(NiriEdgePictureGeometry(
                frame: pictureFrame, displayFrame: display, otherDisplayFrames: neighbors
            ))
            XCTAssertEqual(geometry.panelFrame, pictureFrame)
            XCTAssertEqual(geometry.visibleFrame, pictureFrame.intersection(display))
        }
    }

    func testPublishedFrameAndHiddenStatePreserveOwnedWindowIdentity() {
        let coordinator = SurfaceCoordinator()
        let window = NSPanel(contentRect: display, styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.close() }
        let state = State(frame: display.offsetBy(dx: display.width, dy: 0))
        coordinator.register(
            window: window, id: "picture",
            policy: SurfacePolicy(
                kind: .niriEdgePicture, hitTestPolicy: .interactive,
                capturePolicy: .excluded, suppressesManagedFocusRecovery: false
            ), frameProvider: { state.publishedFrame }, visibilityProvider: { state.visible }
        )
        XCTAssertTrue(coordinator.contains(window: window))
        XCTAssertTrue(coordinator.containsInteractive(point: state.publishedFrame.center))
        XCTAssertFalse(coordinator.containsInteractive(point: display.center))
        state.publishedFrame = display
        XCTAssertTrue(coordinator.containsInteractive(point: display.center))
        state.visible = false
        XCTAssertFalse(coordinator.containsInteractive(point: display.center))
        XCTAssertTrue(coordinator.contains(window: window))
    }

    func testNeighborAboveOrBelowKeepsClippedPanel() throws {
        for direction in [CGFloat(-1), CGFloat(1)] {
            let neighbor = display.offsetBy(dx: 0, dy: direction * display.height)
            let frame = display.offsetBy(dx: 0, dy: direction * display.height / 2)
            let geometry = try XCTUnwrap(NiriEdgePictureGeometry(
                frame: frame, displayFrame: display, otherDisplayFrames: [neighbor]
            ))
            XCTAssertEqual(geometry.panelFrame, frame.intersection(display))
        }
    }

    func testBorderOutsetIsIncludedInNeighborClipDecision() throws {
        let neighbor = display.offsetBy(dx: 0, dy: display.height)
        let native = CGRect(
            x: display.width / 4, y: display.height / 2,
            width: display.width / 2, height: display.height / 2
        )
        let geometry = try XCTUnwrap(NiriEdgePictureGeometry(
            frame: native, displayFrame: display, otherDisplayFrames: [neighbor]
        ))
        XCTAssertEqual(geometry.panelFrame, native)
        let config = BorderConfig(
            enabled: true,
            width: display.height / 100,
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let border = config.resolvedGeometry(for: native, scale: 2)
        let presentation = BorderPresentation(
            windowId: UInt32(tokens[0].windowId), displayFrame: display, scale: 2, otherDisplayFrames: [neighbor]
        )
        XCTAssertEqual(presentation.displayClip(for: border.surfaceFrame), display)
        var isolated = presentation
        isolated.otherDisplayFrames = []
        XCTAssertNil(isolated.displayClip(for: border.surfaceFrame))
    }

    private var pictureFrame: CGRect {
        CGRect(
            x: display.width / 4, y: display.height * 3 / 4,
            width: display.width / 2, height: display.height / 2
        )
    }

    private func plan(pictured: [WindowToken: CGRect] = [:], moving: Bool = false) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.edgeHiddenFrames = pictured
        return WorkspaceLayoutPlan(
            workspaceId: workspace,
            monitor: LayoutMonitorSnapshot(
                monitorId: .init(displayId: 1), displayId: 1,
                frame: display, visibleFrame: display, workingFrame: display, fullscreenLayoutFrame: display,
                scale: 2, orientation: .vertical
            ), sessionPatch: .init(workspaceId: workspace), diff: diff, isAnimationTick: moving
        )
    }

    private func image() throws -> CGImage {
        let components = 4
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: components,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}
