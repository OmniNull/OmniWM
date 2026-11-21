// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DisplayConfigurationTransientSampleTests: XCTestCase {
    private var sampledMonitors: [Monitor] = []

    func testStartingObservationReconcilesMenuBarInsetThatSettledAfterServiceStart() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DisplayConfigurationTransientSampleTests")
        let lifecycle = controller.serviceLifecycleManager
        let withMenuBar = makeMonitor(displayId: 1, name: "External", originX: 0, width: 1440, menuBarHeight: 30)
        let withoutMenuBar = makeMonitor(displayId: 1, name: "External", originX: 0, width: 1440)
        let bar = controller.settings.workspaceBar
        bar.position = .left
        bar.fullWidth = true
        controller.settings.gaps.outerGapTop = 0
        controller.settings.borders.enabled = false

        lifecycle.monitorConfiguration.refreshForServiceStart(currentMonitors: [withMenuBar])
        XCTAssertEqual(controller.workspaceManager.monitors, [withMenuBar])
        lifecycle.monitorConfiguration.currentMonitorsProvider = { [withoutMenuBar] }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer {
            lifecycle.monitorConfiguration.stopObserving()
            lifecycle.topologyInventory.cancel()
            controller.eventIntake.close()
            controller.layoutRefreshController.resetState()
        }

        lifecycle.monitorConfiguration.startObserving()
        controller.eventIntake.drainNow()

        let monitor = try XCTUnwrap(controller.workspaceManager.monitors.first)
        XCTAssertEqual(monitor.visibleFrame, withoutMenuBar.frame)
        let resolved = bar.resolved(for: monitor)
        let barFrame = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            .frame(fittingLength: 100, monitor: monitor, resolved: resolved)
        XCTAssertEqual(barFrame.height, withoutMenuBar.frame.height)
        XCTAssertEqual(controller.layoutFrames(for: monitor, scale: 1).workingFrame.maxY, withoutMenuBar.frame.maxY)
    }

    func testTransientUnusableResampleDoesNotTearDownPresentMonitor() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DisplayConfigurationTransientSampleTests")
        let manager = controller.serviceLifecycleManager
        defer { controller.layoutRefreshController.resetState() }
        manager.topologyInventory.sampleProvider = { nil }
        manager.topologyInventory.sleeper = { _ in await Task.yield() }

        let first = makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440)
        let second = makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440)
        controller.workspaceManager.applyMonitorConfigurationChange([first, second])
        controller.niriLayoutHandler.enableNiriLayout()
        controller.syncMonitorsToNiriEngine()
        let niriSecond = try XCTUnwrap(controller.niriEngine?.monitor(for: second.id))
        let seq = controller.workspaceManager.worldSeq

        manager.monitorConfiguration.currentMonitorsProvider = { [
            first,
            self.makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1)
        ] }
        manager.monitorConfiguration.handle(.disconnected(second.id))

        XCTAssertTrue(controller.niriEngine?.monitor(for: second.id) === niriSecond)
        XCTAssertEqual(controller.workspaceManager.monitors, [first, second])
        XCTAssertEqual(controller.workspaceManager.worldSeq, seq)

        let moved = makeMonitor(displayId: 2, name: "Second", originX: 1540, width: 1440)
        manager.monitorConfiguration.currentMonitorsProvider = { [first, moved] }
        manager.monitorConfiguration.handle(.reconfigured(moved))

        XCTAssertEqual(controller.workspaceManager.monitors, [first, moved])
        XCTAssertNotNil(controller.niriEngine?.monitor(for: second.id))
        XCTAssertGreaterThan(controller.workspaceManager.worldSeq, seq)
    }

    func testObserverIgnoresUnusableSampleAsBaseline() {
        let first = makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440)
        let second = makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440)
        sampledMonitors = [first, second]
        let observer = DisplayConfigurationObserver(initialMonitors: sampledMonitors) { self.sampledMonitors }
        var events: [DisplayConfigurationObserver.DisplayEvent] = []
        observer.setEventHandler { events.append($0) }

        sampledMonitors = [makeMonitor(displayId: 1, name: "First", originX: 0, width: 1), second]
        observer.sampleNow()
        sampledMonitors = [first, second]
        observer.sampleNow()

        XCTAssertTrue(events.isEmpty)
    }

    func testSafeApertureChangeResamplesNotchMetadata() async {
        let plain = makeMonitor(displayId: 1, name: "Built-in", originX: 0, width: 1512)
        let notched = makeMonitor(displayId: 1, name: "Built-in", originX: 0, width: 1512, notchRange: 666 ... 846)
        let external = makeMonitor(displayId: 2, name: "External", originX: 1512, width: 1440)
        sampledMonitors = [plain, external]
        let observer = DisplayConfigurationObserver(initialMonitors: sampledMonitors) { self.sampledMonitors }
        var reconfigured: [Monitor] = []
        var resampled: XCTestExpectation?
        observer.setEventHandler { event in
            guard case let .reconfigured(monitor) = event else {
                XCTFail("Unexpected display event \(event)")
                return
            }
            reconfigured.append(monitor)
            resampled?.fulfill()
        }

        for builtIn in [notched, plain] {
            sampledMonitors = [builtIn, external]
            let notified = expectation(description: "Resampled after safe aperture change")
            resampled = notified
            NotificationCenter.default.post(name: .screenSafeApertureDidChange, object: nil)
            await fulfillment(of: [notified], timeout: failureBound)
        }
        observer.sampleNow()

        XCTAssertEqual(reconfigured, [notched, plain])
    }

    func testObserverReportsMainDisplaySwapWithUnchangedGeometry() {
        sampledMonitors = [
            makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440, isMain: true),
            makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440, isMain: false)
        ]
        let observer = DisplayConfigurationObserver(initialMonitors: sampledMonitors) { self.sampledMonitors }
        var reconfigured: [Monitor] = []
        observer.setEventHandler { event in
            guard case let .reconfigured(monitor) = event else {
                XCTFail("Unexpected display event \(event)")
                return
            }
            reconfigured.append(monitor)
        }
        let swapped = [
            makeMonitor(displayId: 1, name: "First", originX: 0, width: 1440, isMain: false),
            makeMonitor(displayId: 2, name: "Second", originX: 1440, width: 1440, isMain: true)
        ]

        sampledMonitors = swapped
        observer.sampleNow()
        observer.sampleNow()

        XCTAssertEqual(reconfigured.sorted { $0.displayId < $1.displayId }, swapped)
    }

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        originX: CGFloat,
        width: CGFloat,
        notchRange: ClosedRange<CGFloat>? = nil,
        isMain: Bool? = nil,
        menuBarHeight: CGFloat = 0
    ) -> Monitor {
        let frame = CGRect(x: originX, y: 0, width: width, height: 900)
        return Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: CGRect(x: originX, y: 0, width: width, height: frame.height - menuBarHeight),
            hasNotch: notchRange != nil,
            notchRange: notchRange,
            name: name,
            isMain: isMain
        )
    }
}
