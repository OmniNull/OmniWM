// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarRunningAppsSnapshotTests: XCTestCase {
    func testMembershipRepairRequiresResolvedItemAndMatchingLiveOwner() {
        let snapshot = HiddenBarRunningAppsSnapshot(
            bundleIDs: ["app", "helper", "attributed", "empty", "mismatched"],
            candidates: [
                MenuBarAppCandidate(bundleID: "app", pid: 1),
                MenuBarAppCandidate(bundleID: "helper", pid: 2),
                MenuBarAppCandidate(bundleID: "attributed", pid: 3),
                MenuBarAppCandidate(bundleID: "empty", pid: 4),
                MenuBarAppCandidate(bundleID: "mismatched", pid: 5)
            ]
        )
        let items = [
            "app": [item("app", pid: 7), item("app", pid: 1)],
            "helper": [item("helper", pid: 2)],
            "attributed": [item("attributed", pid: 3)],
            "empty": [],
            "mismatched": [item("different", pid: 5)],
            "terminated": [item("terminated", pid: 6)]
        ]
        var queriedPIDs: [pid_t] = []

        let verified = snapshot.verifiedMenuItemBundleIDs(for: items) { pid in
            queriedPIDs.append(pid)
            return [1: "app", 2: "helper.actual", 4: "empty", 5: "mismatched", 6: "terminated", 7: "app"][pid]
        }

        XCTAssertEqual(verified, ["app"])
        XCTAssertEqual(Set(queriedPIDs), [1, 2, 3])
    }

    private func item(_ bundleID: String, pid: pid_t) -> ResolvedMenuBarItem {
        ResolvedMenuBarItem(
            key: MenuBarItemKey(bundleID: bundleID, ordinal: 0),
            pid: pid,
            bounds: CGRect(x: 10, y: 3, width: 24, height: 24)
        )
    }
}
