// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class OwnedSurfaceFocusReleaseTests: XCTestCase {
    func testClosingTheLastOwnedWindowReleasesOwnedFocusAndKeepsTheSelection() throws {
        let fixture = try Fixture()
        let window = fixture.ownedWindow()
        XCTAssertTrue(fixture.controller.workspaceManager.recordOwnedSurfaceFocus())

        fixture.registry.windowWillClose(window)

        XCTAssertEqual(fixture.controller.workspaceManager.nativeFocusOwner, NativeFocusOwner.none)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, fixture.first)
    }

    func testClosingOneOfTwoOwnedWindowsKeepsOwnedFocus() throws {
        let fixture = try Fixture()
        let closing = fixture.ownedWindow()
        fixture.registry.registerWindowNumber(
            surfaceId: "remaining-utility",
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .frontmostInteractive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            ),
            windowNumber: 912_001,
            frameProvider: { nil },
            visibilityProvider: { true }
        )
        XCTAssertTrue(fixture.controller.workspaceManager.recordOwnedSurfaceFocus())

        fixture.registry.windowWillClose(closing)

        XCTAssertEqual(fixture.controller.workspaceManager.nativeFocusOwner, .ownedSurface)
    }

    func testHoveringThePreviouslySelectedWindowAfterTheLastOwnedWindowClosesFocusesIt() throws {
        var focusedTokens: [WindowToken] = []
        let fixture = try Fixture { focusedTokens.append($0) }
        let window = fixture.ownedWindow()
        XCTAssertTrue(fixture.controller.workspaceManager.recordOwnedSurfaceFocus())
        fixture.registry.windowWillClose(window)

        fixture.controller.mouseEventHandler.dispatchMouseMoved(at: fixture.firstFrame.center)

        XCTAssertEqual(focusedTokens, [fixture.first])
    }

    func testHoveringAnotherWindowAfterTheLastOwnedWindowClosesFocusesIt() throws {
        var focusedTokens: [WindowToken] = []
        let fixture = try Fixture { focusedTokens.append($0) }
        let window = fixture.ownedWindow()
        XCTAssertTrue(fixture.controller.workspaceManager.recordOwnedSurfaceFocus())
        fixture.registry.windowWillClose(window)

        fixture.controller.mouseEventHandler.dispatchMouseMoved(at: fixture.secondFrame.center)

        XCTAssertEqual(focusedTokens, [fixture.second])
    }

    func testHoveringTheFocusedWindowDoesNotRequestFocusAgain() throws {
        var focusedTokens: [WindowToken] = []
        let fixture = try Fixture { focusedTokens.append($0) }

        fixture.controller.mouseEventHandler.dispatchMouseMoved(at: fixture.firstFrame.center)

        XCTAssertEqual(focusedTokens, [])
    }
}

@MainActor
private struct Fixture {
    let controller: WMController
    let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
    let first: WindowToken
    let second: WindowToken
    let firstFrame: CGRect
    let secondFrame: CGRect

    init(recordFocus: @escaping (WindowToken) -> Void = { _ in }) throws {
        controller = WindowAdmissionTestSupport.controller(
            prefix: "OwnedSurfaceFocusReleaseTests",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    recordFocus(WindowToken(pid: pid, windowId: Int(windowId)))
                },
                raiseWindow: { _ in }
            ),
            ownedWindowRegistry: registry
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
        controller.niriLayoutHandler.enableNiriLayout()
        let visibleFrame = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId)).visibleFrame
        firstFrame = CGRect(x: visibleFrame.minX + 40, y: visibleFrame.minY + 40, width: 220, height: 150)
        secondFrame = firstFrame.offsetBy(dx: 300, dy: 0)
        first = try Self.addWindow(pid: 912_101, frame: firstFrame, to: workspaceId, controller: controller)
        second = try Self.addWindow(pid: 912_102, frame: secondFrame, to: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            first,
            in: workspaceId,
            activateWorkspaceOnMonitor: false
        ))
    }

    func ownedWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        registry.register(window)
        return window
    }

    private static func addWindow(
        pid: pid_t,
        frame: CGRect,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> WindowToken {
        let windowId = Int(pid) + 100
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let node = try XCTUnwrap(controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil))
        node.frame = frame
        node.renderedFrame = frame
        return token
    }
}
