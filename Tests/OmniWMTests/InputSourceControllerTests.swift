// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class InputSourceControllerTests: XCTestCase {
    private let notifications = [
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
    ]

    func testInputSourceChangesAreReadAfterTheNotificationReturns() async {
        for name in notifications {
            let center = NotificationCenter()
            let previous = source("previous")
            let next = source("next")
            let reader = Reader(previous)
            let controller = InputSourceController(notificationCenter: center, read: reader.read)
            controller.setListening(true)
            defer { controller.setListening(false) }
            XCTAssertEqual(controller.value, previous)
            XCTAssertEqual(reader.reads, 1)

            let changed = expectation(description: "Input source updated after \(name)")
            controller.onChange = { value in
                XCTAssertEqual(value, next)
                changed.fulfill()
            }
            center.post(name: name, object: nil)
            XCTAssertEqual(reader.reads, 1)
            XCTAssertEqual(controller.value, previous)
            reader.current = next

            await fulfillment(of: [changed], timeout: failureBound)
            XCTAssertEqual(controller.value, next)
            XCTAssertEqual(reader.reads, 2)
        }
    }

    func testQueuedInputSourceChangesDoNotReadOrPublishAfterListeningStops() async {
        for name in notifications {
            let center = NotificationCenter()
            let current = source("current")
            let reader = Reader(current)
            let controller = InputSourceController(notificationCenter: center, read: reader.read)
            controller.setListening(true)
            defer { controller.setListening(false) }
            XCTAssertEqual(controller.value, current)
            XCTAssertEqual(reader.reads, 1)

            controller.onChange = { _ in XCTFail("Input source published after stopping \(name)") }
            center.post(name: name, object: nil)
            controller.setListening(false)
            let readsAtStop = reader.reads
            XCTAssertNil(controller.value)

            await Task { @MainActor in }.value
            XCTAssertNil(controller.value)
            XCTAssertEqual(reader.reads, readsAtStop)
        }
    }

    private func source(_ id: String) -> ShellInputSource {
        let entry = ShellInputSourceEntry(id: id, name: id, short: id.uppercased())
        return ShellInputSource(current: entry, sources: [entry])
    }

    @MainActor
    private final class Reader {
        var current: ShellInputSource
        private(set) var reads = 0

        init(_ current: ShellInputSource) {
            self.current = current
        }

        func read() -> ShellInputSource? {
            reads += 1
            return current
        }
    }
}
