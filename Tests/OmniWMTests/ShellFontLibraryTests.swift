// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
@testable import OmniWM
import OmniWMScriptHost
import XCTest

enum ShellFontFixture {
    static let family = "Space Grotesk"
    static let fileName = "SpaceGrotesk[wght].ttf"

    static let layer: URL? = {
        let source = ShellStyleFixture.directory.appendingPathComponent("vitreus/fonts/\(fileName)")
        let layer = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnishell-fonts-\(UUID().uuidString)", isDirectory: true)
        let fonts = layer.appendingPathComponent("fonts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: fonts.appendingPathComponent(fileName))
        } catch {
            return nil
        }
        return layer
    }()

    static func folders() throws -> [URL] {
        ShellFontLibrary.folders([try XCTUnwrap(layer)])
    }

    static func fonts() throws -> ShellFontSet {
        ShellFontLibrary.shared.fonts(in: try folders())
    }

    static func id() throws -> UInt8 {
        try XCTUnwrap(try fonts().ids[family])
    }

    static func file() throws -> URL {
        try folders()[0].appendingPathComponent(fileName)
    }

    static func registered(_ file: URL) -> Int {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let available = CTFontManagerCopyAvailableFontURLs() as? [URL] ?? []
        return available.count { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    static func source(_ font: CTFont) -> String? {
        (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func variation(_ font: CTFont) -> [UInt32: Double] {
        let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.uint32Value, $0.value.doubleValue) })
    }

    static func store(_ text: String) -> ShellTextStore {
        var record = withUnsafeBytes(of: omni_wire_string(id: 1, length: UInt32(text.utf8.count))) { Array($0) }
        record += Array(text.utf8)
        let store = ShellTextStore()
        store.ingest(record, count: 1)
        return store
    }
}

final class ShellFontLibraryTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders.removeAll()
        super.tearDown()
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnishell-font-test-\(UUID().uuidString)/fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder.deletingLastPathComponent())
        return folder
    }

    private func fontData() throws -> Data {
        try Data(contentsOf: try ShellFontFixture.file())
    }

    func testRepeatedAndSymlinkedFoldersShareOneRegistrationOfTheResolvedFile() throws {
        let layer = try XCTUnwrap(ShellFontFixture.layer)
        let first = try ShellFontFixture.fonts()
        let id = try XCTUnwrap(first.ids[ShellFontFixture.family])
        XCTAssertGreaterThanOrEqual(UInt32(id), OMNI_STYLE_FONT_CUSTOM)
        let file = try ShellFontFixture.file()
        let registered = ShellFontFixture.registered(file)
        XCTAssertGreaterThan(registered, 0)
        XCTAssertEqual(try ShellFontFixture.fonts(), first)
        let alias = try folder().deletingLastPathComponent().appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: layer)
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: ShellFontLibrary.folders([alias])), first)
        XCTAssertEqual(ShellFontFixture.registered(file), registered)
        let aliasPath = alias.appendingPathComponent("fonts/\(ShellFontFixture.fileName)").standardizedFileURL.path
        let available = CTFontManagerCopyAvailableFontURLs() as? [URL] ?? []
        XCTAssertFalse(available.contains { $0.standardizedFileURL.path == aliasPath })
        let face = ShellTextStyle.font(for: UInt32(id) << OMNI_STYLE_FONT_SHIFT)
        XCTAssertEqual(ShellFontFixture.source(face), file.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(ShellFontLibrary.shared.family(of: UInt32(id) << OMNI_STYLE_FONT_SHIFT), ShellFontFixture.family)
        XCTAssertNil(ShellFontLibrary.shared.family(of: (OMNI_STYLE_FONT_CUSTOM - 1) << OMNI_STYLE_FONT_SHIFT))
    }

    func testOnlyContainedRegularUncompressedFontsWithinTheLimitsAreRead() throws {
        _ = try ShellFontFixture.fonts()
        let data = try fontData()
        let escaping = try folder()
        try FileManager.default.createSymbolicLink(
            at: escaping.appendingPathComponent("escape.ttf"), withDestinationURL: try ShellFontFixture.file()
        )
        let compressed = try folder()
        try (Data("wOFF".utf8) + data.dropFirst(4)).write(to: compressed.appendingPathComponent("font.ttf"))
        let woff = try folder()
        try data.write(to: woff.appendingPathComponent("font.woff"))
        let sparse = try folder()
        let large = sparse.appendingPathComponent("large.ttf")
        try data.write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ShellFontLibrary.byteLimit + 1))
        try handle.close()
        let hidden = try folder()
        try data.write(to: hidden.appendingPathComponent("._font.ttf"))
        let crowded = try folder()
        for index in 0 ..< ShellFontLibrary.fileLimit {
            try Data("not a font".utf8).write(to: crowded.appendingPathComponent(String(format: "a%02d.ttf", index)))
        }
        try data.write(to: crowded.appendingPathComponent("b.ttf"))
        for excluded in [escaping, compressed, woff, sparse, hidden, crowded] {
            XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [excluded]), ShellFontSet(), excluded.path)
        }
        XCTAssertEqual(ShellFontLibrary.files(in: crowded).count, ShellFontLibrary.fileLimit)
        XCTAssertFalse(ShellFontLibrary.files(in: crowded).map(\.lastPathComponent).contains("b.ttf"))
        XCTAssertEqual(ShellFontLibrary.files(in: hidden), [])

        let upper = try folder()
        try data.write(to: upper.appendingPathComponent("FONT.TTF"))
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [upper]), try ShellFontFixture.fonts())
    }

    func testATruncatedCopyIsReadAgainOnceTheCompleteFileLands() throws {
        let owner = try ShellFontFixture.fonts()
        let data = try fontData()
        let fonts = try folder()
        let file = fonts.appendingPathComponent("copy.ttf")
        try data.prefix(1024).write(to: file)
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [fonts]), ShellFontSet())
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [fonts]), ShellFontSet())
        try data.write(to: file)
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [fonts]), owner)
        XCTAssertEqual(ShellFontFixture.registered(file), 0)
    }

    func testAnotherFolderShippingAnOwnedFamilyUsesTheOwnersFace() throws {
        let owner = try ShellFontFixture.fonts()
        let other = try folder().appendingPathComponent("SpaceGrotesk.otf")
        try fontData().write(to: other)
        XCTAssertEqual(ShellFontLibrary.shared.fonts(in: [other.deletingLastPathComponent()]), owner)
        XCTAssertEqual(ShellFontFixture.registered(other), 0)
        XCTAssertGreaterThan(ShellFontFixture.registered(try ShellFontFixture.file()), 0)
        let both = ShellFontLibrary.shared
            .fonts(in: [other.deletingLastPathComponent()] + (try ShellFontFixture.folders()))
        XCTAssertEqual(both, owner)
    }
}
