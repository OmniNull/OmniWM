// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class SkyLightTransactionScopeTests: XCTestCase {
    @MainActor
    func testScopeCreatesTransactionOnlyOnFirstUse() throws {
        let skyLight = SkyLight.shared
        var created = false
        skyLight.withTransactionScope {
            XCTAssertNil(skyLight.scopedTransaction)
            skyLight.withTransaction { _ in }
            created = skyLight.scopedTransaction != nil
            skyLight.withTransactionScope {
                skyLight.withTransaction { _ in }
            }
        }
        XCTAssertNil(skyLight.scopedTransaction)
        try XCTSkipUnless(created, "WindowServer transactions unavailable")
    }
}
