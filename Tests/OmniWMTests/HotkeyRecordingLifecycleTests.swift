// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class HotkeyRecordingLifecycleTests: XCTestCase {
    func testScrollingRecordingRowOffscreenCancelsRecording() async throws {
        let bindings = HotkeyBindingRegistry.defaults()
        let binding = try XCTUnwrap(bindings.first)
        let state = RecordingState(target: .chord(binding.id))
        let focused = expectation(description: "Native recorder receives keyboard focus")
        let cancelled = expectation(description: "Offscreen recording is cancelled")
        let window = RecordingWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.onRecorderFocused = { focused.fulfill() }
        let host = NSHostingView(rootView: RecordingFixture(state: state, bindings: bindings) {
            state.target = nil
            cancelled.fulfill()
        })
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [focused], timeout: 3)

        let recorder = try XCTUnwrap(window.firstResponder as? KeyRecorderNSView)
        let scroll = try XCTUnwrap(recorder.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(state.target, .chord(binding.id))
        scroll.contentView.scroll(to: CGPoint(
            x: 0,
            y: max(0, document.bounds.height - scroll.contentView.bounds.height)
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [cancelled], timeout: 3)

        XCTAssertNil(state.target)
        XCTAssertFalse(window.firstResponder === recorder)
    }
}

@MainActor
@Observable
private final class RecordingState {
    var target: HotkeyRecordingTarget?

    init(target: HotkeyRecordingTarget?) {
        self.target = target
    }
}

private struct RecordingFixture: View {
    @Bindable var state: RecordingState
    let bindings: [HotkeyBinding]
    let onCancel: () -> Void

    var body: some View {
        HotkeySettingsPage(subtitle: "Shortcuts") {
            Section("Commands") {
                ForEach(bindings) { binding in
                    HotkeyBindingRow(
                        binding: binding,
                        recordingTarget: $state.target,
                        failureReason: nil,
                        pausedDuringSecureInput: false,
                        isHyperActive: { false },
                        onStartChordRecording: { state.target = .chord($0) },
                        onChordCaptured: { _, _ in },
                        onCancelRecording: onCancel,
                        onClearBinding: { _ in },
                        onResetBindings: { _ in },
                        onSetSide: { _, _ in }
                    )
                }
            }
        }
    }
}

private final class RecordingWindow: NSWindow {
    var onRecorderFocused: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, responder is KeyRecorderNSView {
            let callback = onRecorderFocused
            onRecorderFocused = nil
            callback?()
        }
        return accepted
    }
}
