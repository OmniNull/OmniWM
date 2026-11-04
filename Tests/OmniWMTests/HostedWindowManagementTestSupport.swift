// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
struct HostedManagementInstance {
    let token: WindowToken
    let window: HostedManagementWindow
    let session: ShellAppRuntime
}

@MainActor
final class HostedManagementFixture {
    let definition: ShellAppDefinition
    let controller: WMController
    let sourceMonitor: Monitor
    let destinationMonitor: Monitor
    let source: WorkspaceDescriptor.ID
    let sourceOther: WorkspaceDescriptor.ID
    let destination: WorkspaceDescriptor.ID
    let destinationOther: WorkspaceDescriptor.ID
    let external: WindowToken
    let externalFrame: CGRect
    var windows: [HostedManagementWindow] = []
    var activationCount = 0
    var manager: ShellAppWindowManager {
        controller.shellAppWindowManager
    }

    var world: WorkspaceManager {
        controller.workspaceManager
    }

    init(layout: LayoutType = .dwindle, follows: Bool = false) throws {
        definition = try XCTUnwrap(ShellAppDefinition.example)
        controller = WindowAdmissionTestSupport.controller(prefix: "HostedWindowManagement")
        controller.setAnimationsEnabled(false)
        controller.settings.focus.followsWindowToMonitor = follows
        controller.hasStartedServices = true
        let columnCapacity: CGFloat = 3
        let rowCapacity: CGFloat = 2
        let size = CGSize(
            width: definition.contentSize.width * columnCapacity,
            height: definition.contentSize.height * rowCapacity
        )
        sourceMonitor = Self.monitor(id: .max, frame: CGRect(origin: .zero, size: size))
        destinationMonitor = Self.monitor(
            id: .max - 1,
            frame: CGRect(origin: CGPoint(x: -size.width, y: .zero), size: size)
        )
        controller.settings.workspaces.defaultLayoutType = layout
        controller.settings.workspaces.configurations = [
            ("1", sourceMonitor), ("2", sourceMonitor),
            ("3", destinationMonitor), ("4", destinationMonitor)
        ].map { name, monitor in
            WorkspaceConfiguration(
                name: name, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: layout
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange([sourceMonitor, destinationMonitor])
        controller.workspaceManager.applySettings()
        source = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        sourceOther = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        destination = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "3"))
        destinationOther = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "4"))
        let niri = NiriLayoutEngine()
        niri.animationClock = controller.animationClock
        controller.niriEngine = niri
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindle = DwindleLayoutEngine()
        dwindle.animationClock = controller.animationClock
        controller.dwindleEngine = dwindle
        _ = controller.workspaceManager.setActiveWorkspace(destination, on: destinationMonitor.id)
        _ = controller.workspaceManager.setActiveWorkspace(source, on: sourceMonitor.id)
        external = WindowToken(pid: 951_001, windowId: 951_101)
        externalFrame = CGRect(origin: sourceMonitor.visibleFrame.origin, size: definition.minimumContentSize)
        let reference = WindowAdmissionTestSupport.axRef(for: external)
        _ = controller.workspaceManager.addWindow(
            reference, pid: external.pid, windowId: external.windowId, to: source, mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: externalFrame, for: external, referenceMonitor: sourceMonitor
        )
        controller.layoutRefreshController.fastFrameProvider = { [weak self] token, _ in
            guard let self else { return nil }
            return token == external ? externalFrame : manager.frame(for: token)
        }
        manager.activateApplication = { [weak self] in self?.activationCount += 1 }
        manager.focusWithoutRaising = { _ in }
        manager.makeWindow = { [weak self] definition in
            let window = HostedManagementWindow(
                contentRect: CGRect(origin: .zero, size: definition.contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentMinSize = definition.minimumContentSize
            self?.windows.append(window)
            return window
        }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
    }

    func open() throws -> HostedManagementInstance {
        XCTAssertEqual(controller.commandHandler.performCommand(.shellAppNewWindow(definition.id)), .executed)
        let window = try XCTUnwrap(windows.last)
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        return HostedManagementInstance(
            token: token,
            window: window,
            session: try XCTUnwrap(manager.runtime(for: token))
        )
    }

    func select(_ instance: HostedManagementInstance) throws {
        XCTAssertNotNil(controller.focusWindow(instance.token))
        manager.windowDidBecomeKey(notification(instance.window, name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(world.nativeManagedFocusToken, instance.token)
    }

    func float(_ instance: HostedManagementInstance) throws {
        try select(instance)
        XCTAssertEqual(controller.commandHandler.performCommand(.windowState(.toggleFloating)), .executed)
        XCTAssertEqual(world.windowMode(for: instance.token), .floating)
    }

    func moveNative(_ instance: HostedManagementInstance, to frame: CGRect) {
        instance.window.setFrame(frame, display: false)
        manager.windowDidMove(notification(instance.window, name: NSWindow.didMoveNotification))
        manager.windowDidResize(notification(instance.window, name: NSWindow.didResizeNotification))
    }

    func hide(
        _ instance: HostedManagementInstance,
        reason: LayoutRefreshController.HideReason = .workspaceInactive
    ) throws {
        let entry = try XCTUnwrap(world.entry(for: instance.token))
        let monitor = try XCTUnwrap(world.monitor(for: entry.workspaceId))
        XCTAssertTrue(controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .left,
            reason: reason
        ))
    }

    func centeredFrame(on monitor: Monitor, size: CGSize? = nil) -> CGRect {
        let size = size ?? definition.contentSize
        return CGRect(
            x: monitor.frame.midX - size.width / 2,
            y: monitor.frame.midY - size.height / 2,
            width: size.width, height: size.height
        )
    }

    func layoutFrames(in workspace: WorkspaceDescriptor.ID) throws -> [WindowToken: CGRect] {
        let monitor = try XCTUnwrap(world.monitor(for: workspace))
        switch world.activeLayoutKind(for: workspace) {
        case .niri:
            return try XCTUnwrap(controller.niriLayoutHandler.settledFrames(in: workspace))
        case .dwindle:
            let engine = try XCTUnwrap(controller.dwindleEngine)
            return engine.calculateLayout(
                for: workspace, screen: controller.insetWorkingFrame(for: monitor),
                calculationSettings: controller.dwindleLayoutHandler.calculationSettings(
                    controller.resolvedDwindleSettings(for: monitor), from: engine
                )
            )
        }
    }

    func notification(_ window: NSWindow, name: Notification.Name) -> Notification {
        Notification(name: name, object: window)
    }

    func clearOperations() {
        activationCount = 0
        for window in windows { window.operations.removeAll() }
    }

    func close() {
        controller.hasStartedServices = false
        for window in windows { window.close() }
        controller.layoutRefreshController.resetState()
        controller.surfaceReconciler.cleanup()
        controller.axManager.cleanup()
        controller.deadlineWheel.stop()
    }

    private static func monitor(id: CGDirectDisplayID, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Hosted Management \(id)"
        )
    }
}

@MainActor
final class HostedManagementWindow: NSWindow {
    enum Operation: Equatable {
        case frame(CGRect)
        case front
        case out
        case focus
        case minimize
        case restore
    }

    var operations: [Operation] = []
    var reportedBackingScale: CGFloat?
    override var backingScaleFactor: CGFloat {
        reportedBackingScale ?? super.backingScaleFactor
    }

    private var reportsVisible = false
    private var reportsMinimized = false
    private var reportsKey = false
    override var isVisible: Bool {
        reportsVisible
    }

    override var isMiniaturized: Bool {
        reportsMinimized
    }

    override var isKeyWindow: Bool {
        reportsKey && reportsVisible && !reportsMinimized
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        operations.append(.frame(frameRect))
        super.setFrame(frameRect, display: false)
    }

    override func orderFront(_ sender: Any?) {
        reportsVisible = true
        operations.append(.front)
    }

    override func orderOut(_ sender: Any?) {
        reportsVisible = false
        operations.append(.out)
        super.orderOut(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        reportsVisible = true
        reportsKey = true
        operations.append(.focus)
    }

    override func makeKey() {
        reportsKey = true
        operations.append(.focus)
    }

    override func miniaturize(_ sender: Any?) {
        reportsMinimized = true
        operations.append(.minimize)
        delegate?.windowDidMiniaturize?(Notification(name: NSWindow.didMiniaturizeNotification, object: self))
    }

    override func deminiaturize(_ sender: Any?) {
        reportsMinimized = false
        operations.append(.restore)
        delegate?.windowDidDeminiaturize?(Notification(name: NSWindow.didDeminiaturizeNotification, object: self))
    }
}

@MainActor
extension XCTestCase {
    func hostedRender(_ session: ShellAppRuntime, after action: () -> Void) async {
        let sequence = session.renderedSequence
        let published = expectation(description: "Hosted management content publishes or fails")
        let renderFailureDeadline: TimeInterval = 10
        session.onRender = { [weak session] in
            guard let session, session.failure != nil || session.renderedSequence > sequence else { return }
            session.onRender = nil
            published.fulfill()
        }
        action()
        await fulfillment(of: [published], timeout: renderFailureDeadline)
        session.onRender = nil
        XCTAssertNil(session.failure)
        XCTAssertGreaterThan(session.renderedSequence, sequence)
    }

    func readyHosted(_ session: ShellAppRuntime) async {
        if session.renderedSequence == 0 { await hostedRender(session, after: {}) }
        XCTAssertNil(session.failure)
    }

    func applyHosted(_ value: String, to session: ShellAppRuntime) async throws {
        await readyHosted(session)
        let input = try XCTUnwrap(session.surface.textInputs.values.first)
        await hostedRender(session, after: {
            input.field?.stringValue = value
            input.changed()
        })
        let surface = session.surface
        let apply = try hostedSheetAction("Apply", surface: surface)
        await hostedRender(session, after: apply)
    }

    func assertHostedContent(_ value: String, in session: ShellAppRuntime) {
        XCTAssertEqual(session.surface.textInputs.values.first?.text, value)
        XCTAssertTrue(session.surface.text?.strings.contains("You wrote: " + value) == true)
    }
}
