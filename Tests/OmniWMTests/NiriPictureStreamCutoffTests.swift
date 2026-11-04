// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriPictureStreamCutoffTests: XCTestCase {
    func testSubthresholdStillStaysClickableAndGrowthStartsWithoutVisibilityEvent() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let threshold = NiriEdgePictures.minimumLivePictureHeight
        let short = threshold - 1 / driver.scale
        let still = try driver.mount(presenter, visibleHeight: short)
        let surface = try XCTUnwrap(driver.surfaces.first)
        XCTAssertEqual(surface.geometry?.visibleFrame.height, short)
        XCTAssertTrue(surface.content?.image === still)
        XCTAssertTrue(driver.preparations.isEmpty)
        surface.activate?()
        XCTAssertEqual(driver.activations, [driver.token])
        presenter.reconcile(driver.plan(settled: false, visibleHeight: threshold))
        XCTAssertTrue(driver.preparations.isEmpty)
        presenter.reconcile(driver.plan(visibleHeight: threshold))
        _ = try await driver.running(presenter)
        let preparations = driver.preparations.count
        presenter.reconcile(driver.plan(visibleHeight: threshold + 1 / driver.scale))
        XCTAssertEqual(driver.preparations.count, preparations)
    }

    func testMovingAcrossCutoffKeepsStreamAndSettlingBelowStopsWithoutBlanking() async throws {
        let driver = NiriPictureStreamTestDriver()
        let presenter = driver.presenter()
        defer { driver.finish(presenter) }
        let threshold = NiriEdgePictures.minimumLivePictureHeight
        let short = threshold - 1 / driver.scale
        _ = try driver.mount(presenter, visibleHeight: threshold)
        let control = try await driver.running(presenter)
        let picture = try XCTUnwrap(presenter.pictures[driver.token])
        let session = try XCTUnwrap(picture.stream)
        let preview = try makeOverviewPreviewFrame()
        session.output?.offer(preview)
        presenter.deliverStreamFrame(session, picture: picture)
        let preparations = driver.preparations.count
        presenter.reconcile(driver.plan(settled: false, visibleHeight: short))
        presenter.reconcile(driver.plan(settled: false, visibleHeight: threshold))
        presenter.reconcile(driver.plan(settled: false, visibleHeight: short))
        XCTAssertEqual(control.stops, 0)
        XCTAssertEqual(driver.preparations.count, preparations)
        XCTAssertTrue(picture.stream === session)
        presenter.reconcile(driver.plan(visibleHeight: short))
        XCTAssertEqual(control.stops, 1)
        XCTAssertNil(picture.stream)
        XCTAssertTrue(driver.surfaces.first?.content?.preview === preview)
        session.output?.offer(try makeOverviewPreviewFrame())
        presenter.deliverStreamFrame(session, picture: picture)
        XCTAssertTrue(driver.surfaces.first?.content?.preview === preview)
        presenter.reconcile(driver.plan(visibleHeight: threshold))
        XCTAssertEqual(driver.preparations.count, preparations + 1)
        _ = try await driver.running(presenter)
    }
}
