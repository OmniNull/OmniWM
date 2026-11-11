// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class InputSourceIntegrationTests: XCTestCase {
    private let selectionChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    private let enabledSourcesChanged = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)

    func testInputSourceChangesReachTheWidgetWhileNotificationsAreSuspended() async throws {
        let center = ScopedInputSourceNotificationCenter()
        let distributed = DistributedNotificationCenter.default()
        let wasSuspended = distributed.suspended
        distributed.suspended = false
        defer { distributed.suspended = wasSuspended }

        let abc = ShellInputSourceEntry(id: "abc", name: "ABC", short: "EN")
        let german = ShellInputSourceEntry(id: "de", name: "German", short: "DE")
        let sources = [abc, german]
        let initial = ShellInputSource(current: abc, sources: sources)
        let input = InputSourceState(initial)
        let controller = InputSourceController(notificationCenter: center, read: { input.value })
        let widget = try ShellRenderedWidget("input-source")
        var published: XCTestExpectation?
        let feed = ShellDataFeed(devices: ShellDevices(inputSource: controller)) { data in
            guard let source = data.inputSource else { return }
            widget.set("inputSource") { source.write(into: &$0) }
            widget.render(ShellBarData())
            published?.fulfill()
        }
        feed.start()
        defer { feed.stop() }
        let demand = ShellDataKey.inputSource.bit
        feed.setDemand(demand, cadence: .of([(demand, nil)]))
        assertWidget(widget, shows: initial)

        distributed.suspended = true
        let changes: [(Notification.Name, ShellInputSource)] = [
            (selectionChanged, ShellInputSource(current: german, sources: sources)),
            (selectionChanged, initial),
            (enabledSourcesChanged, ShellInputSource(current: abc, sources: [abc]))
        ]
        for (name, source) in changes {
            input.value = source
            let changed = expectation(description: "Input source published for \(name.rawValue)")
            published = changed
            center.post(name)
            guard await XCTWaiter.fulfillment(of: [changed], timeout: failureBound) == .completed else {
                XCTFail("No input source update for \(name.rawValue) while notifications were suspended")
                return
            }
            published = nil
            XCTAssertEqual(feed.current.inputSource, source)
            assertWidget(widget, shows: source)
        }
    }

    func testKeyboardLayoutObserverReceivesEachChangeWhileNotificationsAreSuspended() async {
        let center = ScopedInputSourceNotificationCenter()
        let distributed = DistributedNotificationCenter.default()
        let wasSuspended = distributed.suspended
        distributed.suspended = false
        defer { distributed.suspended = wasSuspended }

        let observer = KeyboardLayoutObserver(notificationCenter: center)
        var changed: XCTestExpectation?
        observer.observe { changed?.fulfill() }
        defer { observer.observe(nil) }

        distributed.suspended = true
        for index in 1 ... 2 {
            let delivered = expectation(description: "Layout change \(index) delivered while suspended")
            changed = delivered
            center.post(selectionChanged)
            guard await XCTWaiter.fulfillment(of: [delivered], timeout: failureBound) == .completed else {
                XCTFail("Layout change \(index) was not delivered while notifications were suspended")
                return
            }
        }
    }

    func testKeyboardLayoutObserverRemovesItsRegistrationWhenObservationStops() async {
        let center = TrackingNotificationCenter()
        let observer = KeyboardLayoutObserver(notificationCenter: center)
        let delivered = expectation(description: "Layout change delivered while observing")
        observer.observe { delivered.fulfill() }
        XCTAssertEqual(center.registeredObserverCount, 1)
        center.post(name: selectionChanged, object: nil)
        await fulfillment(of: [delivered], timeout: failureBound)

        observer.observe(nil)
        XCTAssertEqual(center.registeredObserverCount, 0)
    }

    private func assertWidget(_ widget: ShellRenderedWidget, shows source: ShellInputSource) {
        XCTAssertTrue(widget.strings().contains(source.current.short))
        let nodes = widget.renderPopout()
        let rows = nodes.indices.compactMap { index -> (index: Int, id: String)? in
            guard case let .inputSource(.select(id))? = ShellAction(widget.text.string(nodes[index].content.action))
            else { return nil }
            return (index, id)
        }
        XCTAssertEqual(rows.map(\.id), source.sources.map(\.id))
        for row in rows {
            let symbols = nodes[(row.index + 1) ..< Int(nodes[row.index].subtreeEnd)].filter { $0.kind == .symbol }
            XCTAssertEqual(symbols.count, 1, row.id)
            XCTAssertEqual(symbols.first.map { $0.paint.opacity > 0 }, row.id == source.current.id, row.id)
        }
    }

    @MainActor
    private final class InputSourceState {
        var value: ShellInputSource

        init(_ value: ShellInputSource) {
            self.value = value
        }
    }
}

private final class TrackingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let observerIDs = Mutex<Set<ObjectIdentifier>>([])

    var registeredObserverCount: Int {
        observerIDs.withLock { $0.count }
    }

    override func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?, object: Any?) {
        super.addObserver(observer, selector: selector, name: name, object: object)
        let id = ObjectIdentifier(observer as AnyObject)
        observerIDs.withLock { _ = $0.insert(id) }
    }

    override func removeObserver(_ observer: Any) {
        super.removeObserver(observer)
        let id = ObjectIdentifier(observer as AnyObject)
        observerIDs.withLock { _ = $0.remove(id) }
    }
}

private final class ScopedInputSourceNotificationCenter: DistributedNotificationCenter, @unchecked Sendable {
    private let center = DistributedNotificationCenter.default()
    private let prefix = "com.omniwm.tests.input-source.\(UUID().uuidString)"

    override func addObserver(
        _ observer: Any,
        selector: Selector,
        name: Notification.Name?,
        object: String?,
        suspensionBehavior: SuspensionBehavior
    ) {
        center.addObserver(
            observer, selector: selector, name: name.map(scoped), object: object,
            suspensionBehavior: suspensionBehavior
        )
    }

    override func addObserver(
        forName name: Notification.Name?,
        object: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        center.addObserver(forName: name.map(scoped), object: object, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        center.removeObserver(observer)
    }

    func post(_ name: Notification.Name) {
        center.postNotificationName(scoped(name), object: nil, userInfo: nil, deliverImmediately: false)
    }

    private func scoped(_ name: Notification.Name) -> Notification.Name {
        Notification.Name(prefix + "." + name.rawValue)
    }
}
