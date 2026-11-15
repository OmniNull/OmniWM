// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import SwiftUI
import Vision
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class AppRulesInteractionTests: XCTestCase {
        private static let wideSize = NSSize(width: 1040, height: 680)
        private static let narrowSize = NSSize(width: 700, height: 680)

        func testDraggingTheDividerResizesTheRuleListUpToTheEditorReserve() async throws {
            let fixture = try Fixture(layoutDirection: .leftToRight)
            defer { fixture.close() }
            try await fixture.present()

            try await fixture.dragDivider(by: 80)
            XCTAssertEqual(fixture.editorState.sidebarWidth, 310)

            try await fixture.dragDivider(by: 2000)
            XCTAssertEqual(fixture.editorState.sidebarWidth, 609)
        }

        func testDraggingTheDividerTowardTheEditorWidensTheRuleListRightToLeft() async throws {
            let fixture = try Fixture(layoutDirection: .rightToLeft)
            defer { fixture.close() }
            try await fixture.present()

            try await fixture.dragDivider(by: -30)
            XCTAssertEqual(fixture.editorState.sidebarWidth, 260)
        }

        func testDragInterruptedByTheNarrowLayoutDoesNotLeakItsStartingWidth() async throws {
            let fixture = try Fixture(layoutDirection: .leftToRight)
            defer { fixture.close() }
            try await fixture.present()

            let start = fixture.dividerPoint()
            try fixture.send(.leftMouseDown, at: start)
            try fixture.send(.leftMouseDragged, at: NSPoint(x: start.x + 70, y: start.y))
            await fixture.display()
            XCTAssertEqual(fixture.editorState.sidebarWidth, 300)
            await fixture.resize(to: Self.narrowSize)
            try fixture.send(.leftMouseUp, at: NSPoint(x: start.x + 70, y: start.y))
            await fixture.resize(to: Self.wideSize)

            try await fixture.dragDivider(by: 10)
            XCTAssertEqual(fixture.editorState.sidebarWidth, 310)
        }

        func testCrossingTheWideBreakpointKeepsTheUnsavedRuleDraft() async throws {
            let fixture = try Fixture(layoutDirection: .leftToRight)
            defer { fixture.close() }
            try await fixture.present()

            try await fixture.click("Editor")
            try await fixture.click("Float")
            XCTAssertTrue(fixture.editorState.isDirty)
            XCTAssertNoThrow(try fixture.renderedBounds(for: "Unsaved changes"))

            await fixture.resize(to: Self.narrowSize)
            XCTAssertTrue(fixture.editorState.isDirty)
            XCTAssertNoThrow(try fixture.renderedBounds(for: "Unsaved changes"))

            await fixture.resize(to: Self.wideSize)
            XCTAssertTrue(fixture.editorState.isDirty)
            XCTAssertNoThrow(try fixture.renderedBounds(for: "Unsaved changes"))
        }

        func testArrowKeysMoveTheFocusedDivider() async throws {
            let fixture = try Fixture(layoutDirection: .leftToRight)
            defer { fixture.close() }
            try await fixture.present()

            let point = fixture.dividerPoint()
            try fixture.send(.leftMouseDown, at: point)
            try fixture.send(.leftMouseUp, at: point)
            await fixture.display()
            try fixture.pressArrow(NSRightArrowFunctionKey, keyCode: 124)
            await fixture.display()
            XCTAssertEqual(fixture.editorState.sidebarWidth, 250)
            try fixture.pressArrow(NSLeftArrowFunctionKey, keyCode: 123)
            await fixture.display()
            XCTAssertEqual(fixture.editorState.sidebarWidth, 230)
        }

        @MainActor
        private final class Fixture {
            let window: NSWindow
            let editorState = AppRulesEditorState()
            private let directory: URL
            private let layoutDirection: LayoutDirection
            private let originalActivationPolicy: NSApplication.ActivationPolicy

            init(layoutDirection: LayoutDirection) throws {
                self.layoutDirection = layoutDirection
                originalActivationPolicy = NSApplication.shared.activationPolicy()
                XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
                directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AppRulesInteractionTests-\(UUID().uuidString)")
                let settings = SettingsStore(
                    persistence: SettingsFilePersistence(
                        directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
                    ),
                    runtimeState: RuntimeStateStore(
                        directory: directory.appendingPathComponent("state"),
                        deferSaves: false
                    ),
                    autosaveEnabled: false
                )
                settings.workspaceBar.enabled = false
                settings.island.enabled = false
                settings.animationsEnabled = false
                settings.hotkeyBindings = []
                settings.appRules = [AppRule(bundleId: "com.example.Editor", layout: .tile)]
                let controller = WMController(
                    settings: settings,
                    clipboardHistoryDirectory: directory.appendingPathComponent("clipboard"),
                    diagnosticsDirectory: directory.appendingPathComponent("diagnostics"),
                    ownedWindowRegistry: OwnedWindowRegistry()
                )
                window = KeyPanel(
                    contentRect: NSRect(origin: .zero, size: AppRulesInteractionTests.wideSize),
                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false
                )
                window.animationBehavior = .none
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                let host = NSHostingController(rootView: AppRulesView(
                    settings: settings, controller: controller, editorState: editorState
                )
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.layoutDirection, layoutDirection)
                .transaction { $0.animation = nil })
                host.sizingOptions = []
                window.contentViewController = host
                window.setContentSize(AppRulesInteractionTests.wideSize)
            }

            func present() async throws {
                window.center()
                window.makeKeyAndOrderFront(nil)
                await display()
                _ = try XCTUnwrap(
                    window.isKeyWindow ? window : nil,
                    "The test window must become key; run App Rules interaction checks in an unlocked session"
                )
            }

            func display() async {
                await withCheckedContinuation { continuation in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    CATransaction.setCompletionBlock { continuation.resume() }
                    NSApp.updateWindows()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    CATransaction.commit()
                    CATransaction.flush()
                }
            }

            func resize(to size: NSSize) async {
                window.setContentSize(size)
                await display()
            }

            func dividerPoint() -> NSPoint {
                let bounds = window.contentView?.bounds ?? .zero
                let inset = 12 + editorState.sidebarWidth + AppRulesSidebarSizing.handleWidth / 2
                let x = layoutDirection == .rightToLeft ? bounds.maxX - inset : bounds.minX + inset
                return window.contentView?.convert(NSPoint(x: x, y: bounds.midY), to: nil) ?? .zero
            }

            func dragDivider(by offset: CGFloat) async throws {
                let start = dividerPoint()
                try send(.leftMouseDown, at: start)
                for step in 1 ... 4 {
                    try send(.leftMouseDragged, at: NSPoint(x: start.x + offset * CGFloat(step) / 4, y: start.y))
                }
                try send(.leftMouseUp, at: NSPoint(x: start.x + offset, y: start.y))
                await display()
            }

            func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                ))
                window.sendEvent(event)
            }

            func pressArrow(_ functionKey: Int, keyCode: UInt16) throws {
                let characters = try String(XCTUnwrap(UnicodeScalar(functionKey)))
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = try XCTUnwrap(NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [.function, .numericPad],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                        keyCode: keyCode
                    ))
                    window.sendEvent(event)
                }
            }

            func click(_ title: String) async throws {
                await display()
                let bounds = try renderedBounds(for: title)
                let view = try XCTUnwrap(window.contentView)
                let y = view.isFlipped ? view.bounds.maxY - bounds.midY * view.bounds.height
                    : view.bounds.minY + bounds.midY * view.bounds.height
                let point = view.convert(NSPoint(x: view.bounds.minX + bounds.midX * view.bounds.width, y: y), to: nil)
                try send(.leftMouseDown, at: point)
                try send(.leftMouseUp, at: point)
                await display()
            }

            func renderedBounds(for title: String) throws -> CGRect {
                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = [title]
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                return try XCTUnwrap((request.results ?? []).compactMap { observation -> CGRect? in
                    guard let text = observation.topCandidates(1).first,
                          let range = text.string.range(of: title, options: [.caseInsensitive]) else { return nil }
                    return try text.boundingBox(for: range)?.boundingBox
                }.max { $0.midY < $1.midY }, "Missing rendered text: \(title)")
            }

            func close() {
                window.contentViewController = nil
                window.close()
                _ = NSApp.setActivationPolicy(originalActivationPolicy)
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private final class KeyPanel: NSPanel {
            override var canBecomeKey: Bool {
                true
            }
        }
    }
#endif
