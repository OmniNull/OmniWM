// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellAppExampleDocumentationTests: XCTestCase {
    func testProviderReviewExampleLoadsWithItsSheetAndAnExecutableProvider() async throws {
        let apps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("website/public/examples/omnishell/apps")
        let snapshot = try await ShellAppCatalogLoader().load(directories: [apps], bundled: nil)
        XCTAssertEqual(snapshot.problems, [])
        let app = try XCTUnwrap(snapshot.definitions["provider-review"])
        XCTAssertEqual(app.view, "window")
        XCTAssertEqual(app.children["confirm"]?.kind, .sheet)
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: apps.appendingPathComponent("provider-review/provider.sh").path
        ))
    }
}
