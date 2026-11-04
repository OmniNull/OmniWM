// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriPicturePrewarmingTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()
    private let token = WindowToken(pid: 123, windowId: 456)
    private let display = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @MainActor
    private final class CaptureLog {
        var tokens: [WindowToken] = []
        var completions: [@MainActor (CGImage?) -> Void] = []

        func capture(_ token: WindowToken, completion: @escaping @MainActor (CGImage?) -> Void) -> Task<Void, Never>? {
            tokens.append(token)
            completions.append(completion)
            return nil
        }
    }

    private final class Surface: NiriTopEdgePictureSurface {
        var image: CGImage?
        var geometry: NiriTopEdgePictureGeometry?
        var destroyed = false

        func update(geometry: NiriTopEdgePictureGeometry, image: CGImage, activate _: @escaping @MainActor () -> Void) {
            self.geometry = geometry
            self.image = image
        }

        func destroy() {
            destroyed = true
        }
    }

    func testSettledPrewarmRunsBeforeEmptyPictureEarlyReturnAndDoesNotRetryFailure() {
        let log = CaptureLog()
        let presenter = presenter(log)
        let settled = plan(warm: [token: display.size])
        presenter.reconcile(settled)
        XCTAssertEqual(log.tokens, [token])
        log.completions[0](nil)
        presenter.reconcile(settled)
        XCTAssertEqual(log.tokens, [token])
        XCTAssertTrue(presenter.readyTokens.isEmpty)
    }

    func testPrewarmedImageMountsImmediatelyAndOneMotionRefreshReplacesIt() throws {
        let log = CaptureLog()
        let surface = Surface()
        let presenter = presenter(log, surface: surface)
        let first = try image()
        let newer = try image()
        presenter.reconcile(plan(warm: [token: display.size]))
        log.completions[0](first)
        XCTAssertEqual(presenter.readyTokens, [token])
        let moving = plan(settled: false, motion: [token: display.size], pictured: true)
        presenter.reconcile(moving)
        XCTAssertTrue(surface.image === first)
        XCTAssertEqual(log.tokens, [token, token])
        presenter.reconcile(moving)
        XCTAssertEqual(log.tokens, [token, token])
        log.completions[1](newer)
        XCTAssertTrue(surface.image === newer)
        XCTAssertEqual(surface.geometry?.frame, pictureFrame)
        XCTAssertFalse(surface.destroyed)
    }

    func testMotionSizeRefreshKeepsUsableWarmImageAndReadiness() throws {
        let log = CaptureLog()
        let surface = Surface()
        let presenter = presenter(log, surface: surface)
        let warm = try image()
        presenter.reconcile(plan(warm: [token: display.size]))
        log.completions[0](warm)
        let changedSize = CGSize(width: display.width, height: display.height / 2)
        presenter.reconcile(plan(settled: false, motion: [token: changedSize], pictured: true))
        XCTAssertEqual(log.tokens, [token, token])
        XCTAssertEqual(presenter.readyTokens, [token])
        XCTAssertTrue(surface.image === warm)
        log.completions[1](nil)
        XCTAssertEqual(presenter.readyTokens, [token])
        XCTAssertTrue(surface.image === warm)
    }

    func testPendingLandingCaptureIsInvalidatedWithItsContext() {
        let log = CaptureLog()
        let presenter = presenter(log)
        var landing = plan(warm: [token: display.size])
        landing.diff.frameChanges = [LayoutFrameChange(token: token, frame: display, forceApply: false)]
        presenter.reconcile(landing)
        presenter.retainCurrentContexts { _, _, _, _ in false }
        presenter.frameApplicationEnded(token: token, targetFrame: display)
        XCTAssertTrue(log.tokens.isEmpty)
    }

    func testRetargetAdmitsOnlyNewMotionCandidate() {
        let log = CaptureLog()
        let presenter = presenter(log)
        let other = WindowToken(pid: token.pid, windowId: token.windowId + 1)
        presenter.reconcile(plan(settled: false, motion: [token: display.size]))
        presenter.reconcile(plan(settled: false, motion: [token: display.size]))
        presenter.reconcile(plan(settled: false, motion: [token: display.size, other: display.size]))
        XCTAssertEqual(log.tokens, [token, other])
    }

    func testChangedSettledKeyCapturesButInteractiveResizeDoesNot() {
        let log = CaptureLog()
        let presenter = presenter(log)
        presenter.reconcile(plan(warm: [token: display.size]))
        log.completions[0](nil)
        let resized = CGSize(width: display.width, height: display.height / 2)
        var dragging = plan(warm: [token: resized])
        dragging.isInteractiveResize = true
        presenter.reconcile(dragging)
        XCTAssertEqual(log.tokens, [token])
        presenter.reconcile(plan(warm: [token: resized]))
        XCTAssertEqual(log.tokens, [token, token])
    }

    func testResizedLandingCapturesOnlyAfterMatchingAppliedFrame() {
        let log = CaptureLog()
        let presenter = presenter(log)
        var landing = plan(warm: [token: display.size])
        landing.diff.frameChanges = [LayoutFrameChange(token: token, frame: display, forceApply: false)]
        presenter.reconcile(landing)
        XCTAssertTrue(log.tokens.isEmpty)
        presenter.frameApplicationEnded(token: token, targetFrame: pictureFrame)
        XCTAssertTrue(log.tokens.isEmpty)
        presenter.frameApplicationEnded(token: token, targetFrame: display)
        XCTAssertEqual(log.tokens, [token])
    }

    func testFailedLandingDoesNotCaptureOrRetryUnchangedKey() {
        let log = CaptureLog()
        let presenter = presenter(log)
        var landing = plan(warm: [token: display.size])
        landing.diff.frameChanges = [LayoutFrameChange(token: token, frame: display, forceApply: false)]
        presenter.reconcile(landing)
        presenter.frameApplicationEnded(token: token, targetFrame: display, applied: false)
        presenter.reconcile(landing)
        XCTAssertTrue(log.tokens.isEmpty)
    }

    func testPressureReleasesSpeculationWithoutRefillingAndKeepsMountedPicture() throws {
        let log = CaptureLog()
        let surface = Surface()
        let presenter = presenter(log, surface: surface)
        let other = WindowToken(pid: token.pid, windowId: token.windowId + 1)
        let warm = [token: display.size, other: display.size]
        presenter.reconcile(plan(warm: warm))
        for completion in log.completions { completion(try image()) }
        presenter.reconcile(plan(warm: warm, pictured: true))
        presenter.handleMemoryPressure(true)
        XCTAssertEqual(presenter.readyTokens, [token])
        presenter.reconcile(plan(warm: warm, pictured: true))
        XCTAssertEqual(log.tokens.count, warm.count)
        XCTAssertNotNil(surface.image)
        presenter.handleMemoryPressure(false)
        presenter.reconcile(plan(warm: warm, pictured: true))
        XCTAssertEqual(log.tokens.filter { $0 == other }, [other, other])
    }

    func testIneligibleHostedOrDeniedTokenNeverCapturesOrBecomesReady() {
        let log = CaptureLog()
        let presenter = NiriTopEdgePictures(
            capture: log.capture, isCaptureEligible: { _ in false }, activate: { _, _ in }
        )
        presenter.reconcile(plan(warm: [token: display.size], pictured: true))
        XCTAssertTrue(log.tokens.isEmpty)
        XCTAssertTrue(presenter.readyTokens.isEmpty)
        XCTAssertTrue(presenter.pictures.isEmpty)
    }

    func testResetAndContextChangeRejectStaleCompletion() throws {
        let log = CaptureLog()
        let presenter = presenter(log)
        presenter.reconcile(plan(warm: [token: display.size]))
        presenter.reset()
        log.completions[0](try image())
        XCTAssertTrue(presenter.readyTokens.isEmpty)
        presenter.reconcile(plan(warm: [token: display.size]))
        presenter.retainCurrentContexts { _, _, _, _ in false }
        log.completions[1](try image())
        XCTAssertTrue(presenter.readyTokens.isEmpty)
    }

    func testHorizontalAndInactivePlansDoNotPrewarm() {
        let log = CaptureLog()
        let presenter = presenter(log)
        presenter.reconcile(plan(warm: [token: display.size], orientation: .horizontal))
        var inactive = plan(warm: [token: display.size])
        inactive.isActiveWorkspace = false
        presenter.reconcile(inactive)
        XCTAssertTrue(log.tokens.isEmpty)
    }

    private func presenter(_ log: CaptureLog, surface: Surface = Surface()) -> NiriTopEdgePictures {
        NiriTopEdgePictures(capture: log.capture, makeSurface: { surface }, activate: { _, _ in })
    }

    private var pictureFrame: CGRect {
        CGRect(x: display.minX, y: display.midY, width: display.width, height: display.height)
    }

    private func plan(
        settled: Bool = true,
        warm: [WindowToken: CGSize] = [:],
        motion: [WindowToken: CGSize] = [:],
        pictured: Bool = false,
        orientation: Monitor.Orientation = .vertical
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.picturePreparation = NiriPicturePreparation(
            isSettled: settled, warmCandidates: warm, motionCandidates: motion
        )
        if pictured { diff.topEdgeHiddenFrames[token] = pictureFrame }
        return WorkspaceLayoutPlan(
            workspaceId: workspaceId,
            monitor: LayoutMonitorSnapshot(
                monitorId: .init(displayId: 1), displayId: 1, frame: display, visibleFrame: display,
                workingFrame: display, fullscreenLayoutFrame: display, scale: 1, orientation: orientation
            ),
            sessionPatch: WorkspaceSessionPatch(workspaceId: workspaceId), diff: diff,
            isAnimationTick: !settled
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
