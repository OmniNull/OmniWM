// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class UnsuspendedNotificationObserverTests: XCTestCase {
    func testDistributedNotificationsArriveWhileTheCenterIsSuspended() async {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name("com.omniwm.tests.unsuspended.\(UUID().uuidString)")
        let wasSuspended = center.suspended
        center.suspended = true
        defer { center.suspended = wasSuspended }

        let delivered = expectation(description: "Delivered while suspended")
        let observer = center.addUnsuspendedObserver(forName: name) { _ in delivered.fulfill() }
        defer { center.removeObserver(observer) }
        center.post(name: name, object: nil)

        await fulfillment(of: [delivered], timeout: failureBound)
    }
}
