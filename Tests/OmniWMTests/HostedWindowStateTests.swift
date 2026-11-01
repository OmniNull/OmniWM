// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowStateTests: XCTestCase {
    func testHostedAdmissionUsesCheckedTargetAndDirectLifetime() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let admitted = fixture.manager.addHostedWindow(
            token: fixture.token,
            metadata: fixture.metadata,
            to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        )
        let entry = try XCTUnwrap(fixture.manager.entry(for: fixture.token))

        XCTAssertEqual(admitted, fixture.token)
        XCTAssertEqual(entry.target, .hosted(fixture.metadata))
        XCTAssertNil(entry.axRef)
        XCTAssertEqual(entry.pid, getpid())
        XCTAssertEqual(entry.windowId, fixture.window.windowNumber)
        XCTAssertEqual(entry.lifetimeAuthority, .directLifecycle)
        XCTAssertEqual(entry.workspaceId, fixture.workspaceId)
        XCTAssertEqual(entry.mode, .tiling)
        XCTAssertEqual(entry.lifecyclePhase, .tiled)
        XCTAssertEqual(entry.desiredState.disposition, .tiling)
        XCTAssertNil(entry.floatingState)
        XCTAssertNil(entry.desiredState.floatingFrame)
        XCTAssertEqual(entry.observedState.frame, fixture.window.frame)
        XCTAssertFalse(fixture.manager.promoteLifetimeAuthorityForObservedTopLevelWindows([fixture.token]))
        XCTAssertEqual(fixture.manager.entry(for: fixture.token)?.lifetimeAuthority, .directLifecycle)
    }

    func testHostedStateDoesNotEnterAXBindingPIDBuckets() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        _ = fixture.manager.addHostedWindow(
            token: fixture.token, metadata: fixture.metadata, to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        )
        let entry = try XCTUnwrap(fixture.manager.entry(for: fixture.token))
        let bindings = AXManagedWindowBindings()
        defer { bindings.shutdown() }
        var attemptedRetries: [Int] = []
        bindings.managedWindowBindingRetryDelayProvider = { attempt in
            attemptedRetries.append(attempt)
            return nil
        }

        bindings.bindManagedWindows([entry])

        XCTAssertTrue(attemptedRetries.isEmpty)
        XCTAssertTrue(bindings.pendingManagedWindowBindingRetryPIDs(intersecting: [entry.pid]).isEmpty)
    }

    func testHostedAdmissionRejectsDuplicateAndForeignProcessIdentity() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let foreign = WindowToken(pid: getppid(), windowId: fixture.window.windowNumber)
        XCTAssertNotEqual(foreign.pid, fixture.token.pid)
        XCTAssertNil(fixture.manager.addHostedWindow(
            token: foreign, metadata: fixture.metadata, to: fixture.workspaceId, initialFrame: fixture.window.frame
        ))
        XCTAssertNil(fixture.manager.entry(for: foreign))
        XCTAssertEqual(fixture.manager.addHostedWindow(
            token: fixture.token, metadata: fixture.metadata, to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        ), fixture.token)
        let original = fixture.manager.entry(for: fixture.token)
        XCTAssertNil(fixture.manager.addHostedWindow(
            token: fixture.token, metadata: fixture.metadata, to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        ))
        XCTAssertEqual(fixture.manager.entry(for: fixture.token), original)
    }

    func testHostedRemovalUsesTheManagedRemovalAndIsIdempotent() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        _ = fixture.manager.addHostedWindow(
            token: fixture.token, metadata: fixture.metadata, to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        )
        let admitted = try XCTUnwrap(fixture.manager.entry(for: fixture.token))
        var removed: [WindowState] = []
        fixture.manager.onWindowRemoved = { removed.append($0) }

        XCTAssertEqual(fixture.manager.removeHostedWindow(fixture.token), admitted)
        XCTAssertNil(fixture.manager.entry(for: fixture.token))
        XCTAssertNil(fixture.manager.removeHostedWindow(fixture.token))
        XCTAssertEqual(removed, [admitted])
    }

    func testExternalAdmissionKeepsItsAXReferenceAndRemovalContract() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        let reference = AXWindowRef(
            element: AXUIElementCreateApplication(getppid()),
            windowId: fixture.window.windowNumber
        )
        let token = fixture.manager.addWindow(
            reference,
            pid: getppid(),
            windowId: reference.windowId,
            to: fixture.workspaceId
        )
        let entry = try XCTUnwrap(fixture.manager.entry(for: token))

        XCTAssertEqual(entry.target, .external(reference))
        XCTAssertEqual(entry.axRef, reference)
        XCTAssertEqual(entry.lifetimeAuthority, .axTopLevelInventory)
        XCTAssertNil(entry.observedState.frame)
        XCTAssertNil(entry.floatingState)
        XCTAssertNil(fixture.manager.removeHostedWindow(token))
        XCTAssertEqual(fixture.manager.entry(for: token), entry)
        XCTAssertEqual(fixture.manager.removeWindow(pid: token.pid, windowId: token.windowId), entry)
        XCTAssertNil(fixture.manager.entry(for: token))
    }

    func testHostedTargetsCannotBeRekeyedIntoExternalAXTargets() throws {
        let fixture = try fixture()
        defer { fixture.window.close() }
        _ = fixture.manager.addHostedWindow(
            token: fixture.token, metadata: fixture.metadata, to: fixture.workspaceId,
            initialFrame: fixture.window.frame
        )
        let original = fixture.manager.entry(for: fixture.token)
        let reference = AXWindowRef(
            element: AXUIElementCreateApplication(getppid()),
            windowId: fixture.token.windowId
        )

        XCTAssertNil(fixture.manager.rekeyWindow(
            from: fixture.token, to: fixture.token, newAXRef: reference
        ))
        XCTAssertEqual(fixture.manager.entry(for: fixture.token), original)
        XCTAssertEqual(fixture.manager.addWindow(
            reference,
            pid: fixture.token.pid,
            windowId: fixture.token.windowId,
            to: fixture.workspaceId
        ), fixture.token)
        XCTAssertEqual(fixture.manager.entry(for: fixture.token), original)
    }

    private struct Fixture {
        let controller: WMController
        let manager: WorkspaceManager
        let window: NSWindow
        let metadata: HostedWindowMetadata
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
    }

    private func fixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedWindowStateTests")
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let contentSize = CGSize(width: 320, height: 180)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let metadata = HostedWindowMetadata(
            appId: "hosted-state-fixture", title: "Hosted state fixture", minimumSize: contentSize
        )
        return Fixture(
            controller: controller,
            manager: manager,
            window: window,
            metadata: metadata,
            workspaceId: workspaceId,
            token: WindowToken(pid: getpid(), windowId: window.windowNumber)
        )
    }
}
