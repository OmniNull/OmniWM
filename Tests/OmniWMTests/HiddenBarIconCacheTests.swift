// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarIconCacheTests: XCTestCase {
    private func makeImage(width: Int = 8, height: Int = 8, red: CGFloat = 1, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if alpha > 0 {
            context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    private func key(_ bundleID: String, _ ordinal: Int = 0) -> MenuBarItemKey {
        MenuBarItemKey(bundleID: bundleID, ordinal: ordinal)
    }

    private func item(_ bundleID: String, _ ordinal: Int = 0) -> ResolvedMenuBarItem {
        ResolvedMenuBarItem(
            key: key(bundleID, ordinal),
            pid: 100,
            bounds: CGRect(x: ordinal * 20, y: 0, width: 20, height: 20)
        )
    }

    @MainActor
    func testReplaceNewIconFiresOnChangeOnce() {
        let cache = HiddenBarIconCache()
        var fired = 0
        cache.onChange = { fired += 1 }
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: makeImage(), scale: 2)]
        )
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(cache.icons.count, 1)
    }

    @MainActor
    func testReplaceFiresOnlyWhenIconVisuallyChanges() {
        let cases: [(label: String, red: CGFloat, scale: CGFloat, expectedFires: Int)] = [
            ("visually equal", 1, 2, 0),
            ("changed pixels", 0.5, 2, 1),
            ("changed scale", 1, 1, 1)
        ]
        for testCase in cases {
            let cache = HiddenBarIconCache()
            cache.replaceResolvedItems(
                ["a": [item("a")]],
                capturedIcons: [key("a"): CapturedIcon(image: makeImage(), scale: 2)]
            )
            var fired = 0
            cache.onChange = { fired += 1 }
            cache.replaceResolvedItems(
                ["a": [item("a")]],
                capturedIcons: [key("a"): CapturedIcon(image: makeImage(red: testCase.red), scale: testCase.scale)]
            )
            XCTAssertEqual(fired, testCase.expectedFires, testCase.label)
        }
    }

    @MainActor
    func testPruneRemovesOtherBundlesAndFires() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(
            ["a": [item("a")], "b": [item("b")]],
            capturedIcons: [
                key("a"): CapturedIcon(image: makeImage(), scale: 2),
                key("b"): CapturedIcon(image: makeImage(), scale: 2)
            ]
        )
        var fired = 0
        cache.onChange = { fired += 1 }
        cache.prune(keeping: ["a"])
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(cache.icons.keys.map(\.bundleID), ["a"])
        XCTAssertNil(cache.resolvedItems(for: "b"))
    }

    @MainActor
    func testPruneWithNothingStaleDoesNotFire() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: makeImage(), scale: 2)]
        )
        var fired = 0
        cache.onChange = { fired += 1 }
        cache.prune(keeping: ["a"])
        XCTAssertEqual(fired, 0)
    }

    @MainActor
    func testAuthoritativeReplacementRemovesStaleOrdinalAndImage() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(
            ["a": [item("a", 0), item("a", 1)]],
            capturedIcons: [
                key("a", 0): CapturedIcon(image: makeImage(), scale: 2),
                key("a", 1): CapturedIcon(image: makeImage(), scale: 2)
            ]
        )
        cache.replaceResolvedItems(["a": [item("a", 0)]])
        XCTAssertEqual(cache.resolvedItems(for: "a")?.map(\.key.ordinal), [0])
        XCTAssertNotNil(cache.icons[key("a", 0)])
        XCTAssertNil(cache.icons[key("a", 1)])
    }

    @MainActor
    func testAuthoritativeReplacementAddsNewOrdinalInSortedOrder() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(["a": [item("a", 2), item("a", 0)]])
        cache.replaceResolvedItems(["a": [item("a", 2), item("a", 1), item("a", 0)]])
        XCTAssertEqual(cache.resolvedItems(for: "a")?.map(\.key.ordinal), [0, 1, 2])
        XCTAssertNil(cache.resolvedItems(for: "a")?[1].icon)
    }

    @MainActor
    func testMissingResolutionPreservesPriorSnapshot() {
        let cache = HiddenBarIconCache()
        let image = makeImage()
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: image, scale: 2)]
        )
        cache.replaceResolvedItems([:])
        XCTAssertEqual(cache.resolvedItems(for: "a")?.map(\.key.ordinal), [0])
        XCTAssertTrue(cache.icons[key("a")]?.image === image)
    }

    @MainActor
    func testSuccessfulEmptyResolutionClearsSnapshot() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: makeImage(), scale: 2)]
        )
        cache.replaceResolvedItems(["a": []])
        XCTAssertEqual(cache.resolvedItems(for: "a")?.count, 0)
        XCTAssertTrue(cache.icons.isEmpty)
    }

    @MainActor
    func testCaptureFailurePreservesPriorImageForResolvedKey() {
        let cache = HiddenBarIconCache()
        let image = makeImage()
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: image, scale: 2)]
        )
        var fired = 0
        cache.onChange = { fired += 1 }
        cache.replaceResolvedItems(["a": [item("a")]])
        XCTAssertEqual(fired, 0)
        XCTAssertTrue(cache.resolvedItems(for: "a")?[0].icon?.image === image)
    }

    @MainActor
    func testAuthoritativeIconReplacementClearsStaleSameOrdinalImage() {
        let cache = HiddenBarIconCache()
        cache.replaceResolvedItems(
            ["a": [item("a")]],
            capturedIcons: [key("a"): CapturedIcon(image: makeImage(), scale: 2)]
        )

        cache.replaceResolvedItems(
            ["a": [item("a")]],
            replacingCapturedIcons: true
        )

        XCTAssertNil(cache.resolvedItems(for: "a")?[0].icon)
    }

    @MainActor
    func testReorderedCapturedImagesCommitOnce() {
        let cache = HiddenBarIconCache()
        let first = makeImage(red: 1)
        let second = makeImage(red: 0.5)
        cache.replaceResolvedItems(
            ["a": [item("a", 0), item("a", 1)]],
            capturedIcons: [
                key("a", 0): CapturedIcon(image: first, scale: 2),
                key("a", 1): CapturedIcon(image: second, scale: 2)
            ]
        )
        var fired = 0
        cache.onChange = { fired += 1 }
        cache.replaceResolvedItems(
            ["a": [item("a", 1), item("a", 0)]],
            capturedIcons: [
                key("a", 0): CapturedIcon(image: second, scale: 2),
                key("a", 1): CapturedIcon(image: first, scale: 2)
            ]
        )
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(cache.icons[key("a", 0)]?.image === second)
        XCTAssertTrue(cache.icons[key("a", 1)]?.image === first)
    }

    func testVisualEqualityFastPathAndPixelPath() {
        let image = makeImage()
        let same = CapturedIcon(image: image, scale: 2)
        XCTAssertTrue(HiddenBarIconCache.isVisuallyEqual(same, CapturedIcon(image: image, scale: 2)))
        XCTAssertTrue(HiddenBarIconCache.isVisuallyEqual(
            CapturedIcon(image: makeImage(), scale: 2),
            CapturedIcon(image: makeImage(), scale: 2)
        ))
        XCTAssertFalse(HiddenBarIconCache.isVisuallyEqual(
            CapturedIcon(image: makeImage(red: 1), scale: 2),
            CapturedIcon(image: makeImage(red: 0.25), scale: 2)
        ))
        XCTAssertFalse(HiddenBarIconCache.isVisuallyEqual(same, nil))
        XCTAssertTrue(HiddenBarIconCache.isVisuallyEqual(nil, nil))
    }

    func testTransparencyDetection() {
        XCTAssertTrue(HiddenBarIconCaptureService.isEffectivelyTransparent(makeImage(alpha: 0)))
        XCTAssertFalse(HiddenBarIconCaptureService.isEffectivelyTransparent(makeImage(alpha: 1)))
    }
}
