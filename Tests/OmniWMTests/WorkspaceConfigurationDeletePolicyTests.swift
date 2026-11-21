// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceConfigurationDeletePolicyTests: XCTestCase {
    func testDeletingAWorkspaceMatchesRulesByTheirTrimmedWorkspaceName() {
        let config = WorkspaceConfiguration(name: "3", layoutType: .niri)
        let rules = [
            AppRule(bundleId: "org.example.padded", assignToWorkspace: " 3 "),
            AppRule(bundleId: "org.example.exact", assignToWorkspace: "3"),
            AppRule(bundleId: "org.example.other", assignToWorkspace: "4"),
            AppRule(bundleId: "org.example.unassigned")
        ]

        XCTAssertEqual(WorkspaceConfigurationDeletePolicy.assignedRuleCount(config, in: rules), 2)
        XCTAssertEqual(
            rules.map { WorkspaceConfigurationDeletePolicy.assignsRule($0, to: config) },
            [true, true, false, false]
        )
    }
}
