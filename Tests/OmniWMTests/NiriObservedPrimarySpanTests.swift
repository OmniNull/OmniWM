// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriObservedPrimarySpanTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
    private let observed = CGRect(x: 100, y: 100, width: 360, height: 240)
    private let gap: CGFloat = 12
    private let defaultSpan: CGFloat = 0.5

    func testKeptSizeUsesThePrimaryAxisAndCapsItToThatAxis() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        engine.defaultContainerPrimarySpan = defaultSpan
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            let available = orientation == .horizontal ? frame.width : frame.height
            let requested = orientation == .horizontal ? observed.width : observed.height
            for span in [requested, available * 2] {
                let result = try XCTUnwrap(engine.keptContainerSizingState(
                    primarySpan: span,
                    in: workspaceId,
                    workingSpan: available,
                    gaps: gap,
                    orientation: orientation
                ))
                let fixed = ProportionalSize.fixed(min(span, available - gap * 2))
                XCTAssertEqual(orientation == .horizontal ? result.width : result.height, fixed)
                XCTAssertEqual(
                    orientation == .horizontal ? result.height : result.width,
                    .proportion(defaultSpan)
                )
                XCTAssertNil(result.presetWidthIndex)
                XCTAssertFalse(result.isFullWidth)
                XCTAssertFalse(result.isFullHeight)
            }
        }
    }

    func testAppSizeModeControlsNewWindowAdmissionOnBothAxes() throws {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            for enabled in [false, true] {
                let result = try admittedSizing(orientation: orientation, opening: true, enabled: enabled)
                let span = orientation == .horizontal ? observed.width : observed.height
                XCTAssertEqual(
                    orientation == .horizontal ? result.width : result.height,
                    enabled ? .fixed(span) : .proportion(defaultSpan)
                )
            }
        }
    }

    func testKeepExistingSizeControlsExistingWindowAdmissionOnBothAxes() throws {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            for enabled in [false, true] {
                let result = try admittedSizing(orientation: orientation, opening: false, enabled: enabled)
                let span = orientation == .horizontal ? observed.width : observed.height
                XCTAssertEqual(
                    orientation == .horizontal ? result.width : result.height,
                    enabled ? .fixed(span) : .proportion(defaultSpan)
                )
            }
        }
    }

    func testAnOpeningRuleWinsOverAppSizeOnBothAxes() throws {
        let rule = defaultSpan / 2
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            let result = try admittedSizing(orientation: orientation, opening: true, enabled: true, rule: rule)
            XCTAssertEqual(result.width, .proportion(rule))
            XCTAssertEqual(result.height, .proportion(rule))
        }
    }

    private func admittedSizing(
        orientation: Monitor.Orientation,
        opening: Bool,
        enabled: Bool,
        rule: CGFloat? = nil
    ) throws -> NiriContainerSizingState {
        _ = NSApplication.shared
        let native = NSWindow(contentRect: observed, styleMask: .borderless, backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.alphaValue = 0
        native.orderBack(nil)
        native.displayIfNeeded()
        CATransaction.flush()
        let sky = SkyLight.shared
        let transaction = try XCTUnwrap(sky.transactions.transactionCreate(sky.getMainConnectionID())?
            .takeRetainedValue())
        let synchronous: Int32 = 1
        sky.transactions.transactionCommit(transaction, synchronous)
        defer { native.close() }
        XCTAssertEqual(native.frame, observed)
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriObservedPrimarySpanTests")
        controller.settings.niri.defaultContainerPrimarySpan = Double(defaultSpan)
        controller.settings.niri.opensNewWindowsAtAppWidth = opening ? enabled : true
        controller.settings.niri.keepExistingWindowWidth = opening ? true : enabled
        let monitor = Monitor(
            id: .init(displayId: 78_311), displayId: 78_311,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Observed primary span"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.settings.monitors.updateOrientationSettings(
            MonitorOrientationSettings(
                monitorName: monitor.name, monitorDisplayId: monitor.displayId, orientation: orientation
            ),
            for: monitor
        )
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: native.windowNumber),
            pid: getpid(),
            windowId: native.windowNumber,
            to: workspaceId,
            admissionHints: ManagedWindowAdmissionHints(initialNiriContainerPrimarySpan: rule.map(Double.init))
        )
        XCTAssertNil(engine.findNode(for: token, in: workspaceId))
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(try XCTUnwrap(controller.axEventHandler.observedFrame(for: entry)), observed)
        XCTAssertEqual(engine.effectiveSettings(in: workspaceId).opensNewWindowsAtAppWidth, opening ? enabled : true)
        if opening { engine.noteOpeningWindow(token) }
        let pass = NiriLayoutHandler.NiriLayoutPass(
            motion: .disabled, wsId: workspaceId, engine: engine, monitor: monitor,
            orientation: orientation, insetFrame: frame, gap: gap, windows: [], windowTokens: [token]
        )
        controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.syncWindowsAndInstallConstraints(
                pass: pass, selectedNodeId: nil, preferredFocusToken: nil
            )
        }
        return try XCTUnwrap(engine.containerSizingState(for: token, in: workspaceId))
    }
}
