// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class HostedAppInstanceTests: XCTestCase {
    private let renderFailureDeadline: TimeInterval = 10

    func testNewWindowKeepsIndependentContentAndClosingOneLeavesItsSiblingUsable() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try fixture.open(.shellAppOpen(fixture.definition.id))
        let second = try fixture.open(.shellAppNewWindow(fixture.definition.id))
        await ready(first.session)
        await ready(second.session)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(first.token.pid, second.token.pid)
        XCTAssertNotEqual(first.session.id, second.session.id)
        XCTAssertFalse(first.session.package === second.session.package)
        XCTAssertFalse(first.session.surface === second.session.surface)
        let firstText = "First window's private draft"
        let secondText = "Second window's different draft"
        try await apply(firstText, to: first.session)
        try await apply(secondText, to: second.session)
        assertContent(firstText, in: first.session)
        assertContent(secondText, in: second.session)
        let contentSize = fixture.definition.minimumContentSize
        let frame = first.window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize))
        await render(first.session, after: {
            XCTAssertTrue(fixture.manager.setFrame(frame, for: first.token))
        })
        XCTAssertEqual(first.session.surface.size, contentSize)
        assertContent(firstText, in: first.session)
        assertContent(secondText, in: second.session)
        let request = try XCTUnwrap(fixture.controller.focusWindow(first.token))
        fixture.confirm(first)
        XCTAssertEqual(request.token, first.token)
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, first.token)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.windowState(.close)), .executed)
        XCTAssertTrue(first.session.closed)
        XCTAssertNil(fixture.manager.runtime(for: first.token))
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: first.token))
        XCTAssertTrue(fixture.manager.runtime(for: second.token) === second.session)
        let survivingText = "Still editable after the first window closed"
        try await apply(survivingText, to: second.session)
        assertContent(survivingText, in: second.session)
        let sequence = second.session.renderedSequence
        var late = ShellWidgetDelivery(generation: ShellAppRuntime.generation)
        late.trees[ShellTreeKey(instance: .window(first.session.id), view: .window)] = .init(sequence: sequence)
        first.session.receive(late)
        second.session.receive(late)
        XCTAssertEqual(second.session.renderedSequence, sequence)
        assertContent(survivingText, in: second.session)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testOpenSelectsMatchingMRUIncludingMinimizedFloatingWindowOnAnotherWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try fixture.open(.shellAppOpen(fixture.definition.id))
        let second = try fixture.open(.shellAppNewWindow(fixture.definition.id))
        fixture.confirm(second)
        XCTAssertNotNil(fixture.controller.focusWindow(first.token))
        fixture.confirm(first)
        XCTAssertTrue(fixture.controller.transitionWindowMode(for: first.token, to: .floating))
        let destination = try XCTUnwrap(fixture.controller.workspaceManager.workspaceId(named: "2"))
        let handle = try XCTUnwrap(fixture.controller.workspaceManager.handle(for: first.token))
        _ = fixture.controller.workspaceNavigationHandler.moveWindow(handle: handle, toWorkspaceId: destination)
        first.window.miniaturize(nil)
        XCTAssertTrue(try XCTUnwrap(fixture.controller.workspaceManager.entry(for: first.token)).observedState
            .isMinimized)
        let originalWindows = fixture.created
        fixture.focusedWindows.removeAll()

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.shellAppOpen(fixture.definition.id)),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.created, originalWindows)
        XCTAssertFalse(first.window.isMiniaturized)
        XCTAssertEqual(fixture.focusedWindows, [first.token])
        fixture.confirm(first)
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, first.token)
        XCTAssertTrue(fixture.manager.runtime(for: first.token) === first.session)
        XCTAssertTrue(fixture.manager.runtime(for: second.token) === second.session)
    }

    func testOpenFallsBackToLowestLiveMatchingWindowNumberWithoutFocusHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = try fixture.admitUnfocused()
        let second = try fixture.admitUnfocused()
        let expected = [first.token, second.token].min { $0.windowId < $1.windowId }
        XCTAssertTrue(fixture.controller.workspaceManager.windowFocusRecencyOrder.isEmpty)
        let originalWindows = fixture.created

        XCTAssertTrue(fixture.manager.open(fixture.definition, in: fixture.workspace))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.created, originalWindows)
        XCTAssertEqual(fixture.focusedWindows, [try XCTUnwrap(expected)])
    }

    func testOpenSkipsAMoreRecentWindowFromAnotherHostedApp() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let expected = try fixture.admitUnfocused()
        let otherDefinition = ShellAppDefinition(
            id: "other-example", title: "Other Example", contentSize: fixture.definition.contentSize,
            minimumContentSize: fixture.definition.minimumContentSize, folder: fixture.definition.folder
        )
        let other = try fixture.admitUnfocused(definition: otherDefinition)
        XCTAssertNotNil(fixture.controller.focusWindow(expected.token))
        fixture.confirm(expected)
        XCTAssertNotNil(fixture.controller.focusWindow(other.token))
        fixture.confirm(other)
        fixture.focusedWindows.removeAll()
        let originalWindows = fixture.created

        XCTAssertTrue(fixture.manager.open(fixture.definition, in: fixture.workspace))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.focusedWindows, [expected.token])
        XCTAssertEqual(fixture.created, originalWindows)
    }

    private func ready(_ session: ShellAppRuntime) async {
        if session.renderedSequence > 0 {
            XCTAssertNil(session.failure)
            return
        }
        await render(session, after: {})
    }

    private func render(_ session: ShellAppRuntime, after action: () -> Void) async {
        let sequence = session.renderedSequence
        let published = expectation(description: "The window publishes changed content or a failure")
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

    private func apply(_ value: String, to session: ShellAppRuntime) async throws {
        let input = try XCTUnwrap(session.surface.textInputs.values.first)
        await render(session, after: {
            input.field?.stringValue = value
            input.changed()
        })
        let surface = session.surface
        let apply = try hostedSheetAction("Apply", surface: surface)
        await render(session, after: apply)
    }

    private func assertContent(_ value: String, in session: ShellAppRuntime) {
        XCTAssertEqual(session.surface.textInputs.values.first?.text, value)
        XCTAssertTrue(session.surface.text?.strings.contains("You wrote: " + value) == true)
    }
}

private extension HostedAppInstanceTests {
    struct Instance {
        let token: WindowToken
        let window: InstanceWindow
        let session: ShellAppRuntime
    }

    @MainActor
    final class Fixture {
        let definition: ShellAppDefinition
        let controller: WMController
        let workspace: WorkspaceDescriptor.ID
        var created: [InstanceWindow] = []
        var focusedWindows: [WindowToken] = []
        var manager: ShellAppWindowManager {
            controller.shellAppWindowManager
        }

        init() throws {
            definition = try XCTUnwrap(ShellAppDefinition.example)
            controller = WindowAdmissionTestSupport.controller(prefix: "HostedAppInstances")
            controller.hasStartedServices = true
            controller.shellAppWindowManager.activateApplication = {}
            let frame = CGRect(origin: .zero, size: definition.contentSize)
            let display = CGDirectDisplayID.max
            let monitor = Monitor(
                id: .init(displayId: display), displayId: display, frame: frame, visibleFrame: frame,
                hasNotch: false, name: "Hosted Instances"
            )
            controller.settings.workspaces.configurations = ["1", "2"].map { name in
                WorkspaceConfiguration(
                    name: name, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .dwindle
                )
            }
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
            controller.workspaceManager.applySettings()
            workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            manager.makeWindow = { [weak self] definition in
                let window = InstanceWindow(
                    contentRect: CGRect(origin: .zero, size: definition.contentSize),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.didFocus = { [weak self, weak window] in
                    guard let window else { return }
                    self?.focusedWindows.append(WindowToken(pid: getpid(), windowId: window.windowNumber))
                }
                self?.created.append(window)
                return window
            }
        }

        func open(_ command: HotkeyCommand) throws -> Instance {
            XCTAssertEqual(controller.commandHandler.performCommand(command), .executed)
            let window = try XCTUnwrap(created.last)
            let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
            return Instance(token: token, window: window, session: try XCTUnwrap(manager.runtime(for: token)))
        }

        func admitUnfocused(definition other: ShellAppDefinition? = nil) throws -> Instance {
            let definition = other ?? self.definition
            let window = try XCTUnwrap(manager.makeWindow(definition) as? InstanceWindow)
            let session = ShellAppRuntime(
                definition: definition, window: window,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false))
            )
            let token = try XCTUnwrap(manager.admit(
                window,
                metadata: HostedWindowMetadata(
                    appId: definition.id, title: definition.title,
                    minimumSize: window.frameRect(forContentRect: CGRect(
                        origin: .zero, size: definition.minimumContentSize
                    )).size, instanceID: session.id, rootID: session.id
                ),
                to: workspace
            ))
            manager.runtimes[session.id] = session
            return Instance(token: token, window: window, session: session)
        }

        func confirm(_ instance: Instance) {
            manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: instance.window))
        }

        func close() {
            for window in created { window.close() }
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
    }

    @MainActor
    final class InstanceWindow: NSWindow {
        var didFocus: (() -> Void)?
        private var reportsVisible = false
        private var reportsMinimized = false
        override var isVisible: Bool {
            reportsVisible
        }

        override var isKeyWindow: Bool {
            reportsVisible && !reportsMinimized
        }

        override var isMiniaturized: Bool {
            reportsMinimized
        }

        override func orderFront(_ sender: Any?) {
            reportsVisible = true
        }

        override func orderOut(_ sender: Any?) {
            reportsVisible = false
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            reportsVisible = true
            didFocus?()
        }

        override func miniaturize(_ sender: Any?) {
            reportsMinimized = true
            delegate?.windowDidMiniaturize?(Notification(name: NSWindow.didMiniaturizeNotification, object: self))
        }

        override func deminiaturize(_ sender: Any?) {
            reportsMinimized = false
            delegate?.windowDidDeminiaturize?(Notification(name: NSWindow.didDeminiaturizeNotification, object: self))
        }
    }
}
