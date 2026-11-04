// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowManagementTests: XCTestCase {
    func testFloatPlaceNativeResizeAndRetilePreserveIndependentSessions() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedManagementFixture(layout: layout)
            defer { fixture.close() }
            XCTAssertFalse(fixture.controller.motionPolicy.userAnimationsEnabled)
            let first = try fixture.open()
            let second = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let firstText = "Move and resize this hosted draft"
            let secondText = "Keep this sibling's text intact"
            try await applyHosted(firstText, to: first.session)
            try await applyHosted(secondText, to: second.session)
            let field = try XCTUnwrap(first.session.surface.textInputs.values.first?.field)
            try fixture.float(first)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let requested = CGRect(
                origin: fixture.sourceMonitor.frame.origin,
                size: first.window.frameRect(forContentRect: CGRect(
                    origin: .zero, size: fixture.definition.contentSize
                )).size
            ).offsetBy(dx: -fixture.definition.contentSize.width, dy: -fixture.definition.contentSize.height)
            let expected = FloatingFrameGeometry.clamped(requested, in: fixture.sourceMonitor.visibleFrame)
            fixture.controller.placeFloatingWindow(
                try XCTUnwrap(fixture.world.handle(for: first.token)),
                frame: requested
            )
            XCTAssertEqual(first.window.frame, expected)
            XCTAssertEqual(fixture.world.floatingState(for: first.token)?.lastFrame, expected)

            let contentSize = fixture.definition.minimumContentSize
            let resized = first.window.frameRect(forContentRect: CGRect(
                origin: fixture.sourceMonitor.visibleFrame.center, size: contentSize
            ))
            fixture.moveNative(first, to: resized)
            XCTAssertEqual(fixture.world.entry(for: first.token)?.observedState.frame, resized)
            XCTAssertEqual(fixture.world.floatingState(for: first.token)?.lastFrame, resized)
            XCTAssertEqual(first.session.surface.size, contentSize)
            try fixture.select(first)
            XCTAssertEqual(fixture.controller.commandHandler.performCommand(.windowState(.toggleFloating)), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            XCTAssertEqual(fixture.world.windowMode(for: first.token), .tiling)
            XCTAssertFalse(fixture.world.animationDriver.hasMotion(in: fixture.source))
            let tiled = try XCTUnwrap(fixture.layoutFrames(in: fixture.source)[first.token])
            XCTAssertEqual(
                first.window.frame.minX, tiled.minX, accuracy: FrameTolerance.frameWrite,
                "\(layout): native \(first.window.frame), solver \(tiled), writes \(first.window.operations)"
            )
            XCTAssertEqual(first.window.frame.minY, tiled.minY, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(first.window.frame.width, tiled.width, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(first.window.frame.height, tiled.height, accuracy: FrameTolerance.frameWrite)
            XCTAssertGreaterThanOrEqual(
                first.window.contentRect(forFrameRect: first.window.frame).width,
                contentSize.width
            )
            XCTAssertGreaterThanOrEqual(
                first.window.contentRect(forFrameRect: first.window.frame).height,
                contentSize.height
            )
            assertHostedContent(firstText, in: first.session)
            let retiledText = "Still editable after returning to the tile"
            try await applyHosted(retiledText, to: first.session)
            assertHostedContent(retiledText, in: first.session)
            assertHostedContent(secondText, in: second.session)
            XCTAssertTrue(first.session.surface.textInputs.values.first?.field === field)
            XCTAssertTrue(fixture.manager.runtime(for: first.token) === first.session)
            XCTAssertTrue(fixture.manager.runtime(for: second.token) === second.session)
            XCTAssertEqual(fixture.world.workspace(for: fixture.external), fixture.source)
            XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: first.token.windowId))
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testWorkspaceMoveAppliesOnlySelectedInstanceVisibility() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            for floating in [false, true] {
                for follows in [false, true] {
                    let fixture = try HostedManagementFixture(layout: layout, follows: follows)
                    defer { fixture.close() }
                    let moving = try fixture.open()
                    let sibling = try fixture.open()
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
                    let movingText = "This draft crosses workspaces"
                    let siblingText = "This draft stays on its workspace"
                    try await applyHosted(movingText, to: moving.session)
                    try await applyHosted(siblingText, to: sibling.session)
                    if floating { try fixture.float(moving) }
                    try fixture.select(moving)
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
                    let handle = try XCTUnwrap(fixture.world.handle(for: moving.token))
                    XCTAssertEqual(fixture.world.selectedManagedToken, moving.token)
                    let outcome = fixture.controller.workspaceNavigationHandler.commitWindowMove(
                        handle: handle, toWorkspaceId: fixture.sourceOther
                    )
                    guard case .changed = outcome
                    else { return XCTFail("The workspace command must move the instance") }
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

                    XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.sourceOther)
                    XCTAssertEqual(fixture.world.workspace(for: sibling.token), fixture.source)
                    XCTAssertEqual(fixture.world.workspace(for: fixture.external), fixture.source)
                    XCTAssertEqual(
                        fixture.world.activeWorkspace(on: fixture.sourceMonitor.id)?.id,
                        follows ? fixture.sourceOther : fixture.source
                    )
                    XCTAssertEqual(moving.window.isVisible, follows)
                    XCTAssertEqual(sibling.window.isVisible, !follows)
                    XCTAssertEqual(fixture.world.hiddenState(for: moving.token) == nil, follows)
                    XCTAssertEqual(fixture.world.hiddenState(for: sibling.token) == nil, !follows)
                    XCTAssertEqual(fixture.world.pendingFocusedToken, follows ? moving.token : sibling.token)
                    XCTAssertTrue(fixture.controller.workspaceNavigationHandler.switchWorkspace(
                        rawWorkspaceID: follows ? "1" : "2"
                    ))
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
                    XCTAssertEqual(moving.window.isVisible, !follows)
                    XCTAssertEqual(sibling.window.isVisible, follows)
                    assertHostedContent(movingText, in: moving.session)
                    assertHostedContent(siblingText, in: sibling.session)
                    XCTAssertTrue(fixture.manager.runtime(for: moving.token) === moving.session)
                    XCTAssertTrue(fixture.manager.runtime(for: sibling.token) === sibling.session)
                    fixture.close()
                    await ShellWidgetHost.flushRetiredWork()
                }
            }
        }
    }

    func testMonitorCommandUsesActiveDestinationAndSavedFloatingPlacement() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            for floating in [false, true] {
                for follows in [false, true] {
                    let fixture = try HostedManagementFixture(layout: layout, follows: follows)
                    defer { fixture.close() }
                    let moving = try fixture.open()
                    let sibling = try fixture.open()
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
                    if floating { try fixture.float(moving) }
                    try fixture.select(moving)
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
                    let before = fixture.world.floatingState(for: moving.token)

                    XCTAssertEqual(
                        fixture.controller.commandHandler.performCommand(.workspace(.moveToMonitor(.left))), .executed
                    )
                    await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

                    XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.destination)
                    XCTAssertEqual(fixture.world.workspace(for: sibling.token), fixture.source)
                    XCTAssertEqual(fixture.world.workspace(for: fixture.external), fixture.source)
                    XCTAssertTrue(moving.window.isVisible)
                    XCTAssertTrue(sibling.window.isVisible)
                    XCTAssertEqual(fixture.world.pendingFocusedToken, follows ? moving.token : sibling.token)
                    if let before {
                        let origin = FloatingFrameGeometry.origin(
                            from: try XCTUnwrap(before.normalizedOrigin), windowSize: before.lastFrame.size,
                            in: fixture.destinationMonitor.visibleFrame
                        )
                        let expected = FloatingFrameGeometry.clamped(
                            CGRect(origin: origin, size: before.lastFrame.size),
                            in: fixture.destinationMonitor.visibleFrame
                        )
                        XCTAssertEqual(fixture.world.floatingState(for: moving.token)?.lastFrame, expected)
                        XCTAssertEqual(moving.window.frame, expected)
                    } else {
                        let expected = try XCTUnwrap(fixture.layoutFrames(in: fixture.destination)[moving.token])
                        XCTAssertTrue(moving.window.frame.size.isWithinFrameTolerance(of: expected.size))
                    }
                    XCTAssertTrue(fixture.manager.runtime(for: moving.token) === moving.session)
                    XCTAssertNil(fixture.controller.axManager.parkTargetFrame(for: moving.token.windowId))
                    fixture.close()
                    await ShellWidgetHost.flushRetiredWork()
                }
            }
        }
    }

    func testMinimizeOpenBarAndNativeRestorePreserveSiblingContent() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let first = try fixture.open()
        let second = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let firstText = "Restore this exact session"
        let secondText = "The other session remains editable"
        try await applyHosted(firstText, to: first.session)
        try await applyHosted(secondText, to: second.session)
        try fixture.select(first)
        first.window.miniaturize(nil)
        XCTAssertTrue(try XCTUnwrap(fixture.world.entry(for: first.token)).observedState.isMinimized)
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.shellAppOpen(fixture.definition.id)),
            .executed
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertFalse(first.window.isMiniaturized)
        XCTAssertFalse(try XCTUnwrap(fixture.world.entry(for: first.token)).observedState.isMinimized)
        first.window.miniaturize(nil)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let editedSibling = "The sibling accepts a different edit while the first is minimized"
        try await applyHosted(editedSibling, to: second.session)
        XCTAssertTrue(fixture.controller.windowActionHandler.focusWindowFromBar(token: first.token))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertFalse(first.window.isMiniaturized)
        let otherWorkspace = try XCTUnwrap(fixture.world.descriptor(for: fixture.sourceOther))
        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.switchWorkspace(
            rawWorkspaceID: otherWorkspace.name
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertFalse(first.window.isVisible)
        XCTAssertNotNil(fixture.world.hiddenState(for: first.token))
        let selectedHandle = try XCTUnwrap(fixture.world.handle(for: first.token))
        XCTAssertTrue(fixture.controller.windowActionHandler.navigateToWindow(handle: selectedHandle))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertTrue(first.window.isVisible)
        XCTAssertNil(fixture.world.hiddenState(for: first.token))
        XCTAssertEqual(fixture.world.activeWorkspace(on: fixture.sourceMonitor.id)?.id, fixture.source)
        XCTAssertEqual(fixture.world.pendingFocusedToken, first.token)
        first.window.miniaturize(nil)
        first.window.deminiaturize(nil)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertFalse(try XCTUnwrap(fixture.world.entry(for: first.token)).observedState.isMinimized)
        assertHostedContent(firstText, in: first.session)
        assertHostedContent(editedSibling, in: second.session)
        XCTAssertTrue(fixture.manager.runtime(for: first.token) === first.session)
        XCTAssertTrue(fixture.manager.runtime(for: second.token) === second.session)
        XCTAssertNil(fixture.controller.axManager.parkTargetFrame(for: first.token.windowId))
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
