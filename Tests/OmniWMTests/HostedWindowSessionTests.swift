// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class HostedWindowSessionTests: XCTestCase {
    private let renderFailureDeadline: TimeInterval = 10

    func testTheRealComponentUsesContentSizeAndKeepsInputAndResultAcrossResize() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let window = makeWindow(definition)
        let session = ShellAppRuntime(
            definition: definition, window: window,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false))
        )
        defer { session.close()
            window.close()
        }
        let expectedContent = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(session.context.width, expectedContent.width)
        XCTAssertEqual(session.context.height, expectedContent.height)
        XCTAssertNotEqual(window.frame.height, expectedContent.height)
        XCTAssertTrue(window.contentView === session.surface.view)

        await render(session, after: { session.start() })

        XCTAssertEqual(session.surface.size, expectedContent)
        let input = try XCTUnwrap(session.surface.textInputs.values.first)
        let draft = "A real hosted component"
        let sequence = session.renderedSequence
        await render(session, after: {
            input.field?.stringValue = draft
            input.changed()
        }, newerThan: sequence)
        XCTAssertEqual(try XCTUnwrap(session.surface.textInputs.values.first).text, draft)
        let apply = try hostedSheetAction("Apply", surface: session.surface)
        let buttonSequence = session.renderedSequence
        await render(session, after: {
            apply()
        }, newerThan: buttonSequence)
        XCTAssertTrue(session.surface.text?.strings.contains("You wrote: " + draft) == true)
        let package = session.package
        let root = session.surface.layout.core.rootHandle
        let resizedContent = definition.minimumContentSize
        let resizeSequence = session.renderedSequence

        await render(session, after: {
            window.setContentSize(resizedContent)
            session.resize(window.contentRect(forFrameRect: window.frame).size)
        }, newerThan: resizeSequence)

        XCTAssertTrue(session.package === package)
        XCTAssertEqual(session.surface.layout.core.rootHandle, root)
        XCTAssertEqual(session.surface.size, resizedContent)
        XCTAssertEqual(session.context.width, resizedContent.width)
        XCTAssertEqual(session.context.height, resizedContent.height)
        XCTAssertEqual(try XCTUnwrap(session.surface.textInputs.values.first).text, draft)
        XCTAssertTrue(session.surface.text?.strings.contains("You wrote: " + draft) == true)
    }

    func testCloseRejectsLateTreesAndAReopenedWindowHasADifferentIdentity() async throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let previousWindow = makeWindow(definition)
        let previous = ShellAppRuntime(
            definition: definition, window: previousWindow,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false))
        )
        defer { previous.close()
            previousWindow.close()
        }
        await render(previous, after: { previous.start() })
        let previousSequence = previous.renderedSequence
        previous.close()
        let nextWindow = makeWindow(definition)
        let next = ShellAppRuntime(
            definition: definition, window: nextWindow,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false))
        )
        defer { next.close()
            nextWindow.close()
        }
        XCTAssertNotEqual(previous.id, next.id)
        XCTAssertFalse(previous.package === next.package)
        var late = ShellWidgetDelivery(generation: ShellAppRuntime.generation)
        late.trees[ShellTreeKey(instance: .window(previous.id), view: .window)] = .init(
            sequence: previousSequence + 1
        )

        previous.receive(late)
        next.receive(late)

        XCTAssertTrue(previous.closed)
        XCTAssertEqual(previous.renderedSequence, previousSequence)
        XCTAssertEqual(next.renderedSequence, 0)
        XCTAssertNil(previous.surface.onAction)
        await render(next, after: { next.start() })
        XCTAssertNotEqual(next.renderedSequence, 0)
    }

    func testOpenReusesTheManagedInstanceAndNativeCloseReleasesIt() throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedWindowSession")
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        let frame = CGRect(origin: .zero, size: CGSize(
            width: definition.contentSize.width * 2, height: definition.contentSize.height * 2
        ))
        let display = CGDirectDisplayID.max
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Hosted Session"
        )
        controller.settings.workspaces.configurations = [WorkspaceConfiguration(
            name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .dwindle
        )]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        var created: [HostedSessionWindow] = []
        controller.shellAppWindowManager.makeWindow = { definition in
            let window = HostedSessionWindow(
                contentRect: CGRect(origin: .zero, size: definition.contentSize),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            created.append(window)
            return window
        }
        defer {
            for window in created { window.close() }
            controller.layoutRefreshController.resetState()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let manager = controller.shellAppWindowManager
        XCTAssertTrue(manager.open(definition, in: workspace))
        let pair = try XCTUnwrap(manager.windows.first)
        let original = try XCTUnwrap(manager.runtime(for: pair.key))
        let native = try XCTUnwrap(manager.windows[pair.key])
        let createdBeforeReopen = created
        XCTAssertNotNil(controller.workspaceManager.entry(for: pair.key))

        XCTAssertTrue(manager.open(definition, in: workspace))

        XCTAssertEqual(created, createdBeforeReopen)
        XCTAssertTrue(manager.runtime(for: pair.key) === original)
        XCTAssertTrue(manager.windows[pair.key] === native)
        native.close()
        XCTAssertTrue(original.closed)
        XCTAssertNil(manager.runtime(for: pair.key))
        XCTAssertNil(manager.windows[pair.key])
        XCTAssertNil(controller.workspaceManager.entry(for: pair.key))
        XCTAssertTrue(manager.open(definition, in: workspace))
        let reopened = try XCTUnwrap(manager.runtimes.first?.value)
        XCTAssertNotEqual(reopened.id, original.id)
        XCTAssertFalse(reopened === original)
        let reopenedPair = try XCTUnwrap(manager.windows.first)
        let reopenedWindow = try XCTUnwrap(manager.windows[reopenedPair.key])
        manager.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: reopenedWindow))
        XCTAssertEqual(controller.commandHandler.performCommand(.windowState(.close)), .executed)
        XCTAssertTrue(reopened.closed)
        XCTAssertNil(manager.runtime(for: reopenedPair.key))
        XCTAssertNil(controller.workspaceManager.entry(for: reopenedPair.key))
    }

    private func render(
        _ session: ShellAppRuntime, after action: () -> Void, newerThan sequence: Int = 0
    ) async {
        let rendered = expectation(description: "The hosted component publishes its next tree or a failure")
        session.onRender = { [weak session] in
            guard let session, session.failure != nil || session.renderedSequence > sequence else { return }
            session.onRender = nil
            rendered.fulfill()
        }
        action()
        await fulfillment(of: [rendered], timeout: renderFailureDeadline)
        session.onRender = nil
        XCTAssertNil(session.failure)
        XCTAssertGreaterThan(session.renderedSequence, sequence)
    }

    private func makeWindow(_ definition: ShellAppDefinition) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: definition.contentSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class HostedSessionWindow: NSWindow {
    private var reportsVisible = false
    override var isVisible: Bool {
        reportsVisible
    }

    override var isKeyWindow: Bool {
        reportsVisible
    }

    override func orderFront(_ sender: Any?) {
        reportsVisible = true
    }

    override func orderOut(_ sender: Any?) {
        reportsVisible = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        reportsVisible = true
    }
}
