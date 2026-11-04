// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePictureLiveRefreshTests: XCTestCase {
    @MainActor
    private final class Driver {
        var requested: [WindowToken] = []
        var completions: [@MainActor (CGImage?) -> Void] = []
        var intervals: [Duration] = []
        var ticks: [@MainActor () -> Void] = []
        var cancelled: [Int] = []
        var eligible = true
        var overviewOpen = false
        var surfaces: [Surface] = []
        var presentationChanges = 0

        func capture(_ token: WindowToken, completion: @escaping @MainActor (CGImage?) -> Void) -> Task<Void, Never>? {
            requested.append(token)
            completions.append(completion)
            return Task {}
        }

        func cadence(_ interval: Duration, tick: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            let index = ticks.count
            intervals.append(interval)
            ticks.append(tick)
            return { self.cancelled.append(index) }
        }

        func makePresenter() -> NiriEdgePictures {
            let presenter = NiriEdgePictures(
                capture: { self.capture($0, completion: $1) },
                startCadence: { self.cadence($0, tick: $1) },
                makeSurface: {
                    let surface = Surface()
                    self.surfaces.append(surface)
                    return surface
                },
                isCaptureEligible: { _ in self.eligible },
                isOverviewOpen: { self.overviewOpen }, activate: { _, _ in }
            )
            presenter.onPresentationChanged = { self.presentationChanges += 1 }
            return presenter
        }
    }

    private final class Surface: NiriEdgePictureSurface {
        let windowId: UInt32? = 500
        var isVisibleForCapture = true
        var image: CGImage?
        var destroyed = false
        var updates = 0

        func update(geometry _: NiriEdgePictureGeometry, image: CGImage, activate _: @escaping @MainActor () -> Void) {
            self.image = image
            updates += 1
        }

        func destroy() {
            destroyed = true
        }
    }

    private let token = WindowToken(pid: 100, windowId: 200)
    private let workspace = WorkspaceDescriptor.ID()
    private let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let scale: CGFloat = 2

    func testRestingMountedPictureOwnsOneCadenceAndOnePendingCapture() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        XCTAssertTrue(driver.intervals.isEmpty)
        let first = try image()
        driver.completions[0](first)
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        presenter.reconcile(plan())
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        let updatesBeforeCapture = driver.surfaces[0].updates
        driver.ticks[0]()
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token, token])
        XCTAssertTrue(driver.surfaces[0].image === first)
        XCTAssertEqual(driver.surfaces[0].updates, updatesBeforeCapture)
        let live = try image()
        driver.completions[1](live)
        XCTAssertTrue(driver.surfaces[0].image === live)
        XCTAssertEqual(driver.surfaces[0].updates, updatesBeforeCapture + 1)
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token, token, token])
        driver.completions[2](nil)
        XCTAssertTrue(driver.surfaces[0].image === live)
        XCTAssertFalse(driver.surfaces[0].destroyed)
    }

    func testMotionAndInteractiveResizeSuspendUntilAnActualSettledPlan() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        driver.completions[0](try image())
        for interactive in [false, true] {
            var moving = plan(settled: false)
            moving.isInteractiveResize = interactive
            presenter.reconcile(moving)
            let captures = driver.requested
            driver.ticks.last?()
            XCTAssertEqual(driver.requested, captures)
            XCTAssertNil(presenter.cancelLiveRefresh)
            presenter.reconcile(plan())
            XCTAssertNotNil(presenter.cancelLiveRefresh)
        }
        XCTAssertEqual(driver.intervals, Array(repeating: NiriEdgePictures.liveRefreshInterval, count: 3))
        XCTAssertEqual(driver.cancelled, [0, 1])
    }

    func testOverviewAndPressureSkipCapturesWithoutBlankingOrRestartingCadence() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        let first = try image()
        driver.completions[0](first)
        driver.overviewOpen = true
        driver.ticks[0]()
        XCTAssertNotNil(presenter.cancelLiveRefresh)
        XCTAssertEqual(driver.requested, [token])
        XCTAssertTrue(driver.surfaces[0].image === first)
        presenter.handleMemoryPressure(true)
        driver.overviewOpen = false
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token])
        presenter.handleMemoryPressure(false)
        XCTAssertNotNil(presenter.cancelLiveRefresh)
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        XCTAssertTrue(driver.cancelled.isEmpty)
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token, token])
    }

    func testOccludedPictureSkipsCaptureAndResumesOnNextVisibleTick() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        let first = try image()
        driver.completions[0](first)
        let surface = try XCTUnwrap(driver.surfaces.first)
        surface.isVisibleForCapture = false
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token])
        XCTAssertTrue(surface.image === first)
        XCTAssertNotNil(presenter.cancelLiveRefresh)
        surface.isVisibleForCapture = true
        driver.ticks[0]()
        driver.ticks[0]()
        XCTAssertEqual(driver.requested, [token, token])
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        XCTAssertTrue(driver.cancelled.isEmpty)
    }

    func testRetirementInvalidatesOutstandingLiveCaptureAndStopsCadence() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        driver.completions[0](try image())
        driver.ticks[0]()
        presenter.reconcile(plan(pictured: false))
        XCTAssertEqual(driver.cancelled, [0])
        XCTAssertTrue(driver.surfaces[0].destroyed)
        XCTAssertTrue(presenter.readyTokens.isEmpty)
        driver.completions[1](try image())
        XCTAssertTrue(presenter.readyTokens.isEmpty)
        XCTAssertTrue(presenter.pictures.isEmpty)
    }

    func testPresentationUsesDisplayScaleAndPersistsThroughActualRevealCompletion() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        presenter.reconcile(plan())
        XCTAssertNil(presenter.presentation(for: token))
        driver.completions[0](try image())
        var expected = NiriEdgePicturePresentation(
            frame: pictureFrame, displayFrame: frame, scale: scale, windowId: try XCTUnwrap(driver.surfaces[0].windowId)
        )
        XCTAssertEqual(presenter.presentation(for: token), expected)
        XCTAssertEqual(driver.presentationChanges, 1)
        var landing = plan(pictured: false)
        landing.diff.frameChanges = [.init(token: token, frame: frame, forceApply: false)]
        presenter.reconcile(landing)
        expected = .init(frame: frame, displayFrame: frame, scale: scale, windowId: expected.windowId)
        XCTAssertEqual(presenter.presentation(for: token), expected)
        XCTAssertNil(presenter.cancelLiveRefresh)
        presenter.frameApplicationEnded(token: token, targetFrame: frame)
        XCTAssertNil(presenter.presentation(for: token))
        XCTAssertEqual(driver.presentationChanges, 2)
    }

    func testPermissionContextAndHorizontalRetirementStopCadence() throws {
        for reason in ["permission", "context", "horizontal"] {
            let driver = Driver()
            let presenter = driver.makePresenter()
            presenter.reconcile(plan())
            driver.completions[0](try image())
            switch reason {
            case "permission":
                driver.eligible = false
                presenter.reset()
            case "context": presenter.retainCurrentContexts { _, _, _, _ in false }
            default: presenter.reconcile(plan(orientation: .horizontal))
            }
            XCTAssertEqual(driver.cancelled, [0])
            XCTAssertNil(presenter.cancelLiveRefresh)
            XCTAssertTrue(presenter.pictures.isEmpty)
            driver.ticks[0]()
            XCTAssertEqual(driver.requested, [token])
        }
    }

    func testSeveralRestingPicturesShareOneCadence() throws {
        let driver = Driver()
        let presenter = driver.makePresenter()
        let other = WindowToken(pid: token.pid, windowId: token.windowId + 1)
        var both = plan()
        both.diff.edgeHiddenFrames[other] = pictureFrame.offsetBy(dx: frame.width / 2, dy: 0)
        presenter.reconcile(both)
        let firstCaptures = driver.completions
        for complete in firstCaptures { complete(try image()) }
        XCTAssertEqual(Set(driver.requested), [token, other])
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        driver.ticks[0]()
        XCTAssertEqual(driver.requested.count, firstCaptures.count * 2)
        driver.ticks[0]()
        XCTAssertEqual(driver.requested.count, firstCaptures.count * 2)
    }

    func testReleasingPresenterCancelsItsCadence() throws {
        let driver = Driver()
        var presenter: NiriEdgePictures? = driver.makePresenter()
        presenter?.reconcile(plan())
        driver.completions[0](try image())
        XCTAssertEqual(driver.intervals, [NiriEdgePictures.liveRefreshInterval])
        presenter = nil
        XCTAssertEqual(driver.cancelled, [0])
    }

    private var pictureFrame: CGRect {
        frame.offsetBy(dx: 0, dy: frame.height / 2)
    }

    private func plan(
        settled: Bool = true, pictured: Bool = true, orientation: Monitor.Orientation = .vertical
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.picturePreparation = NiriPicturePreparation(isSettled: settled)
        if pictured { diff.edgeHiddenFrames[token] = pictureFrame }
        return WorkspaceLayoutPlan(
            workspaceId: workspace,
            monitor: LayoutMonitorSnapshot(
                monitorId: .init(displayId: 1), displayId: 1, frame: frame, visibleFrame: frame,
                workingFrame: frame, fullscreenLayoutFrame: frame, scale: scale, orientation: orientation
            ),
            sessionPatch: .init(workspaceId: workspace), diff: diff, isAnimationTick: !settled
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
