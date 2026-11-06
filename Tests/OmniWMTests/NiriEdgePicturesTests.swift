// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePicturesTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()
    private let token = WindowToken(pid: 123, windowId: 456)
    private let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private final class Surface: NiriEdgePictureSurface {
        let isVisibleForCapture = true
        var geometry: NiriEdgePictureGeometry?
        var activation: (@MainActor () -> Void)?
        var destroyed = false
        var hidden = false

        func update(
            geometry: NiriEdgePictureGeometry,
            content _: NiriPictureContent,
            activate: @escaping @MainActor () -> Void
        ) {
            self.geometry = geometry
            activation = activate
        }

        func setOrderingTarget(_: Int?) {}
        func hide() {
            hidden = true
        }

        func destroy() {
            destroyed = true
        }
    }

    func testCaptureOnceUpdatesCropAndSelectsExactWindow() throws {
        var completions: [@MainActor (CGImage?) -> Void] = []
        var surfaces: [Surface] = []
        var selected: (WindowToken, WorkspaceDescriptor.ID)?
        let presenter = NiriEdgePictures(
            capture: { _, completion in completions.append(completion)
                return Task {}
            },
            makeSurface: { let surface = Surface()
                surfaces.append(surface)
                return surface
            },
            activate: { selected = ($0, $1) }
        )
        let frame = topFrame
        presenter.reconcile(plan(pictured: [token: frame]))
        XCTAssertEqual(completions.count, 1)
        XCTAssertTrue(surfaces.isEmpty)
        completions[0](try image())
        let surface = try XCTUnwrap(surfaces.first)
        XCTAssertEqual(surface.geometry?.visibleFrame, frame.intersection(displayFrame))
        XCTAssertEqual(surface.geometry?.pictureFrame, CGRect(origin: .zero, size: frame.size))
        let moved = frame.offsetBy(dx: 0, dy: -frame.height / 4)
        presenter.reconcile(plan(pictured: [token: moved]))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(surface.geometry?.frame, moved)
        surface.activation?()
        XCTAssertEqual(selected?.0, token)
        XCTAssertEqual(selected?.1, workspaceId)
        presenter.reset()
    }

    func testRevealWaitsForMatchingResultAndReversalRejectsOldResult() throws {
        let surface = Surface()
        let captured = try image()
        let presenter = NiriEdgePictures(
            capture: { _, completion in completion(captured)
                return nil
            },
            makeSurface: { surface }, activate: { _, _ in }
        )
        presenter.reconcile(plan(pictured: [token: topFrame]))
        let native = topFrame.offsetBy(dx: 0, dy: -topFrame.height)
        presenter.reconcile(plan(revealed: [token: native]))
        XCTAssertFalse(surface.destroyed)
        presenter.frameApplicationEnded(token: token, targetFrame: topFrame)
        XCTAssertFalse(surface.destroyed)
        presenter.reconcile(plan(pictured: [token: topFrame]))
        presenter.frameApplicationEnded(token: token, targetFrame: native)
        XCTAssertFalse(surface.destroyed)
        presenter.reconcile(plan(revealed: [token: native]))
        presenter.frameApplicationEnded(token: token, targetFrame: native)
        XCTAssertTrue(surface.hidden)
        XCTAssertFalse(surface.destroyed)
        presenter.reset()
    }

    func testRetiredCaptureCannotPublishIntoNewPicture() throws {
        var completions: [@MainActor (CGImage?) -> Void] = []
        var surfaces: [Surface] = []
        let presenter = NiriEdgePictures(
            capture: { _, completion in completions.append(completion)
                return Task {}
            },
            makeSurface: { let surface = Surface()
                surfaces.append(surface)
                return surface
            },
            activate: { _, _ in }
        )
        presenter.reconcile(plan(pictured: [token: topFrame]))
        presenter.remove(token)
        presenter.reconcile(plan(pictured: [token: topFrame]))
        XCTAssertEqual(completions.count, 2)
        completions[0](try image())
        XCTAssertTrue(surfaces.isEmpty)
        completions[1](try image())
        XCTAssertEqual(surfaces.count, 1)
        presenter.retainWorkspaces([])
        XCTAssertTrue(try XCTUnwrap(surfaces.first).destroyed)
    }

    func testFailureDoesNotRetryAndHorizontalOrEmptyPlanRetires() throws {
        var captureCount = 0
        var surfaces: [Surface] = []
        let captured = try image()
        let presenter = NiriEdgePictures(
            capture: { _, completion in
                captureCount += 1
                completion(captureCount == 1 ? nil : captured)
                return nil
            },
            makeSurface: { let surface = Surface()
                surfaces.append(surface)
                return surface
            },
            activate: { _, _ in }
        )
        presenter.reconcile(plan(pictured: [token: topFrame]))
        presenter.reconcile(plan(pictured: [token: topFrame]))
        XCTAssertEqual(captureCount, 1)
        XCTAssertTrue(surfaces.isEmpty)
        presenter.reconcile(plan())
        presenter.reconcile(plan(pictured: [token: topFrame]))
        presenter.reconcile(plan(pictured: [token: topFrame], orientation: .horizontal))
        XCTAssertEqual(captureCount, 2)
        XCTAssertTrue(try XCTUnwrap(surfaces.first).destroyed)
    }

    func testChangedContextRetiresBeforeCaptureCanPublish() throws {
        var completion: (@MainActor (CGImage?) -> Void)?
        var surfaceCount = 0
        let presenter = NiriEdgePictures(
            capture: { _, ready in completion = ready
                return Task {}
            },
            makeSurface: { surfaceCount += 1
                return Surface()
            },
            activate: { _, _ in }
        )
        presenter.reconcile(plan(pictured: [token: topFrame]))
        var checkedToken: WindowToken?
        presenter.retainCurrentContexts { currentToken, _, _, _ in
            checkedToken = currentToken
            return false
        }
        XCTAssertEqual(checkedToken, token)
        try XCTUnwrap(completion)(image())
        XCTAssertEqual(surfaceCount, 0)
    }

    func testPictureAllowsGesturesButStillOwnsClicks() {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "NiriEdgePicturesTests", ownedWindowRegistry: registry
        )
        registry.registerWindowNumber(
            surfaceId: "picture", policy: SurfacePolicy(
                kind: .niriEdgePicture, hitTestPolicy: .interactive,
                capturePolicy: .excluded, suppressesManagedFocusRecovery: false
            ), windowNumber: token.windowId, frameProvider: { self.displayFrame }, visibilityProvider: { true }
        )
        let point = displayFrame.center
        XCTAssertFalse(controller.mouseEventHandler.shouldBlockOwnWindowGestureInput(at: point))
        XCTAssertTrue(registry.contains(point: point, excluding: [.parkingEdgeMask]))
        XCTAssertTrue(registry.contains(windowNumber: token.windowId))
        XCTAssertFalse(registry.isCaptureEligible(windowNumber: token.windowId))
        XCTAssertTrue(controller.mouseEventHandler.shouldBlockOwnWindowInput(
            at: point, windowIdUnderPointer: token.windowId
        ))
        let coveringWindowId = token.windowId + 1
        XCTAssertFalse(controller.mouseEventHandler.shouldBlockOwnWindowInput(
            at: point, windowIdUnderPointer: coveringWindowId
        ))
    }

    func testPictureStaysBelowFloatingWindowsAndOnItsOwnSpace() {
        let window = NiriEdgePictureWindow()
        defer { window.destroy() }
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.isFloatingPanel)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    private var topFrame: CGRect {
        CGRect(
            x: displayFrame.width / 4,
            y: displayFrame.maxY - displayFrame.height / 4,
            width: displayFrame.width / 2,
            height: displayFrame.height / 2
        )
    }

    private func plan(
        pictured: [WindowToken: CGRect] = [:],
        revealed: [WindowToken: CGRect] = [:],
        orientation: Monitor.Orientation = .vertical
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.edgeHiddenFrames = pictured
        diff.frameChanges = revealed.map { LayoutFrameChange(token: $0.key, frame: $0.value, forceApply: false) }
        return WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: LayoutMonitorSnapshot(
                monitorId: Monitor.ID(displayId: 1), displayId: 1,
                frame: displayFrame, visibleFrame: displayFrame, workingFrame: displayFrame,
                fullscreenLayoutFrame: displayFrame, scale: 1, orientation: orientation
            ),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId, viewportState: nil), diff: diff
        )
    }

    private func image() throws -> CGImage {
        let components = 4
        let bitsPerComponent = 8
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: bitsPerComponent,
            bytesPerRow: components, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}
