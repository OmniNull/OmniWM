// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class FileSearchResultMapperTests: XCTestCase {
    func testBulkMetadataMapsToFileAndRankingFields() throws {
        let modified = Date(timeIntervalSince1970: 2_000)
        let engagement = Date(timeIntervalSince1970: 1_000)
        let record = try XCTUnwrap(FileSearchResultMapper.record(attributes: [
            "kMDItemPath": "/Users/test/Documents/Design.pdf",
            "kMDItemDisplayName": "Design.pdf",
            "kMDItemContentType": "com.adobe.pdf",
            "kMDItemFSSize": NSNumber(value: 4_096),
            "kMDItemTitle": "Design Notes",
            "kMDItemAuthors": ["Author One", "Author Two"],
            "kMDItemContentModificationDate": modified,
            "_kMDItemRecentSpotlightEngagementDatesNonUnique": [engagement],
            "_kMDItemRecentSpotlightEngagementQueriesNonUnique": ["design"]
        ]))

        XCTAssertEqual(record.result.displayName, "Design.pdf")
        XCTAssertEqual(record.result.size, 4_096)
        XCTAssertEqual(record.result.modifiedAt, modified)
        XCTAssertEqual(record.candidate.fields.authors, "Author One")
        XCTAssertEqual(record.candidate.fields.title, "Design Notes")
        XCTAssertEqual(record.candidate.engagement.inSpotlightDates, [engagement])
        XCTAssertEqual(record.candidate.engagement.inSpotlightQueries, ["design"])
    }

    func testFallbackQueryEscapesMetadataSyntax() {
        let query = FileSearchResultMapper.fallbackQueryString(for: "a\"b c\\d")
        XCTAssertEqual(query, "(** = \"a\\\"b*\"cdw) && (** = \"c\\\\d*\"cdw)")
        XCTAssertNil(FileSearchResultMapper.record(attributes: [:]))
    }
}
