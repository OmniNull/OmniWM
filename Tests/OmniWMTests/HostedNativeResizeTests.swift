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

    func testDisabledNativeResizeKeepsTheExistingLayoutAndRequestsCorrection() throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try fixture(layout)
            defer { fixture.close() }
            fixture.controller.settings.gestures.adoptNativeResize = false
            let token = fixture.tokens[0]
            let window = fixture.windows[0]
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            XCTAssertTrue(fixture.controller.shellAppWindowManager.setFrame(start, for: token))
            let callback = Notification(name: NSWindow.didEndLiveResizeNotification, object: window)
            fixture.controller.shellAppWindowManager.windowWillStartLiveResize(callback)
            var observed = start
            observed.size.width += initialContentSize.width
            window.setFrame(observed, display: false)
            fixture.controller.shellAppWindowManager.windowDidResize(callback)

            fixture.controller.shellAppWindowManager.windowDidEndLiveResize(callback)

            XCTAssertEqual(try fixture.frames(), before)
            XCTAssertEqual(
                (fixture.controller.layoutRefreshController.layoutState.pendingRefresh
                    ?? fixture.controller.layoutRefreshController.layoutState.activeRefresh)?.affectedWorkspaceIds,
                [fixture.workspace]
            )
            XCTAssertNil(fixture.controller.shellAppWindowManager.liveResizeStarts[token])
        }
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

    private func fixture(_ layout: LayoutType) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedNativeResize")
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        controller.settings.gestures.adoptNativeResize = true
        let display = CGDirectDisplayID.max
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: displayFrame, visibleFrame: displayFrame,
            hasNotch: false, name: "Hosted Native Resize"
        )
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
