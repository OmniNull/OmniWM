// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellNotificationsControllerTests: XCTestCase {
    private let fixtureBundle = "fixture.notifications"

    func testPreferenceReplacementRefreshesWithoutDatabaseChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferencesDirectory = directory.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferencesURL = preferencesDirectory.appendingPathComponent("settings.plist")
        let databaseURL = directory.appendingPathComponent("db")
        try Data().write(to: databaseURL)
        let allowed = ShellNotificationPreferences.notificationsAllowed
        let hidden = ShellNotificationPreferences.hiddenFromNotificationCenter
        try notificationPreferences([["bundle-id": fixtureBundle, "flags": allowed]]).write(to: preferencesURL)
        let controller = ShellNotificationsController(
            url: databaseURL,
            preferencesURL: preferencesURL,
            load: { [fixtureBundle] _ in
                let listed = ShellNotificationPreferences(contentsOf: preferencesURL)?
                    .lists(fixtureBundle, isInstalled: { _ in true }) ?? true
                return ShellNotificationsData(state: listed ? "ready" : "empty")
            }
        )
        controller.setListening(true)
        defer { controller.setListening(false) }
        await controller.task?.value
        XCTAssertEqual(controller.current.state, "ready")
        let before = ShellNotificationsController.StorageRevision.read(at: databaseURL)
        let refreshed = expectation(description: "preference-only change published")
        controller.onChange = { value in
            if value.state == "empty" { refreshed.fulfill() }
        }
        try notificationPreferences([["bundle-id": fixtureBundle, "flags": allowed | hidden]])
            .write(to: preferencesURL, options: .atomic)
        await fulfillment(of: [refreshed], timeout: failureBound)
        XCTAssertEqual(ShellNotificationsController.StorageRevision.read(at: databaseURL), before)
    }

    func testPreferenceOnlyChangeCannotRestoreADispatchedNotification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferencesDirectory = directory.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferencesURL = preferencesDirectory.appendingPathComponent("settings.plist")
        let databaseURL = directory.appendingPathComponent("db")
        try Data().write(to: databaseURL)
        try Data(UUID().uuidString.utf8).write(to: preferencesURL)
        let original = SettingsFileAccess.currentFingerprint(at: preferencesURL)
        let id = UUID()
        let snapshot = ShellNotificationsData(state: "ready", items: [.object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(fixtureBundle), "actions": .array([])
        ])])
        let readAfterRewrite = expectation(description: "read started after the preference rewrite")
        readAfterRewrite.assertForOverFulfill = false
        let controller = ShellNotificationsController(
            url: databaseURL,
            preferencesURL: preferencesURL,
            load: { _ in
                if SettingsFileAccess.currentFingerprint(at: preferencesURL) != original {
                    readAfterRewrite.fulfill()
                }
                return snapshot
            },
            perform: { _ in .dispatched }
        )
        controller.setListening(true)
        defer { controller.setListening(false) }
        await controller.task?.value
        XCTAssertTrue(controller.perform(.dismiss(bundle: fixtureBundle, id: id)))
        let action = try XCTUnwrap(controller.actionTask)
        await action.value
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        try Data(UUID().uuidString.utf8).write(to: preferencesURL, options: .atomic)
        await fulfillment(of: [readAfterRewrite], timeout: failureBound)
        await controller.task?.value
        XCTAssertEqual(controller.current.dispatched, [id.uuidString.lowercased()])
        XCTAssertEqual(controller.current.kept, 0)
    }

    func testClockHostFollowsTheOSReleaseAndFallsBackToTheOtherHost() {
        let pids: [String: pid_t] = [
            "com.apple.notificationcenterui": 1,
            "com.apple.MenuBarAgent": 2,
            "com.apple.controlcenter": 3
        ]
        func resolve(_ major: Int, without missing: String? = nil) -> pid_t? {
            ShellNotificationsController.nativeProcesses(osMajorVersion: major) {
                $0 == missing ? nil : pids[$0]
            }?.1
        }
        XCTAssertEqual(resolve(26), 3)
        XCTAssertEqual(resolve(27), 2)
        XCTAssertEqual(resolve(26, without: "com.apple.controlcenter"), 2)
        XCTAssertEqual(resolve(27, without: "com.apple.MenuBarAgent"), 3)
        XCTAssertNil(resolve(26, without: "com.apple.notificationcenterui"))
    }

    func testCenterCommandIsTheBareWord() {
        XCTAssertEqual(ShellAction("notifications center"), .notifications(.center))
        XCTAssertNil(ShellAction("notifications center now"))
    }

    func testCenterRunsItsPerformerOnceAndLeavesTheSnapshotAlone() async {
        let ran = expectation(description: "center performer ran")
        let controller = ShellNotificationsController(url: url(), showCenter: {
            ran.fulfill()
            return .dispatched
        })
        let before = controller.current
        XCTAssertTrue(controller.perform(.center))
        await fulfillment(of: [ran], timeout: failureBound)
        XCTAssertEqual(controller.current, before)
    }

    func testCenterIsRefusedWhileANativeActionIsInFlight() async throws {
        let id = UUID()
        let snapshot = ShellNotificationsData(state: "ready", items: [.object([
            "id": .text(id.uuidString.lowercased()), "bundle": .text(fixtureBundle), "actions": .array([])
        ])])
        let entered = expectation(description: "dismiss entered")
        let ran = expectation(description: "center performer ran")
        let release = AsyncStream<Void>.makeStream()
        let controller = ShellNotificationsController(
            url: url(),
            load: { _ in snapshot },
            perform: { _ in
                entered.fulfill()
                for await _ in release.stream { break }
                return .dispatched
            },
            showCenter: {
                ran.fulfill()
                return .dispatched
            }
        )
        controller.setListening(true)
        defer { controller.setListening(false) }
        await controller.task?.value
        XCTAssertTrue(controller.perform(.dismiss(bundle: fixtureBundle, id: id)))
        let action = try XCTUnwrap(controller.actionTask)
        await fulfillment(of: [entered], timeout: failureBound)
        XCTAssertFalse(controller.perform(.center))
        release.continuation.yield()
        await action.value
        XCTAssertTrue(controller.perform(.center))
        await fulfillment(of: [ran], timeout: failureBound)
    }

    private actor LoadGate {
        let entered: @Sendable (Int) -> Void
        let returned: @Sendable (Int) -> Void
        private var requests: [URL] = []
        private var pending: [Int: CheckedContinuation<ShellNotificationsData, Never>] = [:]

        init(entered: @escaping @Sendable (Int) -> Void, returned: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.entered = entered
            self.returned = returned
        }

        func load(_ url: URL) async -> ShellNotificationsData {
            let index = requests.count
            requests.append(url)
            let value = await withCheckedContinuation { continuation in
                pending[index] = continuation
                entered(index)
            }
            returned(index)
            return value
        }

        func complete(_ index: Int, with value: ShellNotificationsData) -> Bool {
            guard let continuation = pending.removeValue(forKey: index) else { return false }
            continuation.resume(returning: value)
            return true
        }

        var requestCount: Int {
            requests.count
        }

        func finishAll() {
            let continuations = Array(pending.values)
            pending.removeAll()
            for continuation in continuations {
                continuation.resume(returning: ShellNotificationsData(state: "loading"))
            }
        }
    }

    private func url() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uncreated/db")
    }

    private func data(_ id: String) -> ShellNotificationsData {
        ShellNotificationsData(
            state: "ready",
            items: [.object(["id": .text(id), "body": .text("Synthetic private body \(id)")])],
            apps: [.object(["bundle": .text(fixtureBundle)])]
        )
    }

    func testRepeatedListeningSharesOneReadAndStopClearsPublishedData() async {
        let entered = expectation(description: "one initial read")
        let published = expectation(description: "initial snapshot published")
        let gate = LoadGate(entered: { _ in entered.fulfill() })
        let controller = ShellNotificationsController(url: url(), load: { await gate.load($0) })
        let expected = data("initial")
        var values: [ShellNotificationsData] = []
        controller.onChange = { value in
            values.append(value)
            published.fulfill()
        }
        controller.setListening(true)
        controller.setListening(true)
        controller.setListening(true)
        await fulfillment(of: [entered], timeout: failureBound)
        let completed = await gate.complete(0, with: expected)
        XCTAssertTrue(completed)
        await fulfillment(of: [published], timeout: failureBound)
        XCTAssertEqual(controller.current, expected)
        XCTAssertEqual(values, [expected])
        controller.setListening(true)
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertTrue(controller.isListening)
        controller.setListening(false)
        XCTAssertFalse(controller.isListening)
        XCTAssertEqual(controller.current, ShellNotificationsData(state: "loading"))
        controller.refresh()
        controller.setListening(false)
        let stoppedCount = await gate.requestCount
        XCTAssertEqual(stoppedCount, 1)
        await gate.finishAll()
    }

    func testRefreshDuringReadCoalescesIntoOneFollowingRead() async {
        let firstStarted = expectation(description: "first read started")
        let secondStarted = expectation(description: "coalesced read started")
        let firstPublished = expectation(description: "first result published")
        let secondPublished = expectation(description: "second result published")
        let gate = LoadGate(entered: { index in
            if index == 0 { firstStarted.fulfill() }
            else if index == 1 { secondStarted.fulfill() }
            else { XCTFail("Refresh burst started an extra read") }
        })
        let controller = ShellNotificationsController(url: url(), load: { await gate.load($0) })
        let first = data("first")
        let second = data("second")
        var values: [ShellNotificationsData] = []
        controller.onChange = { value in
            values.append(value)
            if value == first { firstPublished.fulfill() }
            else if value == second { secondPublished.fulfill() }
            else { XCTFail("Unexpected snapshot published") }
        }
        controller.setListening(true)
        await fulfillment(of: [firstStarted], timeout: failureBound)
        for _ in 0 ..< 8 { controller.refresh() }
        let inFlightCount = await gate.requestCount
        XCTAssertEqual(inFlightCount, 1)
        let completedFirst = await gate.complete(0, with: first)
        XCTAssertTrue(completedFirst)
        await fulfillment(of: [firstPublished, secondStarted], timeout: failureBound)
        let completedSecond = await gate.complete(1, with: second)
        XCTAssertTrue(completedSecond)
        await fulfillment(of: [secondPublished], timeout: failureBound)
        XCTAssertEqual(values, [first, second])
        XCTAssertEqual(controller.current, second)
        let count = await gate.requestCount
        XCTAssertEqual(count, 2)
        controller.setListening(false)
        await gate.finishAll()
    }

    func testCancelledCompletionCannotOverwriteRestartedGeneration() async {
        let oldStarted = expectation(description: "old generation read started")
        let newStarted = expectation(description: "new generation read started")
        let followingStarted = expectation(description: "new generation remains refreshable")
        let oldReturned = expectation(description: "cancelled loader returns")
        let freshPublished = expectation(description: "new result published")
        let followingPublished = expectation(description: "following result published")
        let gate = LoadGate(entered: { index in
            switch index {
            case 0: oldStarted.fulfill()
            case 1: newStarted.fulfill()
            case 2: followingStarted.fulfill()
            default: XCTFail("Unexpected additional read")
            }
        }, returned: { index in if index == 0 { oldReturned.fulfill() } })
        let controller = ShellNotificationsController(url: url(), load: { await gate.load($0) })
        let stale = data("cancelled")
        let fresh = data("fresh")
        let following = data("following")
        var values: [ShellNotificationsData] = []
        controller.onChange = { value in
            values.append(value)
            if value == fresh { freshPublished.fulfill() }
            else if value == following { followingPublished.fulfill() }
            else { XCTFail("Cancelled generation published private data") }
        }
        controller.setListening(true)
        await fulfillment(of: [oldStarted], timeout: failureBound)
        controller.refresh()
        controller.setListening(false)
        XCTAssertEqual(controller.current, ShellNotificationsData(state: "loading"))
        controller.setListening(true)
        await fulfillment(of: [newStarted], timeout: failureBound)
        let completedFresh = await gate.complete(1, with: fresh)
        XCTAssertTrue(completedFresh)
        await fulfillment(of: [freshPublished], timeout: failureBound)
        let completedStale = await gate.complete(0, with: stale)
        XCTAssertTrue(completedStale)
        await fulfillment(of: [oldReturned], timeout: failureBound)
        controller.refresh()
        await fulfillment(of: [followingStarted], timeout: failureBound)
        let completedFollowing = await gate.complete(2, with: following)
        XCTAssertTrue(completedFollowing)
        await fulfillment(of: [followingPublished], timeout: failureBound)
        XCTAssertEqual(values, [fresh, following])
        XCTAssertEqual(controller.current, following)
        let count = await gate.requestCount
        XCTAssertEqual(count, 3)
        controller.setListening(false)
        await gate.finishAll()
    }
}
