// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedSettingsWindowTests: XCTestCase {
    func testAdmittedSettingsWindowFloatsOnTheActiveWorkspace() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        XCTAssertNotNil(fixture.controller.workspaceManager.focusWorkspace(named: "2"))
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.second)
        let window = fixture.makeWindow()

        let token = try XCTUnwrap(fixture.admit(window))

        XCTAssertEqual(token, WindowToken(pid: getpid(), windowId: window.windowNumber))
        XCTAssertTrue(fixture.manager.windows[token] === window)
        XCTAssertTrue(window.delegate === fixture.manager)
        XCTAssertNil(fixture.manager.runtime(for: token))
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .floating)
        XCTAssertEqual(entry.workspaceId, fixture.second)
        XCTAssertNil(entry.axRef)
        let metadata = try XCTUnwrap(entry.target.hostedMetadata)
        XCTAssertTrue(metadata.admitsFloating)
        XCTAssertEqual(metadata.role, .main)
        XCTAssertEqual(metadata.title, fixture.title)
        XCTAssertEqual(metadata.minimumSize, fixture.minimumSize)
        XCTAssertFalse(metadata.appId.isEmpty)
    }

    func testClosingTheSettingsWindowRemovesItsEntry() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let commanded = fixture.makeWindow()
        let commandedToken = try XCTUnwrap(fixture.admit(commanded))

        XCTAssertTrue(fixture.manager.close(commandedToken))

        XCTAssertNil(fixture.manager.windows[commandedToken])
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: commandedToken))

        let direct = fixture.makeWindow()
        let directToken = try XCTUnwrap(fixture.admit(direct))

        direct.close()

        XCTAssertNil(fixture.manager.windows[directToken])
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: directToken))
    }

    func testCloseGuardDecidesWhetherTheSettingsWindowCloses() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let window = fixture.makeWindow()
        let guardState = CloseGuard()
        let token = try XCTUnwrap(fixture.admit(window) {
            guardState.consulted += 1
            return guardState.allowsClose
        })

        window.performClose(nil)

        XCTAssertEqual(guardState.consulted, 1)
        XCTAssertTrue(fixture.manager.windows[token] === window)
        XCTAssertNotNil(fixture.controller.workspaceManager.entry(for: token))

        guardState.allowsClose = true
        XCTAssertTrue(fixture.manager.close(token))

        XCTAssertEqual(guardState.consulted, 2)
        XCTAssertNil(fixture.manager.windows[token])
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: token))
    }

    func testSwitcherListsTheAdmittedSettingsWindowWithItsTitle() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let token = try XCTUnwrap(fixture.admit(fixture.makeWindow()))
        let external = WindowToken(pid: 114_001, windowId: 114_101)
        _ = WindowAdmissionTestSupport.track(external, in: fixture.first, controller: controller)
        controller.settings.windowSwitcher.enabled = true
        _ = controller.workspaceManager.setManagedFocus(token, in: fixture.first)
        controller.commandHandler.frontmostAppPidProvider = { token.pid }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { token }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .windowSwitcher, hasCaptureAccess: { false })
        let switcher = WindowSwitcherController(controller: controller, previewCapture: capture)
        defer {
            switcher.shutdown()
            driver.finish()
        }

        switcher.handle(.begin(reverse: false, scope: .activeWorkspace))

        let panel = try XCTUnwrap(
            fixture.registry.visibleWindows().compactMap { $0 as? WindowSwitcherPanel }.first
        )
        let cards = presentationSubviews(WindowSwitcherTile.self, in: try XCTUnwrap(panel.contentView))
        XCTAssertEqual(Set(cards.map(\.handle.id)), [token, external])
        let card = try XCTUnwrap(cards.first { $0.handle.id == token })
        XCTAssertTrue(card.handle === controller.workspaceManager.handle(for: token))
        XCTAssertEqual(card.toolTip, fixture.title)
        XCTAssertTrue(presentationSubviews(NSTextField.self, in: card).map(\.stringValue).contains(fixture.title))
        switcher.handle(.cancel)
    }

    func testOwnedSettingsWindowStaysRefusedByTheAXPathAndIsAdmittedOnce() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let window = fixture.makeWindow()
        let token = try XCTUnwrap(fixture.admit(window))

        XCTAssertNil(fixture.admit(window))

        XCTAssertEqual(fixture.manager.windows.count, 1)
        XCTAssertEqual(
            fixture.controller.workspaceManager.allEntries().filter { $0.windowId == token.windowId }.count, 1
        )
        XCTAssertTrue(fixture.registry.contains(windowNumber: window.windowNumber))
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let evaluation = fixture.controller.evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        XCTAssertEqual(evaluation.decision.disposition, .unmanaged)
        XCTAssertEqual(evaluation.decision.source, .builtInRule(WindowRuleEngine.ownedWindowRuleName))
        guard case let .ignored(ignoredToken, reason) = fixture.controller.axEventHandler.prepareCreateCandidate(
            windowId: UInt32(token.windowId), windowInfo: nil, fallbackToken: token, fallbackAXRef: axRef
        ) else {
            return XCTFail("Expected the AX create path to ignore the owned Settings window")
        }
        XCTAssertEqual(ignoredToken, token)
        XCTAssertEqual(reason, .ownedWindow)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        XCTAssertNil(entry.axRef)
        XCTAssertEqual(entry.target.hostedMetadata?.admitsFloating, true)
    }

    func testSettingsWindowIsQueriedVisibleAgainAfterAWorkspaceRoundTrip() async throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let window = fixture.makeWindow()
        let token = try XCTUnwrap(fixture.admit(window))
        window.orderFront(nil)
        let world = fixture.controller.workspaceManager
        XCTAssertNotNil(world.floatingState(for: token))
        XCTAssertEqual(fixture.queriedVisibility(of: token), true)

        await fixture.activate(fixture.second)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(world.hiddenState(for: token)?.reason, .workspaceInactive)
        XCTAssertEqual(fixture.queriedVisibility(of: token), false)

        await fixture.activate(fixture.first)

        XCTAssertTrue(window.isVisible)
        XCTAssertNil(world.hiddenState(for: token))
        XCTAssertEqual(fixture.queriedVisibility(of: token), true)
    }

    func testManagedSettingsWindowNoLongerSuppressesManagedFocusRecovery() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let settings = fixture.makeWindow()
        settings.orderFront(nil)
        XCTAssertTrue(fixture.controller.hasVisibleOwnedWindow)

        _ = try XCTUnwrap(fixture.admit(settings))

        XCTAssertTrue(fixture.registry.contains(windowNumber: settings.windowNumber))
        XCTAssertFalse(fixture.controller.hasVisibleOwnedWindow)
        let unmanaged = fixture.makeWindow()
        unmanaged.orderFront(nil)
        XCTAssertTrue(fixture.controller.hasVisibleOwnedWindow)
    }

    func testOwnActivationLeavesTheFocusedSettingsWindowToKeyConfirmation() throws {
        let fixture = try SettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let token = try XCTUnwrap(fixture.admit(fixture.makeWindow()))
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            token, in: fixture.first, onMonitor: fixture.monitor.id, activateWorkspaceOnMonitor: true
        ))
        var reads = 0
        controller.factResolver.factProvider = { _ in
            reads += 1
            return nil
        }
        controller.axEventHandler.frontmostApplicationPIDProvider = { getpid() }

        controller.axEventHandler.handleAppActivation(pid: getpid(), source: .cgsFrontAppChanged)

        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, token)
        XCTAssertNil(controller.workspaceManager.externalFocusIdentity)
    }
}

@MainActor
private final class CloseGuard {
    var allowsClose = false
    var consulted = 0
}

@MainActor
private final class SettingsWindowFixture {
    let title = "OmniWM Settings"
    let minimumSize = CGSize(width: 760, height: 588)
    let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
    let controller: WMController
    let first: WorkspaceDescriptor.ID
    let second: WorkspaceDescriptor.ID
    let monitor: Monitor
    private var windows: [NSWindow] = []
    var manager: ShellAppWindowManager {
        controller.shellAppWindowManager
    }

    init() throws {
        controller = WindowAdmissionTestSupport.controller(
            prefix: "HostedSettingsWindow", ownedWindowRegistry: registry
        )
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        controller.shellAppWindowManager.focusWithoutRaising = { _ in }
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let display: CGDirectDisplayID = 114_000
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Hosted Settings"
        )
        self.monitor = monitor
        controller.settings.workspaces.configurations = ["1", "2"].map { name in
            WorkspaceConfiguration(
                name: name, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .dwindle
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        first = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        second = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 100, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        registry.register(window)
        windows.append(window)
        return window
    }

    func admit(_ window: NSWindow, shouldClose: (() -> Bool)? = nil) -> WindowToken? {
        manager.admitNativeFloating(window, title: title, minimumSize: minimumSize, shouldClose: shouldClose)
    }

    func activate(_ workspace: WorkspaceDescriptor.ID) async {
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace, on: monitor.id))
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [first, second], reason: .workspaceTransition
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
    }

    func queriedVisibility(of token: WindowToken) -> Bool? {
        IPCWindowQueryProjection(
            controller: controller, sessionToken: "", request: IPCQueryRequest(name: .windows),
            windowOrderedInProvider: { _ in true }
        ).result().windows.first { $0.windowId == token.windowId }?.isVisible
    }

    func close() {
        for window in windows {
            window.close()
            registry.unregister(window)
        }
        controller.layoutRefreshController.resetState()
        controller.surfaceReconciler.cleanup()
        controller.axManager.cleanup()
    }
}
