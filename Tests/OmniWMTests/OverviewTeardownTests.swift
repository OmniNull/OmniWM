// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class OverviewTeardownTests: XCTestCase {
    func testMainActorFinalReleaseCleansUpImmediately() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OverviewTeardown")
        let record = OverviewDestructionRecord()
        let owner = makeOwner(controller: controller, record: record, start: true)

        owner.withLock { $0 = nil }

        XCTAssertEqual(record.events.withLock { $0 }, ["removeMonitor:true", "destroyed:true"])
    }

    func testDetachedFinalReleaseCleansUpOnMainActor() async {
        let cases: [(start: Bool, expected: [String])] = [
            (true, ["removeMonitor:true", "destroyed:true"]),
            (false, ["destroyed:true"])
        ]
        for row in cases {
            let controller = WindowAdmissionTestSupport.controller(prefix: "OverviewTeardown")
            let record = OverviewDestructionRecord()
            let owner = makeOwner(controller: controller, record: record, start: row.start)

            let releasedOnMainThread = await Task.detached {
                owner.withLock { overview in
                    overview = nil
                    return Thread.isMainThread
                }
            }.value
            await fulfillment(of: [record.completed], timeout: failureBound)

            XCTAssertFalse(releasedOnMainThread)
            XCTAssertEqual(record.events.withLock { $0 }, row.expected)
        }
    }

    private func makeOwner(
        controller: WMController, record: OverviewDestructionRecord, start: Bool
    ) -> Mutex<OverviewController?> {
        var environment = OverviewEnvironment()
        environment.frontmostApplicationPID = { nil }
        environment.notificationCenter = NotificationCenter()
        environment.addLocalEventMonitor = { _, _ in NSObject() }
        environment.removeEventMonitor = { _ in
            record.events.withLock { $0.append("removeMonitor:\(Thread.isMainThread)") }
        }
        let overview = OverviewController(
            wmController: controller, motionPolicy: controller.motionPolicy, environment: environment
        )
        let witness = OverviewDestructionWitness(record: record)
        overview.onActivateWindow = { [witness] _, _ in withExtendedLifetime(witness) {} }
        if start { overview.beginOwnedSession() }
        return Mutex(overview)
    }
}

private final class OverviewDestructionRecord: Sendable {
    let completed = XCTestExpectation(description: "Overview stored properties destroyed")
    let events = Mutex<[String]>([])
}

private final class OverviewDestructionWitness: Sendable {
    private let record: OverviewDestructionRecord

    init(record: OverviewDestructionRecord) {
        self.record = record
    }

    deinit {
        record.events.withLock { $0.append("destroyed:\(Thread.isMainThread)") }
        record.completed.fulfill()
    }
}
