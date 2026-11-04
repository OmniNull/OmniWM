// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedUtilityTests: XCTestCase {
    func testAuthoredUtilitySharesOneRuntimeReusesItsDeclarationAndClosesIndependently() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        let independent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await openHostedUtility(parent, fixture: fixture)
        let declaration = try XCTUnwrap(fixture.definition.children["preferences"])
        let package = parent.session.package
        XCTAssertEqual(utility.metadata.role, .utility(parent: parent.token, declarationID: declaration.id))
        XCTAssertEqual(utility.metadata.instanceID, parent.session.id)
        XCTAssertTrue(fixture.manager.runtime(for: utility.token) === parent.session)
        XCTAssertTrue(utility.window.parent === parent.window)
        XCTAssertTrue(parent.window.childWindows?.contains(utility.window) == true)
        XCTAssertEqual(utility.window.level, .normal)
        XCTAssertTrue(utility.window.styleMask.contains(.resizable))
        XCTAssertFalse(utility.window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(utility.window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertEqual(utility.window.contentMinSize, declaration.minimumContentSize)
        XCTAssertEqual(fixture.world.windowMode(for: utility.token), .floating)
        XCTAssertEqual(Set(fixture.manager.runtimes.keys), [parent.session.id, independent.session.id])
        let heading = "Shared heading edited in Preferences"
        try await editHostedHeading(heading, in: utility, parent: parent)
        try await applyHosted("The main stays usable", to: parent.session)
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(heading))
        await readyHosted(independent.session)
        XCTAssertFalse(hostedSheetLabels(independent.session.surface).contains(heading))

        let nativeUtility = try XCTUnwrap(utility.window as? HostedManagementWindow)
        nativeUtility.operations.removeAll()
        let reopened = try await openHostedUtility(parent, fixture: fixture)

        XCTAssertEqual(nativeUtility.operations.filter { $0 == .focus }, [.focus])
        XCTAssertEqual(reopened.token, utility.token)
        XCTAssertTrue(reopened.window === utility.window)
        XCTAssertTrue(reopened.slot === utility.slot)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, utility.token)
        let close = try hostedSheetAction("Close", surface: utility.slot.surface)
        await hostedSheetEvent(parent.session, description: "Utility close removes only its root", completed: {
            fixture.manager.windows[utility.token] == nil && parent.session.slots[utility.metadata.rootID] == nil
        }, action: close)
        XCTAssertNil(fixture.world.entry(for: utility.token))
        XCTAssertTrue(fixture.manager.windows[parent.token] === parent.window)
        XCTAssertTrue(parent.session.package === package)
        XCTAssertFalse(parent.session.closed)
        let fresh = try await openHostedUtility(parent, fixture: fixture)
        XCTAssertNotEqual(fresh.metadata.rootID, utility.metadata.rootID)
        XCTAssertEqual(fresh.slot.surface.textInputs.values.first?.text, heading)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testUtilityFloatingPlacementResizesWithinMinimumAndLayoutFramesDoNotTranslateItTwice() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await openHostedUtility(parent, fixture: fixture)
        let handle = try XCTUnwrap(fixture.world.handle(for: utility.token))
        let desired = fixture.centeredFrame(on: fixture.sourceMonitor, size: utility.metadata.minimumSize)
        let placed = FloatingFrameGeometry.clamped(desired, in: fixture.sourceMonitor.visibleFrame)

        fixture.controller.placeFloatingWindow(handle, frame: desired)

        XCTAssertEqual(utility.window.frame, placed)
        XCTAssertEqual(fixture.world.floatingState(for: utility.token)?.lastFrame, placed)
        XCTAssertEqual(utility.slot.surface.size, utility.window.contentRect(forFrameRect: placed).size)
        let parentStart = parent.window.frame
        let childStart = utility.window.frame
        let offset = utility.metadata.minimumSize
        let target = parentStart.offsetBy(dx: offset.width, dy: -offset.height)
        let sequence = fixture.world.worldSeq
        let preparation = LayoutDiffExecutor(refreshController: fixture.controller.layoutRefreshController)
            .prepareFrameOnlyUpdates([
                .init(
                    token: utility.token,
                    frame: childStart.offsetBy(dx: offset.width, dy: offset.height),
                    forceApply: true
                ),
                .init(token: parent.token, frame: target, forceApply: true)
            ], controller: fixture.controller)
        XCTAssertTrue(preparation.frameUpdates.isEmpty)
        XCTAssertEqual(parent.window.frame, target)
        XCTAssertEqual(utility.window.frame, childStart.offsetBy(
            dx: target.minX - parentStart.minX,
            dy: target.minY - parentStart.minY
        ))
        XCTAssertEqual(fixture.world.worldSeq, sequence)
        XCTAssertTrue(utility.window.parent === parent.window)
        let tooSmall = CGRect(origin: placed.origin, size: .zero)
        XCTAssertTrue(fixture.manager.setFloatingFrame(tooSmall, for: utility.token))
        XCTAssertEqual(utility.window.frame.size, utility.metadata.minimumSize)
        XCTAssertEqual(fixture.world.floatingState(for: utility.token)?.lastFrame, utility.window.frame)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testActiveSheetBlocksUtilityInputAndRedirectsOnlyItsFamily() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        let independent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await openHostedUtility(parent, fixture: fixture)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        XCTAssertFalse(utility.window.ignoresMouseEvents)
        XCTAssertEqual(fixture.manager.activeSheet(for: utility.token), sheet.token)
        XCTAssertEqual(fixture.controller.focusWindow(utility.token)?.token, sheet.token)
        XCTAssertEqual(fixture.controller.focusWindow(independent.token)?.token, independent.token)
        try await applyHosted("Independent during sheet", to: independent.session)
        try await closeHostedSheet(sheet, button: "Cancel", parent: parent, fixture: fixture)
        XCTAssertFalse(utility.window.ignoresMouseEvents)
        XCTAssertNil(fixture.manager.activeSheet(for: utility.token))
        XCTAssertEqual(fixture.controller.focusWindow(utility.token)?.token, utility.token)
        fixture.manager.windowDidBecomeKey(fixture.notification(
            utility.window,
            name: NSWindow.didBecomeKeyNotification
        ))
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.windowState(.toggleFloating)), .attachedWindow)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.fullscreen(.native)), .attachedWindow)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.fullscreen(.managed)), .attachedWindow)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(
            .scratchpad(.assign(ScratchpadIndex.range.lowerBound))
        ), .attachedWindow)
        XCTAssertEqual(fixture.controller.workspaceNavigationHandler.moveWindow(
            handle: try XCTUnwrap(fixture.world.handle(for: utility.token)), toWorkspaceId: fixture.sourceOther
        ), .unchanged)
        XCTAssertTrue(fixture.manager.close(utility.token))
        XCTAssertNotNil(fixture.world.entry(for: parent.token))
        XCTAssertNil(fixture.world.entry(for: utility.token))
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
