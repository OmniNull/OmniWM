// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class HostedWindowShutdownTests: XCTestCase {
    private let completionFailureDeadline: TimeInterval = 10

    func testShutdownTwiceRemovesEachHostedWindowOnceWithoutRecoveringFocus() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let first = try fixture.open()
        let second = try fixture.open()
        let instances = [first, second]
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        for instance in instances { await readyHosted(instance.session) }
        try fixture.select(first)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let previousRemoval = fixture.world.onWindowRemoved
        var removed: [WindowToken] = []
        fixture.world.onWindowRemoved = { entry in
            previousRemoval?(entry)
            removed.append(entry.token)
        }
        defer { fixture.world.onWindowRemoved = previousRemoval }
        let tokensByWindow = Dictionary(uniqueKeysWithValues: instances.map {
            (ObjectIdentifier($0.window), $0.token)
        })
        let nativeCloses = Mutex<[WindowToken: Int]>([:])
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  let token = tokensByWindow[ObjectIdentifier(window)] else { return }
            nativeCloses.withLock { $0[token, default: 0] += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.manager.windowWillStartLiveResize(
            fixture.notification(first.window, name: NSWindow.willStartLiveResizeNotification)
        )
        XCTAssertNotNil(fixture.manager.liveResizeStarts[first.token])
        XCTAssertNotNil(fixture.controller.focusWindow(second.token))
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, second.token)
        let latestIntent = fixture.controller.intentLedger.newestFocusIntentId()
        fixture.clearOperations()

        fixture.manager.shutdown()
        let registeredRetirements = Set(ShellWidgetHost.retiringTasks.keys)
        fixture.manager.shutdown()
        fixture.manager.windowWillClose(fixture.notification(first.window, name: NSWindow.willCloseNotification))

        XCTAssertEqual(Set(ShellWidgetHost.retiringTasks.keys), registeredRetirements)
        XCTAssertEqual(Set(removed), Set(instances.map(\.token)))
        XCTAssertEqual(removed.count, instances.count)
        XCTAssertEqual(nativeCloses.withLock { $0 }, Dictionary(uniqueKeysWithValues: instances.map { ($0.token, 1) }))
        XCTAssertTrue(fixture.manager.isShuttingDown)
        XCTAssertTrue(fixture.manager.windows.isEmpty)
        XCTAssertTrue(fixture.manager.runtimes.isEmpty)
        XCTAssertTrue(fixture.manager.liveResizeStarts.isEmpty)
        XCTAssertTrue(fixture.manager.applyingFrames.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.world.pendingFocusedToken)
        XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), latestIntent)
        XCTAssertEqual(fixture.activationCount, 0)
        XCTAssertNotNil(fixture.world.entry(for: fixture.external))
        XCTAssertFalse(fixture.manager.open(fixture.definition, in: fixture.source))
        XCTAssertFalse(fixture.manager.newWindow(fixture.definition.id))
        for instance in instances {
            XCTAssertNil(fixture.world.entry(for: instance.token))
            XCTAssertTrue(instance.session.closed)
            XCTAssertNil(instance.session.surface.onAction)
            XCTAssertFalse(instance.window.operations.contains(.front))
            XCTAssertFalse(instance.window.operations.contains(.focus))
            assertLateTreeRejected(by: instance.session)
        }
        await ShellWidgetHost.flushRetiredWork()
    }

    func testQuitPreparationAwaitsActualHostedPackageRetirement() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let clipboard = try HostedShutdownClipboard()
        defer { try? clipboard.close() }
        fixture.controller.clipboardHistoryService = clipboard.service
        let held = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        await readyHosted(held.session)
        await readyHosted(sibling.session)
        let package = held.session.package
        let entered = expectation(description: "Existing provider reconciliation is held by the fixture")
        let gate = HostedShutdownRetirementGate { entered.fulfill() }
        let installed = await package.gateHostedRetirement(gate)
        XCTAssertTrue(installed)
        await fulfillment(of: [entered], timeout: completionFailureDeadline)
        let closeBegan = expectation(description: "Actual package close cancels its registered service")
        let owner = ShellServiceOwner(generation: package.services.generation, owner: .max, epoch: .zero)
        let service = ShellServiceID(owner: owner, request: .max)
        XCTAssertTrue(package.services.register(service) { closeBegan.fulfill() })
        let delegate = AppDelegate()
        var preparationCompleted = false
        var events: [RetirementEvent] = []
        let preparation = Task {
            let accepted = await delegate.prepareShellForQuit(controller: fixture.controller) { error in
                XCTFail("Empty fixture clipboard should flush: \(error)")
                return false
            }
            preparationCompleted = true
            events.append(.preparationCompleted)
            return accepted
        }
        await fulfillment(of: [closeBegan], timeout: completionFailureDeadline)
        let retirement = ShellWidgetHost.retiringTasks[ObjectIdentifier(package)]
        XCTAssertNotNil(retirement)
        XCTAssertFalse(preparationCompleted)
        XCTAssertTrue(fixture.manager.runtimes.isEmpty)
        XCTAssertTrue(held.session.closed)
        XCTAssertTrue(sibling.session.closed)
        XCTAssertFalse(package.services.contains(service))

        events.append(.retirementReleased)
        await gate.release()
        let accepted = await preparation.value
        await retirement?.value

        XCTAssertTrue(accepted)
        XCTAssertTrue(preparationCompleted)
        XCTAssertEqual(events, [.retirementReleased, .preparationCompleted])
        XCTAssertNil(ShellWidgetHost.retiringTasks[ObjectIdentifier(package)])
        XCTAssertNil(fixture.world.entry(for: held.token))
        XCTAssertNil(fixture.world.entry(for: sibling.token))
        XCTAssertNotNil(fixture.world.entry(for: fixture.external))
    }

    func testDecliningClipboardDiscardPreservesHostedSessionsAndInput() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let first = try fixture.open()
        let second = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let firstText = "Keep the first hosted document"
        let secondText = "Keep the independent sibling document"
        try await applyHosted(firstText, to: first.session)
        try await applyHosted(secondText, to: second.session)
        let firstPackage = first.session.package
        let secondPackage = second.session.package
        let clipboard = try HostedShutdownClipboard()
        defer { try? clipboard.close() }
        try clipboard.preventSaving()
        fixture.controller.clipboardHistoryService = clipboard.service
        let captured = expectation(description: "Fixture clipboard capture is published")
        clipboard.service.onPaletteItemsChanged = { items in
            guard items.map(\.title) == [clipboard.value] else { return }
            clipboard.service.onPaletteItemsChanged = nil
            captured.fulfill()
        }
        clipboard.capture()
        await fulfillment(of: [captured], timeout: completionFailureDeadline)
        XCTAssertNotNil(clipboard.timer.action)
        var confirmations = 0
        fixture.clearOperations()

        let accepted = await AppDelegate().prepareShellForQuit(controller: fixture.controller) { _ in
            confirmations += 1
            return false
        }

        XCTAssertFalse(accepted)
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(clipboard.timer.action)
        XCTAssertEqual(clipboard.service.paletteItems.map(\.title), [clipboard.value])
        XCTAssertFalse(fixture.manager.isShuttingDown)
        XCTAssertTrue(fixture.manager.windows[first.token] === first.window)
        XCTAssertTrue(fixture.manager.windows[second.token] === second.window)
        XCTAssertTrue(fixture.manager.runtime(for: first.token) === first.session)
        XCTAssertTrue(fixture.manager.runtime(for: second.token) === second.session)
        XCTAssertTrue(first.session.package === firstPackage)
        XCTAssertTrue(second.session.package === secondPackage)
        XCTAssertNotNil(fixture.world.entry(for: first.token))
        XCTAssertNotNil(fixture.world.entry(for: second.token))
        XCTAssertFalse(first.session.closed)
        XCTAssertFalse(second.session.closed)
        XCTAssertEqual(fixture.activationCount, 0)
        assertHostedContent(firstText, in: first.session)
        assertHostedContent(secondText, in: second.session)
        let nextFirstText = firstText + " after canceling quit"
        let nextSecondText = secondText + " after canceling quit"
        try await applyHosted(nextFirstText, to: first.session)
        try await applyHosted(nextSecondText, to: second.session)
        assertHostedContent(nextFirstText, in: first.session)
        assertHostedContent(nextSecondText, in: second.session)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    private func assertLateTreeRejected(by session: ShellAppRuntime) {
        let sequence = session.renderedSequence
        var delivery = ShellWidgetDelivery(generation: ShellAppRuntime.generation)
        delivery.trees[ShellTreeKey(instance: .window(session.id), view: .window)] = .init(sequence: sequence + 1)
        session.receive(delivery)
        XCTAssertEqual(session.renderedSequence, sequence)
    }

    private enum RetirementEvent {
        case retirementReleased
        case preparationCompleted
    }
}
