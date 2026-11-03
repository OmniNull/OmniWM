// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon.HIToolbox
@testable import OmniWM
import XCTest

@MainActor
final class HostedNativeWindowInputTests: XCTestCase {
    func testBlockedUtilityConsumesKeyInputAndForwardsWindowEvents() throws {
        let definition = try XCTUnwrap(ShellAppDefinition.example)
        let parent = SheetInputParent(
            contentRect: CGRect(origin: .zero, size: definition.contentSize),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        parent.isReleasedWhenClosed = false
        let window = ShellAppWindowManager.makeWindow(definition)
        let sheet = ShellAppWindowManager.makeWindow(definition)
        defer {
            parent.presentedSheet = nil
            parent.removeChildWindow(window)
            window.close()
            sheet.close()
            parent.close()
        }
        let view = InputRecordingView(frame: CGRect(origin: .zero, size: definition.contentSize))
        window.contentView = view
        window.delegate = view
        parent.addChildWindow(window, ordered: .above)
        XCTAssertTrue(window.makeFirstResponder(view))
        let location = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)
        ))
        let exposure = try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            subtype: NSEvent.EventSubtype.windowExposed.rawValue, data1: 0, data2: 0
        ))

        window.sendEvent(key)
        XCTAssertEqual(view.received, [key])
        view.received.removeAll()
        parent.presentedSheet = sheet
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.ignoresMouseEvents)

        window.sendEvent(key)
        XCTAssertTrue(view.received.isEmpty)
        XCTAssertTrue(view.exposedWindows.isEmpty)
        window.sendEvent(exposure)
        XCTAssertEqual(view.exposedWindows, [window])

        parent.presentedSheet = nil
        window.sendEvent(key)
        XCTAssertEqual(view.received, [key])
        XCTAssertFalse(window.ignoresMouseEvents)
    }
}

@MainActor
private final class SheetInputParent: NSWindow {
    var presentedSheet: NSWindow?
    override var attachedSheet: NSWindow? {
        presentedSheet
    }
}

@MainActor
private final class InputRecordingView: NSView, NSWindowDelegate {
    var received: [NSEvent] = []
    var exposedWindows: [NSWindow] = []
    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        received.append(event)
    }

    func windowDidExpose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { exposedWindows.append(window) }
    }
}
