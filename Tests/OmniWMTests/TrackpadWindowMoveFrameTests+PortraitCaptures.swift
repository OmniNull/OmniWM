// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension TrackpadWindowMoveFrameTests {
    @MainActor
    private final class PendingImages {
        var completions: [WindowToken: @MainActor (CGImage?) -> Void] = [:]

        func capture(_ token: WindowToken, completion: @escaping @MainActor (CGImage?) -> Void) -> Task<Void, Never>? {
            completions[token] = completion
            return nil
        }

        func complete(_ token: WindowToken) throws {
            let grayscalePixel = try XCTUnwrap(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: UInt8.bitWidth,
                bytesPerRow: MemoryLayout<UInt8>.size, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            try XCTUnwrap(completions.removeValue(forKey: token))(grayscalePixel.makeImage())
        }
    }

    private func beginPortraitCarryWithTwoPendingCaptures() throws -> (Fixture, PendingImages) {
        let windowCount = 2
        let fixture = try makeMoveFixture(
            .vertical,
            windows: windowCount,
            firstWindowId: Int(CGWindowID.max) - windowCount
        )
        let controller = fixture.controller
        let images = PendingImages()
        let pictures = NiriEdgePictures(
            capture: images.capture, makeSurface: { NiriPictureStreamTestDriver.Surface() }, activate: { _, _ in }
        )
        controller.niriEdgePictures = pictures
        controller.hasStartedServices = true
        let refresh = controller.layoutRefreshController
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        startSettledCarry(fixture)
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds + 1)
        pictures.reset()
        images.completions.removeAll()
        let start = fixture.expectedFloatingFrame(at: fixture.slideWithinStartingWindow(1 / 4))
        let frames = [fixture.moved: start, fixture.target: fixture.targetFrame]
        let orientation = controller.settings.monitors.effectiveOrientation(for: fixture.monitor)
        let plan = WorkspaceLayoutPlan(
            workspaceId: fixture.workspace, monitor: refresh.buildMonitorSnapshot(
                for: fixture.monitor,
                orientation: orientation
            ),
            sessionPatch: .init(workspaceId: fixture.workspace),
            diff: .init(
                frameChanges: frames.map { .init(token: $0.key, frame: $0.value, forceApply: false) },
                picturePreparation: .init(isSettled: true, warmCandidates: frames.mapValues(\.size))
            )
        )
        pictures.reconcile(plan)
        XCTAssertEqual(pictures.pendingCaptures.mapValues(\.targetFrame), frames)
        controller.surfaceReconciler.reconcileNow()
        return (fixture, images)
    }

    func testPortraitCarryRetargetsOnlyTheMovingWindowAndAcceptsItsLatestFrame() throws {
        let (fixture, images) = try beginPortraitCarryWithTwoPendingCaptures()
        let pictures = fixture.controller.niriEdgePictures
        let refresh = fixture.controller.layoutRefreshController
        let surfaces = fixture.controller.surfaceReconciler
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        let fractions: [CGFloat] = [1 / 8, -1 / 8]
        var frames: [CGRect] = []
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        for fraction in fractions {
            let touch = fixture.slideWithinStartingWindow(fraction)
            let frame = fixture.expectedFloatingFrame(at: touch)
            fixture.send(fixture.event(at: touch))
            frames.append(frame)
            assertFrameSubmission(fixture.moved, frame: frame)
            XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
            XCTAssertEqual(surfaces.pendingReconcileScope, .borderOnly)
            surfaces.reconcileNow()
            XCTAssertEqual(pictures.pendingCaptures[fixture.moved]?.targetFrame, frame)
            XCTAssertEqual(pictures.pendingCaptures[fixture.target]?.targetFrame, fixture.targetFrame)
        }
        pictures.frameApplicationEnded(token: fixture.moved, targetFrame: try XCTUnwrap(frames.first))
        XCTAssertTrue(images.completions.isEmpty)
        pictures.frameApplicationEnded(token: fixture.target, targetFrame: fixture.targetFrame)
        XCTAssertEqual(Set(images.completions.keys), [fixture.target])
        pictures.frameApplicationEnded(token: fixture.moved, targetFrame: try XCTUnwrap(frames.last))
        XCTAssertEqual(Set(images.completions.keys), Set(fixture.tokens))
        for token in fixture.tokens { try images.complete(token) }
        XCTAssertEqual(pictures.readyTokens, Set(fixture.tokens))
        pictures.handleMemoryPressure(true)
        pictures.handleMemoryPressure(false)
        XCTAssertTrue(pictures.readyTokens.isEmpty)
        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds + 1)
        fixture.cancel()
    }

    func testPortraitCarryStartsTheWarmCaptureWhenAXEnforcesPositionOnly() throws {
        let (fixture, images) = try beginPortraitCarryWithTwoPendingCaptures()
        let pictures = fixture.controller.niriEdgePictures
        let refresh = fixture.controller.layoutRefreshController
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let target = fixture.expectedFloatingFrame(at: touch)
        let observed = CGRect(origin: target.origin, size: CGSize(width: target.width / 2, height: target.height))
        let ledger = fixture.controller.axManager.frameLedger
        let token = fixture.moved
        let window = try XCTUnwrap(fixture.base.manager.entry(for: token)?.axRef)
        for retry in [false, true] {
            let request = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
                ledger, pid: token.pid, window: window, frame: target, isRetry: retry
            ))
            _ = ledger.handleFrameApplyResults([
                WindowAdmissionTestSupport.verificationMismatchFrameResult(request: request, observed: observed)
            ])
        }
        XCTAssertEqual(ledger.enforcedSizePlacement(for: token.windowId, targetFrame: target), observed)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
        assertFrameSubmission(token, frame: observed)
        XCTAssertEqual(Set(images.completions.keys), [token])
        XCTAssertNil(pictures.pendingCaptures[token])
        XCTAssertEqual(pictures.pendingCaptures[fixture.target]?.targetFrame, fixture.targetFrame)
        try images.complete(token)
        XCTAssertEqual(pictures.readyTokens, [token])
        fixture.cancel()
    }
}
