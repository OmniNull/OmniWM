// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class ApplicationCatalogFilterTests: XCTestCase {
    private let home = "/Users/tester"

    func testRootsAndOneLevelSubfoldersAreCatalogPaths() {
        let included = [
            "/Applications/Safari.app",
            "/Applications/Utilities/Terminal.app",
            "/System/Applications/Calculator.app",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            "/Users/tester/Applications/Chrome Apps.localized/Docs.app",
            "/Users/Shared/Tool.app",
            "/Users/tester/Downloads/Installer.app",
            "/System/Library/CoreServices/Applications/Keychain Access.app",
            ApplicationCatalogFilter.finderPath
        ]
        for path in included {
            XCTAssertTrue(ApplicationCatalogFilter.isCatalogPath(path, home: home), path)
        }
    }

    func testNestedBundlesDeepFoldersAndDownloadsSubfoldersAreExcluded() {
        let excluded = [
            "/Applications/Xcode.app/Contents/Applications/Instruments.app",
            "/Applications/Suite.app/Helper.app",
            "/Applications/Vendor/Nested/Tool.app",
            "/Users/tester/Downloads/Archive/Installer.app",
            "/System/Library/CoreServices/Dock.app",
            "/Applications/README.txt"
        ]
        for path in excluded {
            XCTAssertFalse(ApplicationCatalogFilter.isCatalogPath(path, home: home), path)
        }
    }
}
