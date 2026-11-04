// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriEdgePictureStreamTests: XCTestCase {
    func testRestingStreamStartsOnceWithoutFurtherStillCaptures() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        let preparation = try XCTUnwrap(driver.preparations.first)
        XCTAssertEqual(preparation.request.pixelWidth, Int(driver.display.width * driver.scale))
        XCTAssertEqual(preparation.request.pixelHeight, Int(driver.display.height * driver.scale))
        let control = try await driver.running(presenter)
        let captures = driver.captures.count
        presenter.reconcile(driver.plan())
        presenter.reconcileLiveStreams()
        XCTAssertEqual(driver.preparations.count, driver.controls.count)
        XCTAssertEqual(driver.captures.count, captures)
        XCTAssertEqual(control.stops, 0)
    }

    func testThresholdStripRunsCoveredStopsAndUncoverRestartsOnceWithoutAPlan() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter, visibleHeight: NiriEdgePictures.minimumLivePictureHeight)
        let first = try await driver.running(presenter)
        let surface = try XCTUnwrap(driver.surfaces.first)
        XCTAssertEqual(surface.geometry?.visibleFrame.height, NiriEdgePictures.minimumLivePictureHeight)
        surface.visible(false)
        XCTAssertEqual(first.stops, 1)
        XCTAssertTrue(surface.content?.image === still)
        let before = driver.preparations.count
        surface.visible(true)
        surface.visible(true)
        XCTAssertEqual(driver.preparations.count, before + 1)
        _ = try await driver.running(presenter)
    }

    func testMotionCoalescesNewestFrameAndRetainsSessionAcrossOcclusion() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        let control = try await driver.running(presenter)
        let picture = try XCTUnwrap(presenter.pictures[driver.token])
        let session = try XCTUnwrap(picture.stream)
        let output = try XCTUnwrap(session.output)
        let surface = try XCTUnwrap(driver.surfaces.first)
        presenter.reconcile(driver.plan(settled: false))
        surface.visible(false)
        let first = try makeOverviewPreviewFrame()
        let newest = try makeOverviewPreviewFrame()
        output.offer(first)
        presenter.deliverStreamFrame(session, picture: picture)
        output.offer(newest)
        presenter.deliverStreamFrame(session, picture: picture)
        XCTAssertTrue(surface.publications.isEmpty)
        XCTAssertTrue(surface.content?.image === still)
        XCTAssertEqual(control.stops, 0)
        surface.visible(true)
        presenter.reconcile(driver.plan())
        XCTAssertEqual(surface.publications.count, 1)
        XCTAssertTrue(surface.publications.first === newest)
        XCTAssertTrue(picture.stream === session)
        presenter.reconcile(driver.plan(settled: false))
        XCTAssertTrue(surface.content?.preview === newest)
    }

    func testDiscoveryCompletionDuringMotionDoesNotConstructOrStartUntilSettled() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        presenter.reconcile(driver.plan(settled: false))
        let control = try driver.prepared()
        XCTAssertTrue(driver.controls.isEmpty)
        presenter.reconcile(driver.plan())
        await driver.started(control)
        control.finish()
        await presenter.pictures[driver.token]?.stream?.startTask?.value
    }

    func testSizeChangeReplacesStreamOnlyAtSettlement() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        let first = try await driver.running(presenter)
        let preparations = driver.preparations.count
        let size = CGSize(width: driver.display.width, height: driver.display.height / 2)
        presenter.reconcile(driver.plan(settled: false, size: size))
        XCTAssertEqual(driver.preparations.count, preparations)
        XCTAssertEqual(first.stops, 0)
        presenter.reconcile(driver.plan(size: size))
        XCTAssertEqual(first.stops, 1)
        let request = try XCTUnwrap(driver.preparations.last?.request)
        XCTAssertEqual(request.pixelHeight, Int(size.height * driver.scale))
        _ = try await driver.running(presenter)
    }

    func testStartFailureKeepsStillAndDoesNotRetryEachSettledPlan() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        let control = try driver.prepared()
        await driver.started(control)
        let task = presenter.pictures[driver.token]?.stream?.startTask
        control.finish(NiriPictureStreamTestDriver.Failure.requested)
        await task?.value
        let preparations = driver.preparations.count
        presenter.reconcile(driver.plan())
        presenter.reconcileLiveStreams()
        XCTAssertEqual(driver.preparations.count, preparations)
        XCTAssertTrue(driver.surfaces.first?.content?.image === still)
        XCTAssertEqual(control.stops, 1)
    }

    func testSourceFailureKeepsLatestPreviewAndRejectsFurtherFrames() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        let control = try await driver.running(presenter)
        let picture = try XCTUnwrap(presenter.pictures[driver.token])
        let session = try XCTUnwrap(picture.stream)
        let preview = try makeOverviewPreviewFrame()
        session.output?.offer(preview)
        presenter.deliverStreamFrame(session, picture: picture)
        presenter.streamFailed(session, picture: picture)
        session.output?.offer(try makeOverviewPreviewFrame())
        presenter.reconcile(driver.plan())
        XCTAssertTrue(picture.content?.preview === preview)
        XCTAssertEqual(driver.preparations.count, driver.controls.count)
        XCTAssertEqual(control.stops, 1)
    }

    func testRetirementRejectsLateDiscoveryAndLateSuccessfulStart() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        presenter.reconcile(driver.plan(pictured: false))
        _ = try driver.prepared()
        XCTAssertTrue(driver.controls.isEmpty)
        _ = try driver.mount(presenter)
        let control = try driver.prepared()
        await driver.started(control)
        let start = presenter.pictures[driver.token]?.stream?.startTask
        presenter.reconcile(driver.plan(pictured: false))
        let stopsBeforeCompletion = control.stops
        control.finish()
        await start?.value
        XCTAssertEqual(control.stops, stopsBeforeCompletion + 1)
        XCTAssertTrue(presenter.pictures.isEmpty)
    }

    func testOverviewAndPressureStopAndResumeWithoutBlanking() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        let first = try await driver.running(presenter)
        driver.overviewOpen = true
        presenter.reconcileLiveStreams()
        XCTAssertEqual(first.stops, 1)
        XCTAssertTrue(driver.surfaces.first?.content?.image === still)
        driver.overviewOpen = false
        presenter.reconcileLiveStreams()
        let second = try await driver.running(presenter)
        presenter.handleMemoryPressure(true)
        XCTAssertEqual(second.stops, 1)
        XCTAssertTrue(driver.surfaces.first?.content?.image === still)
        presenter.handleMemoryPressure(false)
        _ = try await driver.running(presenter)
    }

    func testPermissionAndContextRemovalStopSessionsAndRejectStaleContent() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        _ = try driver.mount(presenter)
        let control = try await driver.running(presenter)
        let picture = try XCTUnwrap(presenter.pictures[driver.token])
        let session = try XCTUnwrap(picture.stream)
        driver.eligible = false
        presenter.reconcileLiveStreams()
        XCTAssertEqual(control.stops, 1)
        session.output?.offer(try makeOverviewPreviewFrame())
        presenter.deliverStreamFrame(session, picture: picture)
        XCTAssertNil(picture.content?.preview)
        presenter.retainCurrentContexts { _, _, _, _ in false }
        XCTAssertTrue(presenter.pictures.isEmpty)
    }

    func testNativeOutputNotificationPublishesWithoutCopyAndLateStillCannotReplaceIt() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        _ = try await driver.running(presenter)
        let surface = try XCTUnwrap(driver.surfaces.first)
        let published = expectation(description: "Stream frame published")
        surface.onPublication = { published.fulfill() }
        let preview = try makeOverviewPreviewFrame()
        let picture = try XCTUnwrap(presenter.pictures[driver.token])
        picture.stream?.output?.offer(preview)
        await fulfillment(of: [published], timeout: driver.failureDeadline)
        XCTAssertTrue(surface.content?.preview === preview)
        try XCTUnwrap(driver.captures.last)(still)
        XCTAssertTrue(surface.content?.preview === preview)
        XCTAssertTrue(picture.content?.preview === preview)
    }

    func testDiscoveryFailureStaysLatchedAcrossSettledPlans() throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        try XCTUnwrap(driver.preparations.last).complete(nil)
        let preparations = driver.preparations.count
        presenter.reconcile(driver.plan())
        presenter.reconcileLiveStreams()
        XCTAssertEqual(driver.preparations.count, preparations)
        XCTAssertTrue(driver.controls.isEmpty)
        XCTAssertTrue(driver.surfaces.first?.content?.image === still)
    }

    func testConstructionFailureStaysLatchedAcrossSettledPlans() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        try XCTUnwrap(driver.preparations.last).complete { throw NiriPictureStreamTestDriver.Failure.requested }
        await presenter.pictures[driver.token]?.stream?.startTask?.value
        let preparations = driver.preparations.count
        presenter.reconcile(driver.plan())
        presenter.reconcileLiveStreams()
        XCTAssertEqual(driver.preparations.count, preparations)
        XCTAssertTrue(driver.controls.isEmpty)
        XCTAssertTrue(driver.surfaces.first?.content?.image === still)
    }

    func testScaleChangeRetiresOldStreamAndUsesNewPixelDimensions() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let still = try driver.mount(presenter)
        let control = try await driver.running(presenter)
        let previous = try XCTUnwrap(driver.preparations.last)
        driver.scale *= 2
        presenter.reconcile(driver.plan())
        XCTAssertEqual(control.stops, 1)
        previous.output.offer(try makeOverviewPreviewFrame())
        try XCTUnwrap(driver.captures.last)(still)
        let request = try XCTUnwrap(driver.preparations.last?.request)
        XCTAssertEqual(request.pixelWidth, Int(driver.display.width * driver.scale))
        XCTAssertEqual(request.pixelHeight, Int(driver.display.height * driver.scale))
        XCTAssertNil(presenter.pictures[driver.token]?.content?.preview)
        _ = try await driver.running(presenter)
    }

    func testDeinitStopsRunningSession() async throws {
        let driver = NiriPictureStreamTestDriver()
        var presenter: NiriEdgePictures? = driver.presenter()
        _ = try driver.mount(try XCTUnwrap(presenter))
        let control = try await driver.running(try XCTUnwrap(presenter))
        presenter = nil
        XCTAssertEqual(control.stops, 1)
    }
}
