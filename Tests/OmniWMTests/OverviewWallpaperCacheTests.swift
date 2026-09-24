// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import UniformTypeIdentifiers
import XCTest

@MainActor
final class OverviewWallpaperCacheTests: XCTestCase {
    func testBucketsPixelSizesToBoundedVariants() {
        XCTAssertEqual(OverviewWallpaperCache.bucketedPixelSize(10), 64)
        XCTAssertEqual(OverviewWallpaperCache.bucketedPixelSize(64), 64)
        XCTAssertEqual(OverviewWallpaperCache.bucketedPixelSize(65), 512)
        XCTAssertEqual(OverviewWallpaperCache.bucketedPixelSize(900), 1024)
        XCTAssertEqual(OverviewWallpaperCache.bucketedPixelSize(9000), 4096)
    }

    func testRenderedColoursStayDisplaySpecificWithSharedFallbackURL() throws {
        let url = try makeImageFile(width: 400, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }
        let black = try makeSolidImage(gray: 0)
        let white = try makeSolidImage(gray: 1)
        let firstFrame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let secondFrame = firstFrame.offsetBy(dx: 400, dy: -100)
        var captures = 0
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in url }
        cache.captureWallpaper = { frame in
            captures += 1
            return frame == firstFrame ? black : white
        }

        let small = try XCTUnwrap(cache.image(for: 999, maxPixelSize: 64, frame: firstFrame))
        XCTAssertEqual(small.width, 64)
        XCTAssertEqual(small.height, 32)
        try assertGray(small, equals: 0)
        XCTAssertTrue(cache.image(for: 999, maxPixelSize: 64, frame: firstFrame) === small)
        XCTAssertEqual(captures, 1)
        let large = try XCTUnwrap(cache.image(for: 999, maxPixelSize: 512, frame: firstFrame))
        XCTAssertEqual(large.width, 400)
        try assertGray(large, equals: 0)
        try assertGray(cache.image(for: 998, maxPixelSize: 64, frame: secondFrame), equals: 1)
        try assertGray(cache.image(for: 999, maxPixelSize: 64, frame: firstFrame), equals: 0)
        XCTAssertEqual(captures, 3)
    }

    func testNewSessionAndChangedDisplayFrameRefreshRenderedWallpaper() throws {
        let black = try makeSolidImage(gray: 0)
        let white = try makeSolidImage(gray: 1)
        var desktop = black
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        cache.captureWallpaper = { _ in desktop }
        try assertGray(cache.image(for: 999, maxPixelSize: 64, frame: frame), equals: 0)

        desktop = white
        cache.clear()
        try assertGray(cache.image(for: 999, maxPixelSize: 64, frame: frame), equals: 1)
        desktop = black
        try assertGray(
            cache.image(for: 999, maxPixelSize: 64, frame: frame.offsetBy(dx: 400, dy: 0)),
            equals: 0
        )
    }

    func testUnavailableCaptureFallsBackToFileAndRetriesNextSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(NSBitmapImageRep(cgImage: makeSolidImage(gray: 1))
            .representation(using: .png, properties: [:])).write(to: url)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        var desktop: CGImage?
        var captures = 0
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in url }
        cache.captureWallpaper = { _ in
            captures += 1
            return desktop
        }
        try assertGray(cache.image(for: 999, maxPixelSize: 64, frame: frame), equals: 1)
        try assertGray(cache.image(for: 999, maxPixelSize: 512, frame: frame), equals: 1)
        XCTAssertEqual(captures, 1)

        desktop = try makeSolidImage(gray: 0)
        cache.clear()
        try assertGray(cache.image(for: 999, maxPixelSize: 64, frame: frame), equals: 0)
        XCTAssertEqual(captures, 2)
    }

    func testDecodesDownsampledThumbnailsOncePerSizeAndDropsStaleURLs() throws {
        let first = try makeImageFile(width: 400, height: 200)
        let second = try makeImageFile(width: 300, height: 300)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var url: URL? = first
        let cache = OverviewWallpaperCache()
        cache.captureWallpaper = { _ in nil }
        cache.desktopImageURL = { _ in url }

        let small = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 64))
        XCTAssertEqual(max(small.width, small.height), 64)
        XCTAssertTrue(cache.image(for: 1, maxPixelSize: 64) === small)
        let large = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 512))
        XCTAssertEqual(large.width, 400)
        XCTAssertFalse(large === small)

        url = second
        let replaced = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 64))
        XCTAssertFalse(replaced === small)
        XCTAssertEqual(replaced.width, replaced.height)

        url = nil
        XCTAssertNil(cache.image(for: 1, maxPixelSize: 64))
    }

    func testDifferentDisplaysRetainTheirWallpaperVariantsWhenAnotherDisplayChanges() throws {
        let first = try makeImageFile(width: 400, height: 200)
        let second = try makeImageFile(width: 300, height: 300)
        let replacement = try makeImageFile(width: 500, height: 300)
        defer {
            for url in [first, second, replacement] { try? FileManager.default.removeItem(at: url) }
        }
        var urls: [CGDirectDisplayID: URL] = [1: first, 2: second]
        let cache = OverviewWallpaperCache()
        cache.captureWallpaper = { _ in nil }
        cache.desktopImageURL = { urls[$0] }
        let firstSmall = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 64))
        let firstLarge = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 512))
        let secondSmall = try XCTUnwrap(cache.image(for: 2, maxPixelSize: 64))
        let secondLarge = try XCTUnwrap(cache.image(for: 2, maxPixelSize: 512))
        XCTAssertTrue(cache.image(for: 1, maxPixelSize: 64) === firstSmall)
        XCTAssertTrue(cache.image(for: 1, maxPixelSize: 512) === firstLarge)
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 64) === secondSmall)
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 512) === secondLarge)
        urls[1] = replacement
        XCTAssertFalse(cache.image(for: 1, maxPixelSize: 512) === firstLarge)
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 512) === secondLarge)
        urls[1] = nil
        XCTAssertNil(cache.image(for: 1, maxPixelSize: 512))
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 64) === secondSmall)
    }

    func testSharedWallpaperSurvivesOneDisplayChanging() throws {
        let shared = try makeImageFile(width: 400, height: 200)
        let replacement = try makeImageFile(width: 300, height: 300)
        defer {
            for url in [shared, replacement] { try? FileManager.default.removeItem(at: url) }
        }
        var urls: [CGDirectDisplayID: URL] = [1: shared, 2: shared]
        let cache = OverviewWallpaperCache()
        cache.captureWallpaper = { _ in nil }
        cache.desktopImageURL = { urls[$0] }
        let original = try XCTUnwrap(cache.image(for: 1, maxPixelSize: 512))
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 512) === original)
        urls[1] = replacement
        XCTAssertFalse(cache.image(for: 1, maxPixelSize: 512) === original)
        XCTAssertTrue(cache.image(for: 2, maxPixelSize: 512) === original)
        cache.clear()
        XCTAssertFalse(cache.image(for: 2, maxPixelSize: 512) === original)
    }

    private func assertGray(
        _ image: CGImage?, equals gray: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let bitmap = try NSBitmapImageRep(cgImage: XCTUnwrap(image, file: file, line: line))
        let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertEqual(color.redComponent, gray, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.greenComponent, gray, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.blueComponent, gray, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, file: file, line: line)
    }

    private func makeSolidImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeImageFile(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverviewWallpaperCacheTests-\(UUID().uuidString).png")
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
