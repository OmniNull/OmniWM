// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class SkyLightTransactionScopeTests: XCTestCase {
    @MainActor
    func testMoveJoinsAnOpenTransactionAndOpensNone() {
        let skyLight = SkyLight.shared
        let absentWindow: UInt32 = 0
        skyLight.withTransactionScope {
            _ = skyLight.moveJoiningOpenTransaction(absentWindow, origin: .zero)
            XCTAssertNil(skyLight.scopedTransaction)

            var open: CFTypeRef?
            skyLight.withTransaction { open = $0 }
            XCTAssertTrue(skyLight.moveJoiningOpenTransaction(absentWindow, origin: .zero))
            XCTAssertTrue(skyLight.scopedTransaction === open)
        }
    }

    @MainActor
    func testScopeCreatesTransactionOnlyOnFirstUse() throws {
        let skyLight = SkyLight.shared
        var created = false
        skyLight.withTransactionScope {
            XCTAssertNil(skyLight.scopedTransaction)
            var first: CFTypeRef?
            skyLight.withTransaction { first = $0 }
            created = first != nil
            XCTAssertTrue(skyLight.scopedTransaction === first)
            skyLight.withTransaction { second in
                XCTAssertTrue(second === first)
            }
            skyLight.withTransactionScope {
                skyLight.withTransaction { nested in
                    XCTAssertTrue(nested === first)
                }
            }
            XCTAssertTrue(skyLight.scopedTransaction === first)
        }
        XCTAssertNil(skyLight.scopedTransaction)
        guard created else { throw MissingTestPrerequisite("WindowServer transactions unavailable") }
    }
}
