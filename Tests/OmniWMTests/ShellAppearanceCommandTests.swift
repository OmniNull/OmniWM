// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import Synchronization
import XCTest

private let theme = Atomic<Int32>(SkyLightAppearanceFunctions.light)
private let writes = Atomic<Int>(0)

final class ShellAppearanceCommandTests: XCTestCase {
    private let functions = SkyLightAppearanceFunctions(
        getTheme: { theme.load(ordering: .relaxed) },
        setTheme: { value in
            theme.store(value, ordering: .relaxed)
            _ = writes.wrappingAdd(1, ordering: .relaxed)
        }
    )

    override func setUp() {
        super.setUp()
        writes.store(0, ordering: .relaxed)
    }

    func testEachToggleWritesTheOppositeOfTheThemeItReads() {
        theme.store(SkyLightAppearanceFunctions.dark, ordering: .relaxed)
        let expected = [SkyLightAppearanceFunctions.light, SkyLightAppearanceFunctions.dark]
        for next in expected {
            XCTAssertTrue(ShellAppearanceCommand.toggle.perform(using: functions))
            XCTAssertEqual(theme.load(ordering: .relaxed), next)
        }
        XCTAssertEqual(writes.load(ordering: .relaxed), expected.count)
    }

    func testToggleHonorsAThemeChangedElsewhere() {
        theme.store(SkyLightAppearanceFunctions.light, ordering: .relaxed)
        XCTAssertTrue(ShellAppearanceCommand.toggle.perform(using: functions))
        XCTAssertEqual(theme.load(ordering: .relaxed), SkyLightAppearanceFunctions.dark)
        theme.store(SkyLightAppearanceFunctions.light, ordering: .relaxed)
        XCTAssertTrue(ShellAppearanceCommand.toggle.perform(using: functions))
        XCTAssertEqual(theme.load(ordering: .relaxed), SkyLightAppearanceFunctions.dark)
    }

    func testMissingFunctionsLeaveTheAppearanceAlone() {
        theme.store(SkyLightAppearanceFunctions.light, ordering: .relaxed)
        let missing = [
            SkyLightAppearanceFunctions(getTheme: nil, setTheme: functions.setTheme),
            SkyLightAppearanceFunctions(getTheme: functions.getTheme, setTheme: nil)
        ]
        for functions in missing {
            XCTAssertFalse(ShellAppearanceCommand.toggle.perform(using: functions))
        }
        XCTAssertEqual(theme.load(ordering: .relaxed), SkyLightAppearanceFunctions.light)
        XCTAssertEqual(writes.load(ordering: .relaxed), 0)
    }
}
