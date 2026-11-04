// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMIPC
import Synchronization
import XCTest

@MainActor
final class HostedSheetTests: XCTestCase {
    func testAuthoredDeleteCancelAndConfirmShareStateAndReopenAFreshNativeRoot() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let draft = "Keep this parent document until confirmation"
        try await applyHosted(draft, to: parent.session)
        let result = "You wrote: " + draft
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(result))

        let first = try await openHostedSheet(parent, fixture: fixture)
        let declaration = try XCTUnwrap(fixture.definition.children["confirm"])
        XCTAssertTrue(first.window.sheetParent === parent.window)
        XCTAssertTrue(parent.window.attachedSheet === first.window)
        XCTAssertEqual(first.metadata.role, .sheet(parent: parent.token, declarationID: declaration.id))
        XCTAssertEqual(first.metadata.instanceID, parent.session.id)
        XCTAssertEqual(first.metadata.title, declaration.title)
        XCTAssertEqual(first.slot.context.viewName, declaration.view)
        XCTAssertEqual(fixture.world.windowMode(for: first.token), .floating)
        XCTAssertEqual(fixture.world.workspace(for: first.token), fixture.world.workspace(for: parent.token))
        XCTAssertTrue(fixture.manager.runtime(for: first.token) === parent.session)
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(result))

        try await closeHostedSheet(first, button: "Cancel", parent: parent, fixture: fixture)

        XCTAssertNil(parent.window.attachedSheet)
        XCTAssertNil(first.window.sheetParent)
        XCTAssertNil(fixture.world.entry(for: first.token))
        XCTAssertNil(first.slot.surface.onAction)
        XCTAssertFalse(parent.session.closed)
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(result))
        XCTAssertEqual(parent.session.surface.textInputs.values.first?.text, draft)

        let reopened = try await openHostedSheet(parent, fixture: fixture)

        XCTAssertNotEqual(reopened.metadata.rootID, first.metadata.rootID)
        XCTAssertNotEqual(reopened.slot.surface.sourceID, first.slot.surface.sourceID)
        XCTAssertTrue(reopened.window.sheetParent === parent.window)
        let roots = await parent.session.package.hostedSheetRootIDs()
        XCTAssertEqual(roots, [parent.session.id, reopened.metadata.rootID])
        XCTAssertFalse(roots.contains(first.metadata.rootID))

        try await closeHostedSheet(
            reopened, button: "Confirm", parent: parent, fixture: fixture, expectedResult: "Deleted."
        )

        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains("Deleted."))
        XCTAssertFalse(hostedSheetLabels(parent.session.surface).contains(result))
        XCTAssertEqual(parent.session.surface.textInputs.values.first?.text, draft)
        XCTAssertNil(fixture.manager.activeSheet(for: parent.token))
        XCTAssertNotNil(fixture.world.entry(for: parent.token))
        XCTAssertFalse(parent.session.closed)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testActiveSheetRejectsIndependentManagementAndParentFocusTargetsIt() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        let declaration = try XCTUnwrap(fixture.definition.children["confirm"])
        let windows = Set(fixture.manager.windows.keys)

        XCTAssertEqual(
            fixture.manager.openSheet(declaration, runtime: parent.session, parent: parent.token),
            "This window already has an active sheet."
        )
        XCTAssertEqual(Set(fixture.manager.windows.keys), windows)
        XCTAssertEqual(fixture.manager.childTokens(of: parent.token), [sheet.token])
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        let request = try XCTUnwrap(fixture.controller.focusWindow(parent.token))
        XCTAssertEqual(request.token, sheet.token)
        fixture.manager.windowDidBecomeKey(fixture.notification(sheet.window, name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(fixture.world.nativeManagedFocusToken, sheet.token)
        let sourceWorkspace = fixture.world.workspace(for: sheet.token)
        let frame = sheet.window.frame
        let parentFrame = parent.window.frame

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.windowState(.toggleFloating)), .attachedWindow)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.fullscreen(.managed)), .attachedWindow)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.fullscreen(.native)), .attachedWindow)
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.scratchpad(.assign(ScratchpadIndex.range.lowerBound))),
            .attachedWindow
        )
        XCTAssertEqual(fixture.controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: sheet.token), toWorkspaceId: fixture.sourceOther
        ), .unchanged)
        XCTAssertEqual(fixture.controller.workspaceNavigationHandler.moveWindowToMonitor(
            handle: WindowHandle(id: sheet.token), direction: .left
        ), .unchanged)

        XCTAssertEqual(fixture.world.workspace(for: sheet.token), sourceWorkspace)
        XCTAssertEqual(fixture.world.windowMode(for: sheet.token), .floating)
        XCTAssertNil(fixture.world.scratchpadIndex(for: sheet.token))
        XCTAssertNil(fixture.world.manualLayoutOverride(for: sheet.token))
        XCTAssertEqual(sheet.window.frame, frame)
        XCTAssertEqual(parent.window.frame, parentFrame)
        XCTAssertTrue(fixture.manager.setFrame(parentFrame, for: sheet.token))
        XCTAssertEqual(sheet.window.frame, frame)
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)

        let independent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        await readyHosted(independent.session)
        let independentText = "This app instance remains usable during the other instance's sheet"
        try await applyHosted(independentText, to: independent.session)
        XCTAssertTrue(hostedSheetLabels(independent.session.surface).contains("You wrote: " + independentText))
        XCTAssertEqual(fixture.controller.focusWindow(independent.token)?.token, independent.token)
        XCTAssertEqual(fixture.controller.focusWindow(parent.token)?.token, sheet.token)
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testParentCloseAndRepeatedShutdownCloseEachAttachedNativeWindowOnce() async throws {
        for shutdown in [false, true] {
            let fixture = try HostedManagementFixture()
            defer { fixture.close() }
            let parent = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let sheet = try await openHostedSheet(parent, fixture: fixture)
            let expectedTokens = [parent.token, sheet.token]
            let tokensByWindow = [
                ObjectIdentifier(parent.window): parent.token,
                ObjectIdentifier(sheet.window): sheet.token
            ]
            let nativeCloses = Mutex<[WindowToken: Int]>([:])
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: nil
            ) { notification in
                guard let window = notification.object as? NSWindow,
                      let token = tokensByWindow[ObjectIdentifier(window)] else { return }
                nativeCloses.withLock { $0[token, default: 0] += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let previousRemoval = fixture.world.onWindowRemoved
            var removed: [WindowToken] = []
            fixture.world.onWindowRemoved = { entry in
                previousRemoval?(entry)
                removed.append(entry.token)
            }
            defer { fixture.world.onWindowRemoved = previousRemoval }

            if shutdown {
                fixture.manager.shutdown()
                fixture.manager.shutdown()
            } else {
                parent.window.close()
            }

            XCTAssertEqual(Set(removed), Set(expectedTokens))
            XCTAssertEqual(removed.count, expectedTokens.count)
            XCTAssertEqual(
                nativeCloses.withLock { $0 },
                Dictionary(uniqueKeysWithValues: expectedTokens.map { ($0, 1) })
            )
            XCTAssertTrue(parent.session.closed)
            XCTAssertTrue(parent.session.slots.isEmpty)
            XCTAssertTrue(fixture.manager.windows.isEmpty)
            XCTAssertTrue(fixture.manager.runtimes.isEmpty)
            XCTAssertNil(parent.window.attachedSheet)
            XCTAssertNil(sheet.window.sheetParent)
            XCTAssertNotNil(fixture.world.entry(for: fixture.external))
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testEscapeFinishesTheFocusedNoteBeforeAnUnhandledEscapeClosesTheSheet() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        let surface = sheet.slot.surface
        let note = try XCTUnwrap(surface.textInputs.values.first)
        XCTAssertTrue(sheet.window.makeFirstResponder(note.responder))
        let editor = try XCTUnwrap(note.textEditor)
        XCTAssertTrue(sheet.window.firstResponder === editor)
        XCTAssertTrue(note.editing)
        XCTAssertTrue(surface.hasFocusedTextInput)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))

        editor.keyDown(with: escape)

        XCTAssertFalse(note.editing)
        XCTAssertFalse(surface.hasFocusedTextInput)
        XCTAssertTrue(sheet.window.firstResponder === surface.view)
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        XCTAssertNotNil(fixture.world.entry(for: sheet.token))
        XCTAssertTrue(parent.session.slots[sheet.metadata.rootID] === sheet.slot)

        sheet.window.firstResponder?.keyDown(with: escape)

        XCTAssertNil(parent.window.attachedSheet)
        XCTAssertNil(fixture.world.entry(for: sheet.token))
        XCTAssertNil(parent.session.slots[sheet.metadata.rootID])
        XCTAssertNotNil(fixture.world.entry(for: parent.token))
        XCTAssertFalse(parent.session.closed)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testClosingParentThroughManagedCommandDismissesOnlyItsSheet() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let sheet = try await openHostedSheet(parent, fixture: fixture)

        XCTAssertTrue(fixture.manager.close(parent.token))

        XCTAssertNil(fixture.manager.windows[sheet.token])
        XCTAssertNil(fixture.world.entry(for: sheet.token))
        XCTAssertTrue(fixture.manager.windows[parent.token] === parent.window)
        XCTAssertNotNil(fixture.world.entry(for: parent.token))
        XCTAssertNil(parent.window.attachedSheet)
        XCTAssertFalse(parent.session.closed)
        let request = try XCTUnwrap(fixture.controller.focusWindow(parent.token))
        XCTAssertEqual(request.token, parent.token)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
