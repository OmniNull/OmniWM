// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedNativeResizeTests: XCTestCase {
    private let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let initialContentSize = CGSize(width: 320, height: 240)

    func testNativeLiveResizeAdoptsTheExistingNiriAndDwindleLayoutsWithoutAX() throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try fixture(layout)
            defer { fixture.close() }
            let token = fixture.tokens[0]
            let window = fixture.windows[0]
            let start = try XCTUnwrap(fixture.frames()[token])
            XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
            let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
            fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
            var observed = start
            observed.size.width += initialContentSize.width

            window.setFrame(observed, display: false)
            fixture.controller.shellAppWindowManager.windowDidResize(callback)
            fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

            let adopted = try XCTUnwrap(fixture.frames()[token])
            XCTAssertGreaterThan(adopted.width, start.width, "\(layout)")
            XCTAssertEqual(adopted.width, observed.width, accuracy: FrameTolerance.frameWrite, "\(layout)")
            XCTAssertEqual(fixture.controller.workspaceManager.entry(for: token)?.observedState.frame, observed)
            XCTAssertEqual(fixture.controller.workspaceManager.entry(for: token)?.mode, .tiling)
            XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
            XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
            XCTAssertNil(fixture.controller.mouseEventHandler.state.nativeTitleBarDrag)
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        }
    }

    func testOnALandscapeStripANativeLiveResizeIsAdopted() throws {
        for centred in [false, true] {
            let fixture = try fixture(.niri)
            defer { fixture.close() }
            let token = fixture.tokens[0]
            let window = fixture.windows[0]
            let start = try XCTUnwrap(fixture.frames()[token])
            XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
            let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
            fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
            let growth = initialContentSize.width
            let observed = centred
                ? start.insetBy(dx: -growth / 2, dy: 0)
                : CGRect(x: start.minX, y: start.minY, width: start.width + growth, height: start.height)

            window.setFrame(observed, display: false)
            fixture.controller.shellAppWindowManager.windowDidResize(callback)
            fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

            let adopted = try XCTUnwrap(fixture.frames()[token])
            XCTAssertEqual(adopted.width, observed.width, accuracy: FrameTolerance.frameWrite, "\(centred)")
        }
    }

    func testPortraitPrimaryNativeLiveResizesAdopt() throws {
        let changes: [(top: Bool, centred: Bool, direction: CGFloat)] = [
            (false, false, 1), (true, false, 1), (true, true, 1), (true, true, -1)
        ]
        for change in changes {
            let fixture = try fixture(.niri, portrait: true)
            defer { fixture.close() }
            fixture.controller.motionPolicy.animationsEnabled = false
            let engine = try XCTUnwrap(fixture.controller.niriEngine)
            fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspace) { _ in
                for column in engine.columns(in: fixture.workspace) {
                    column.height = .proportion(1.0 / 3.0)
                    column.cachedHeight = 0
                }
            }
            let token = fixture.tokens[1]
            let window = fixture.windows[1]
            let start = try XCTUnwrap(fixture.frames()[token])
            XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
            let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
            fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
            let growth = change.direction * initialContentSize.height / 4
            let observed = CGRect(
                x: start.minX,
                y: start.minY - (change.centred ? growth / 2 : change.top ? 0 : growth),
                width: start.width,
                height: start.height + growth
            )

            window.setFrame(observed, display: false)
            fixture.controller.shellAppWindowManager.windowDidResize(callback)
            fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

            let adopted = try XCTUnwrap(fixture.frames()[token])
            XCTAssertEqual(adopted.height, observed.height, accuracy: FrameTolerance.frameWrite, "\(change)")
            XCTAssertEqual(adopted.width, start.width, accuracy: FrameTolerance.frameWrite, "\(change)")
            if change.centred {
                XCTAssertEqual(adopted.midY, start.midY, accuracy: FrameTolerance.frameWrite, "\(change)")
            } else {
                XCTAssertEqual(
                    change.top ? adopted.minY : adopted.maxY,
                    change.top ? start.minY : start.maxY,
                    accuracy: FrameTolerance.frameWrite,
                    "\(change)"
                )
            }
            XCTAssertEqual(fixture.controller.workspaceManager.entry(for: token)?.observedState.frame, observed)
            XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
            XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
            XCTAssertNil(fixture.controller.mouseEventHandler.state.nativeTitleBarDrag)
        }
    }

    func testPortraitSecondaryAndMixedNativeLiveResizesAdoptWithoutTheLegacySetting() throws {
        let changes: [(leading: Bool, centred: Bool, corner: Bool)] = [
            (false, false, false), (true, false, false), (false, true, false),
            (false, false, true), (false, true, true)
        ]
        for change in changes {
            let fixture = try fixture(.niri, portrait: true)
            defer { fixture.close() }
            fixture.controller.motionPolicy.animationsEnabled = false
            let engine = try XCTUnwrap(fixture.controller.niriEngine)
            let token = fixture.tokens[1]
            let node = try XCTUnwrap(engine.findNode(for: token, in: fixture.workspace))
            let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
            fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspace) { _ in
                for column in engine.columns(in: fixture.workspace) {
                    column.height = .proportion(1.0 / 3.0)
                    column.cachedHeight = 0
                }
                engine.setWindowSecondarySpan(
                    node, change: .setFixed(workingFrame.width / 2), in: fixture.workspace,
                    geometry: .init(
                        workingFrame: workingFrame,
                        gaps: fixture.controller.innerGap(for: fixture.monitor),
                        orientation: .vertical
                    )
                )
            }
            let window = fixture.windows[1]
            let start = try XCTUnwrap(fixture.frames()[token])
            XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
            let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
            fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
            let growth = initialContentSize.width / 4
            let heightGrowth = change.corner ? initialContentSize.height / 4 : 0
            let observed = CGRect(
                x: start.minX - (change.centred ? growth / 2 : change.leading ? growth : 0),
                y: start.minY - (change.centred ? heightGrowth / 2 : 0),
                width: start.width + growth,
                height: start.height + heightGrowth
            )
            window.setFrame(observed, display: false)
            fixture.controller.shellAppWindowManager.windowDidResize(callback)
            fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

            let adopted = try XCTUnwrap(fixture.frames()[token])
            XCTAssertEqual(adopted.width, start.width + growth, accuracy: FrameTolerance.frameWrite, "\(change)")
            XCTAssertEqual(
                adopted.height,
                start.height + heightGrowth,
                accuracy: FrameTolerance.frameWrite,
                "\(change)"
            )
            if change.corner {
                XCTAssertEqual(
                    change.centred ? adopted.midY : adopted.minY,
                    change.centred ? start.midY : start.minY,
                    accuracy: FrameTolerance.frameWrite,
                    "\(change)"
                )
            }
            XCTAssertEqual(fixture.controller.workspaceManager.entry(for: token)?.observedState.frame, observed)
            XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
            XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
            XCTAssertNil(fixture.controller.mouseEventHandler.state.nativeTitleBarDrag)
        }
    }

    func testDwindleNativeResizeAdoptsTheSharedSplit() throws {
        let fixture = try fixture(.dwindle)
        defer { fixture.close() }
        let token = fixture.tokens[0]
        let window = fixture.windows[0]
        let before = try fixture.frames()
        let start = try XCTUnwrap(before[token])
        XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
        let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
        fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
        var observed = start
        observed.size.width += initialContentSize.width
        var expectedFrames = before
        expectedFrames[token] = observed
        let neighbor = fixture.tokens[1]
        var neighborFrame = try XCTUnwrap(before[neighbor])
        neighborFrame.origin.x += initialContentSize.width
        neighborFrame.size.width -= initialContentSize.width
        expectedFrames[neighbor] = neighborFrame
        window.setFrame(observed, display: false)
        fixture.controller.shellAppWindowManager.windowDidResize(callback)

        fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

        XCTAssertEqual(try fixture.frames(), expectedFrames)
        XCTAssertEqual(
            (fixture.controller.layoutRefreshController.layoutState.pendingRefresh
                ?? fixture.controller.layoutRefreshController.layoutState.activeRefresh)?.affectedWorkspaceIds,
            []
        )
        XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
    }

    func testDwindleHostedCenteredResizeUsesTheNativeLifecycleWithoutPointerState() throws {
        let fixture = try fixture(.dwindle)
        defer { fixture.close() }
        fixture.controller.motionPolicy.animationsEnabled = false
        let extra = makeWindow()
        defer { extra.close() }
        let right = try XCTUnwrap(fixture.controller.shellAppWindowManager.admit(
            extra,
            metadata: HostedWindowMetadata(appId: "resize", title: "Right", minimumSize: initialContentSize),
            to: fixture.workspace
        ))
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let token = fixture.tokens[1]
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspace) {
            engine.setSelectedNode(engine.findNode(for: token, in: fixture.workspace), in: fixture.workspace)
            _ = engine.setPreselection(.right, in: fixture.workspace)
            _ = engine.addWindow(token: right, to: fixture.workspace, activeWindowFrame: nil)
        }
        engine.cancelAnimations(in: fixture.workspace)
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let settings = fixture.controller.dwindleLayoutHandler.calculationSettings(
            fixture.controller.resolvedDwindleSettings(for: fixture.monitor), from: engine
        )
        let fraction = settings.ratioToFraction(settings.defaultSplitRatio)
        let leftWidth = area.width * fraction
        let middleWidth = (area.width - leftWidth) * fraction
        let growth = area.width / 32
        func frames(halfGrowth: CGFloat) -> [WindowToken: CGRect] {
            let branchWidth = area.width - leftWidth + halfGrowth
            let targetWidth = middleWidth + 2 * halfGrowth
            let outer = engine.splitRect(
                area, orientation: .horizontal, ratio: 2 * (1 - branchWidth / area.width),
                minimums: (.zero, .zero), settings: settings
            )
            let inner = engine.splitRect(
                outer.1, orientation: .horizontal, ratio: 2 * targetWidth / branchWidth,
                minimums: (.zero, .zero), settings: settings
            )
            return Dictionary(uniqueKeysWithValues: zip([fixture.tokens[0], token, right], [outer.0, inner.0, inner.1])
                .map {
                    ($0, DwindleGapCalculator.applyGaps(nodeRect: $1, tilingArea: area, settings: settings))
                })
        }
        let original = frames(halfGrowth: 0)
        XCTAssertEqual(try fixture.frames(), original)
        let start = try XCTUnwrap(original[token])
        let window = fixture.windows[1]
        XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
        let nativeStart = window.frame
        let notification = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
        fixture.controller.shellAppWindowManager.windowWillStartLiveResize(notification)
        window.setFrame(start.insetBy(dx: -growth, dy: 0), display: false)
        let nativeObserved = window.frame
        XCTAssertGreaterThan(nativeObserved.width, nativeStart.width)
        fixture.controller.shellAppWindowManager.windowDidResize(notification)
        fixture.controller.shellAppWindowManager.windowDidEndLiveResize(notification)

        let actual = try fixture.frames()
        XCTAssertEqual(actual, frames(halfGrowth: nativeStart.minX - nativeObserved.minX))
        XCTAssertEqual(actual[token]?.midX, start.midX)
        XCTAssertEqual(fixture.controller.workspaceManager.entry(for: token)?.observedState.frame, nativeObserved)
        XCTAssertNil(fixture.controller.mouseEventHandler.state.leftPressLocation)
        XCTAssertNil(fixture.controller.mouseEventHandler.state.nativeTitleBarDrag)
        XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
        XCTAssertNil(engine.interactiveResize)
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
    }

    @MainActor
    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspace: WorkspaceDescriptor.ID
        let windows: [NSWindow]
        let tokens: [WindowToken]

        func frames() throws -> [WindowToken: CGRect] {
            let frame = controller.insetWorkingFrame(for: monitor)
            switch controller.workspaceManager.activeLayoutKind(for: workspace) {
            case .niri:
                let gap = controller.innerGap(for: monitor)
                return try XCTUnwrap(controller.niriEngine).calculateLayout(
                    state: controller.workspaceManager.niriViewportState(for: workspace), workspaceId: workspace,
                    monitorFrame: frame, gaps: (horizontal: gap, vertical: gap),
                    orientation: controller.settings.monitors.effectiveOrientation(for: monitor)
                )
            case .dwindle:
                let engine = try XCTUnwrap(controller.dwindleEngine)
                return engine.calculateLayout(
                    for: workspace, screen: frame,
                    calculationSettings: controller.dwindleLayoutHandler.calculationSettings(
                        controller.resolvedDwindleSettings(for: monitor), from: engine
                    )
                )
            }
        }

        func close() {
            for window in windows { window.close() }
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
    }

    private func fixture(_ layout: LayoutType, portrait: Bool = false) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedNativeResize")
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        let display = CGDirectDisplayID.max
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: displayFrame, visibleFrame: displayFrame,
            hasNotch: false, name: "Hosted Native Resize"
        )
        if portrait {
            controller.settings.monitors.updateOrientationSettings(
                MonitorOrientationSettings(
                    monitorName: monitor.name,
                    monitorDisplayId: monitor.displayId,
                    orientation: .vertical
                ),
                for: monitor
            )
        }
        controller.settings.workspaces.configurations = [WorkspaceConfiguration(
            name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: layout
        )]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let windows = [makeWindow(), makeWindow()]
        let metadata = HostedWindowMetadata(appId: "resize", title: "Resize", minimumSize: initialContentSize)
        let tokens = try windows.map { window in
            try XCTUnwrap(controller.shellAppWindowManager.admit(window, metadata: metadata, to: workspace))
        }
        if layout == .niri {
            controller.enableNiriLayout()
            let engine = try XCTUnwrap(controller.niriEngine)
            let first = engine.addWindow(token: tokens[0], to: workspace, afterSelection: nil)
            _ = engine.addWindow(token: tokens[1], to: workspace, afterSelection: first.id)
        } else {
            controller.enableDwindleLayout()
            let engine = try XCTUnwrap(controller.dwindleEngine)
            controller.workspaceManager.withEngineMutationScope(in: workspace) {
                for token in tokens {
                    _ = engine.setPreselection(.right, in: workspace)
                    _ = engine.addWindow(token: token, to: workspace, activeWindowFrame: nil)
                }
            }
            engine.cancelAnimations(in: workspace)
        }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        return Fixture(controller: controller, monitor: monitor, workspace: workspace, windows: windows, tokens: tokens)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: initialContentSize), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
