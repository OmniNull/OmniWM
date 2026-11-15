// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

final class WallpaperLibraryTests: XCTestCase {
    func testOnlyVisibleImageFilesAreWallpapersInFinderOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try WallpaperFixtures.makeFolder(root, "w", files: [
            "img10.jpg", "img2.jpg", "Photo.HEIC", ".DS_Store", ".secret.png", "notes.txt", "movie.mov", "raw"
        ])
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub.png"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.png"),
            withDestinationURL: folder.appendingPathComponent("img2.jpg")
        )
        XCTAssertEqual(try WallpaperLibrary.files(in: folder), ["img2.jpg", "img10.jpg", "linked.png", "Photo.HEIC"])
        XCTAssertThrowsError(
            try WallpaperLibrary.files(in: root.appendingPathComponent("missing")),
            "a folder that cannot be listed is a failure, not an empty folder"
        )
    }

    func testPathsExpandAndAbbreviateAroundTheHomeFolder() {
        XCTAssertEqual(WallpaperLibrary.expand("~/Pictures", home: "/Users/a"), "/Users/a/Pictures")
        XCTAssertEqual(WallpaperLibrary.expand("~", home: "/Users/a"), "/Users/a")
        XCTAssertEqual(WallpaperLibrary.abbreviate("/Users/a/Pictures", home: "/Users/a"), "~/Pictures")
        XCTAssertEqual(WallpaperLibrary.abbreviate("/Users/ab/Pictures", home: "/Users/a"), "/Users/ab/Pictures")
        XCTAssertNil(WallpaperLibrary.folderURL("relative/folder", home: "/Users/a"))
    }

    func testFileNameTokensRoundTripAnyName() {
        for name in ["a b.jpg", "quote\"back\\slash.png", "été 🌅.heic", "tab\tname.jpg"] {
            let token = WallpaperLibrary.token(for: name)
            XCTAssertTrue(token.allSatisfy(\.isHexDigit))
            XCTAssertEqual(WallpaperLibrary.name(forToken: token), name)
        }
        XCTAssertNil(WallpaperLibrary.name(forToken: "zz"))
        XCTAssertNil(WallpaperLibrary.name(forToken: "abc"))
    }

    func testEveryWallpaperShowsOnceBeforeAnyRepeatsAndCyclesDoNotRepeatAtTheSeam() {
        var shuffle = WallpaperShuffle()
        var random = WallpaperRandom(seed: 42)
        let files = (1 ... WallpaperPreviews.defaultWindow).map { "w\($0).jpg" }
        var previous: String?
        for _ in 0 ..< 2 * WallpaperPreviews.pageLimit {
            var cycle: [String] = []
            for _ in files {
                let pick = shuffle.next(display: "A", folder: "/w", files: files, using: &random)!
                if cycle.isEmpty { XCTAssertNotEqual(pick, previous) }
                cycle.append(pick)
                previous = pick
            }
            XCTAssertEqual(Set(cycle).count, files.count)
        }
    }

    func testRemovedFilesAreSkippedNewFilesJoinAndAFolderChangeStartsOver() {
        var shuffle = WallpaperShuffle()
        var random = WallpaperRandom(seed: 1)
        let files = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        let first = shuffle.next(display: "A", folder: "/w", files: files, using: &random)!
        let removed = files.first { $0 != first }!
        let changed = files.filter { $0 != removed } + ["e.jpg"]
        var picks: [String] = []
        for _ in 0 ..< changed.count - 1 {
            picks.append(shuffle.next(display: "A", folder: "/w", files: changed, using: &random)!)
        }
        XCTAssertEqual(picks.sorted(), changed.filter { $0 != first }.sorted())
        _ = shuffle.next(display: "A", folder: "/other", files: ["x.jpg"], using: &random)
        XCTAssertEqual(shuffle.displays["A"]?.folder, "/other")
        XCTAssertEqual(shuffle.next(display: "A", folder: "/w", files: [], using: &random), nil)
    }

    func testDisplaysKeepIndependentOrdersAndPeekDoesNotAdvance() throws {
        var shuffle = WallpaperShuffle()
        var random = WallpaperRandom(seed: 9)
        let files = ["a.jpg", "b.jpg", "c.jpg"]
        _ = shuffle.next(display: "A", folder: "/w", files: files, using: &random)
        let peeked = shuffle.peek(display: "B", folder: "/w", files: files, random: random)
        XCTAssertNil(shuffle.displays["B"])
        XCTAssertEqual(shuffle.next(display: "B", folder: "/w", files: files, using: &random), peeked)
        let data = try JSONEncoder().encode(shuffle)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperShuffle.self, from: data), shuffle)
    }

    func testThePaletteSampleIsTheWholeFileTheSameWayTheStillWallpaperReadIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("split.png")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 150, y: 0, width: 100, height: 100))
        try NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:])!.write(to: url)

        let sample = try XCTUnwrap(WallpaperRendering.sample(WallpaperSampleKey(file: WallpaperFileStamp(url))))
        let stillRead = try XCTUnwrap(ShellWallpaperPalette.read(url).map(ShellWallpaperPalette.pixels(of:)))
        XCTAssertEqual(sample, stillRead, "the manager and the still wallpaper read sample a file identically")
        let blue = Double(sample.filter { $0 & 0xFF > 0x80 && ($0 >> 16) & 0xFF < 0x80 }.count) / Double(sample.count)
        XCTAssertLessThan(blue, 0.4, "the whole file is sampled, not the middle a square display would show")
        XCTAssertEqual(WallpaperFileStamp(url), WallpaperFileStamp(url))
    }

    func testAStampOfASymbolicLinkChangesWhenTheWallpaperItPointsAtChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.jpg")
        try Data("first".utf8).write(to: target)
        let link = root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = WallpaperFileStamp(link)

        let changed = Data("a longer second version".utf8)
        try changed.write(to: target)
        let after = WallpaperFileStamp(link)
        XCTAssertNotEqual(after, before, "a new image behind the same link gets a new stamp")
        XCTAssertEqual(after.bytes, Int64(changed.count))
        XCTAssertEqual(after.path, link.standardizedFileURL.path, "the stamp keeps the link's own path")
    }

    func testPreviewsAreCroppedToTheDisplayShape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("w.png")
        try WallpaperFixtures.writeImage(url, width: 1600, height: 900, color: (0.2, 0.4, 0.6))
        let width = WallpaperPreviews.gridWidth
        let ultrawide = try XCTUnwrap(WallpaperRendering.preview(
            url, width: width, aspect: 32.0 / 9.0, placement: .fill
        ))
        XCTAssertEqual(ultrawide.width, width)
        XCTAssertEqual(ultrawide.height, Int((Double(width) * 9 / 32).rounded()))
        let portrait = try XCTUnwrap(WallpaperRendering.preview(
            url, width: width, aspect: 9.0 / 16.0, placement: .fill
        ))
        XCTAssertEqual(portrait.width, Int((Double(width) * 9 / 16).rounded()))
        XCTAssertEqual(portrait.height, width)
        XCTAssertNil(WallpaperRendering.preview(
            root.appendingPathComponent("none.png"),
            width: width,
            aspect: 1,
            placement: .fill
        ))
    }
}
