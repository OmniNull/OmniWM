// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellAppExampleDocumentationTests: XCTestCase {
    func testProviderReviewExampleLoadsWithItsSheetAndAnExecutableProvider() async throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: apps) }
        let folder = try ShellProviderReviewExampleFixture.copy(to: apps)
        let snapshot = try await ShellAppCatalogLoader().load(directories: [apps], bundled: nil)
        XCTAssertEqual(snapshot.problems, [])
        let app = try XCTUnwrap(snapshot.definitions["provider-review"])
        XCTAssertEqual(app.view, "window")
        XCTAssertEqual(app.children["confirm"]?.kind, .sheet)
        XCTAssertEqual(app.component?.providerCommand, ["provider"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("provider.swift").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: folder.appendingPathComponent("provider").path
        ))
    }
}
