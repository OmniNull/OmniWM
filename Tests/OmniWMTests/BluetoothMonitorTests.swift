// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class BluetoothMonitorTests: XCTestCase {
    @MainActor
    func testDeviceNotificationsFromABackgroundThreadAreHandledOnMain() async {
        let monitor = BluetoothMonitor()
        let handled = expectation(description: "notifications handled")
        DispatchQueue.global().async {
            monitor.perform(NSSelectorFromString("connected:device:"), with: nil, with: nil)
            monitor.perform(NSSelectorFromString("disconnected:device:"), with: nil, with: nil)
            DispatchQueue.main.async { handled.fulfill() }
        }
        await fulfillment(of: [handled], timeout: failureBound)
    }
}
