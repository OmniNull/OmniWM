// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import UniformTypeIdentifiers
import XCTest

final class FileSuggestionsReaderTests: XCTestCase {
    func testArchivePreservesOrderAndFiltersDuplicatesTrashAndTypes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("First.pdf")
        let second = directory.appendingPathComponent("Second.pdf")
        let image = directory.appendingPathComponent("Image.png")
        let trash = directory.appendingPathComponent(".Trash/Discard.pdf")
        try FileManager.default.createDirectory(
            at: trash.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for url in [first, second, image, trash] {
            try Data().write(to: url)
        }

        let urls = [second, image, first, first, trash]
        var objects: [Any] = ["$null"]
        objects.append(["predictedDocuments": ["CF$UID": 2]])
        let entryReferences = urls.indices.map { index in ["CF$UID": 3 + index * 3] }
        objects.append(["NS.objects": entryReferences])
        for url in urls {
            let documentIndex = objects.count + 1
            let stringIndex = objects.count + 2
            objects.append(["predictionType": 1, "documentURL": ["CF$UID": documentIndex]])
            objects.append(["NS.relative": ["CF$UID": stringIndex]])
            objects.append(url.absoluteString)
        }

        let archive: [String: Any] = [
            "$objects": objects,
            "$top": ["root": ["CF$UID": 1]]
        ]
        let cache = directory.appendingPathComponent("suggestions.bplist")
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        try data.write(to: cache)

        let results = FileSuggestionsReader.read(from: cache, acceptedTypes: [.pdf])
        XCTAssertEqual(results.map(\.fileURL), [second, first])
    }

    func testCachedSuggestionsFilterByChipTypeLimitAndExistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["a.pdf", "b.png", "c.pdf", "d.pdf", "gone.pdf"]
        let results = try names.map { name in
            let url = directory.appendingPathComponent(name)
            if name != "gone.pdf" { try Data().write(to: url) }
            return LauncherFileResult(
                fileURL: url,
                displayName: name,
                contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier
            )
        }
        XCTAssertEqual(
            FileSuggestionsReader.filter(results, acceptedTypes: [.pdf], limit: 2).map(\.displayName),
            ["a.pdf", "c.pdf"]
        )
        XCTAssertEqual(
            FileSuggestionsReader.filter(results, acceptedTypes: [], limit: 5).map(\.displayName),
            ["a.pdf", "b.png", "c.pdf", "d.pdf"]
        )
    }

    func testMissingCacheProducesNoSuggestions() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileSuggestionsReader.read(from: missing).isEmpty)
    }
}
