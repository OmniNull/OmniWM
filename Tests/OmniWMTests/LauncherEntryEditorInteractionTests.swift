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
    final class LauncherEntryEditorInteractionTests: XCTestCase {
        func testRunningSavedDraftKeepsEditorOpenAndSavesTheSameEdits() async throws {
            try requireNativeInteraction()
            var entry = LauncherEntry()
            entry.name = "Original command"
            entry.command = "printf original"
            let fixture = Fixture(entry: entry, runOnly: false)
            defer { fixture.close() }
            await fixture.present()
            await fulfillment(of: [fixture.appeared, fixture.beganSheet], timeout: failureBound)
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)
            try await fixture.enter("Edited command", replacing: "Original command", in: sheet)
            try await fixture.enter("printf edited", replacing: "printf original", in: sheet)
            sheet.makeFirstResponder(nil)
            await fixture.display()

            try await fixture.click("Run Now", in: sheet)
            await fulfillment(of: [fixture.ran], timeout: failureBound)
            await fixture.display()
            XCTAssertTrue(fixture.window.attachedSheet === sheet)
            XCTAssertEqual(fixture.dismissals, 0)
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertFalse(try fixture.renderedBounds(for: "Test launch failure", in: sheet).isEmpty)
            let ran = try XCTUnwrap(fixture.executed.first)
            XCTAssertEqual(ran.name, "Edited command")
            XCTAssertEqual(ran.command, "printf edited")

            try await fixture.click("Save", in: sheet)
            await fulfillment(of: [fixture.didSave, fixture.dismissed], timeout: failureBound)
            XCTAssertEqual(fixture.executed, [ran])
            XCTAssertEqual(fixture.saved, [ran])
            XCTAssertEqual(fixture.dismissals, 1)
            XCTAssertNil(fixture.window.attachedSheet)
        }

        func testRunningOneOffCLIDismissesWithoutSaving() async throws {
            try requireNativeInteraction()
            var entry = LauncherEntry()
            entry.name = "true"
            entry.kind = .executable
            entry.path = "/usr/bin/true"
            let fixture = Fixture(entry: entry, runOnly: true)
            defer { fixture.close() }
            await fixture.present()
            await fulfillment(of: [fixture.appeared, fixture.beganSheet], timeout: failureBound)
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)

            try await fixture.click("Run", in: sheet)
            await fulfillment(of: [fixture.ran, fixture.dismissed], timeout: failureBound)
            XCTAssertEqual(fixture.executed, [entry])
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertEqual(fixture.dismissals, 1)
            XCTAssertNil(fixture.window.attachedSheet)
        }

        private func requireNativeInteraction() throws {
            _ = NSApplication.shared
        }

        @MainActor
        private final class Fixture {
            let window: NSWindow
            let appeared = XCTestExpectation(description: "Editor appeared")
            let beganSheet = XCTestExpectation(description: "Editor sheet presentation began")
            let ran = XCTestExpectation(description: "Editor ran the draft")
            let didSave = XCTestExpectation(description: "Editor saved the draft")
            let dismissed = XCTestExpectation(description: "Editor sheet dismissed")
            var executed: [LauncherEntry] = []
            var saved: [LauncherEntry] = []
            var dismissals = 0
            private var sheetObserver: NSObjectProtocol?
            private let originalActivationPolicy: NSApplication.ActivationPolicy
            private let originalOutcome: LauncherExecution.Outcome?

            init(entry: LauncherEntry, runOnly: Bool) {
                originalActivationPolicy = NSApp.activationPolicy()
                originalOutcome = LauncherExecution.shared.outcome
                XCTAssertTrue(NSApp.setActivationPolicy(.accessory))
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false
                )
                window.animationBehavior = .none
                window.hasShadow = false
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: SheetHost(
                    entry: entry, runOnly: runOnly,
                    onAppear: { [weak self] in self?.appeared.fulfill() },
                    onDismiss: { [weak self] in
                        self?.dismissals += 1
                        self?.dismissed.fulfill()
                    },
                    save: { [weak self] entry in
                        self?.saved.append(entry)
                        self?.didSave.fulfill()
                    },
                    run: { [weak self] entry in
                        self?.executed.append(entry)
                        if !runOnly {
                            LauncherExecution.shared.outcome = .init(
                                name: entry.name, message: "Test launch failure", output: "", failed: true
                            )
                        }
                        self?.ran.fulfill()
                    }
                ))
                let beganSheet = beganSheet
                sheetObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willBeginSheetNotification, object: window, queue: .main
                ) { _ in beganSheet.fulfill() }
            }

            func present() async {
                window.center()
                window.orderBack(nil)
                await display()
            }

            func display() async {
                await withCheckedContinuation { continuation in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    CATransaction.setCompletionBlock { continuation.resume() }
                    NSApp.updateWindows()
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    window.attachedSheet?.displayIfNeeded()
                    CATransaction.commit()
                    CATransaction.flush()
                }
            }

            func enter(_ value: String, replacing text: String, in sheet: NSWindow) async throws {
                try await click(text, in: sheet)
                let editor = try XCTUnwrap(sheet.firstResponder as? NSTextView)
                editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
                editor.insertText(value, replacementRange: editor.selectedRange())
                await display()
            }

            func click(_ title: String, in sheet: NSWindow) async throws {
                sheet.makeKey()
                await display()
                let bounds = try renderedBounds(for: title, in: sheet)
                let view = try XCTUnwrap(sheet.contentView)
                let y = view.isFlipped ? view.bounds.maxY - bounds.midY * view.bounds.height
                    : view.bounds.minY + bounds.midY * view.bounds.height
                let point = view.convert(NSPoint(x: view.bounds.minX + bounds.midX * view.bounds.width, y: y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ))
                    sheet.sendEvent(event)
                }
            }

            func renderedBounds(for title: String, in sheet: NSWindow) throws -> CGRect {
                let view = try XCTUnwrap(sheet.contentView)
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
                }.sorted { $0.midY < $1.midY }.first, "Missing rendered control: \(title)")
            }

            func close() {
                if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.contentViewController = nil
                window.close()
                _ = NSApp.setActivationPolicy(originalActivationPolicy)
                LauncherExecution.shared.outcome = originalOutcome
            }
        }

        private struct SheetHost: View {
            @State private var presented = false
            let entry: LauncherEntry
            let runOnly: Bool
            let onAppear: () -> Void
            let onDismiss: () -> Void
            let save: (LauncherEntry) -> Void
            let run: (LauncherEntry) -> Void

            var body: some View {
                Color.clear
                    .onAppear { presented = true }
                    .sheet(isPresented: $presented, onDismiss: onDismiss) {
                        LauncherEntryEditor(entry: entry, runOnly: runOnly, save: save, run: run)
                            .transaction { $0.animation = nil }
                            .onAppear(perform: onAppear)
                    }
            }
        }
    }
#endif
