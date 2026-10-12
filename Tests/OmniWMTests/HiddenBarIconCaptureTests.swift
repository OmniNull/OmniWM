// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarIconCaptureTests: XCTestCase {
    private let displayFrame = CGRect(x: 2560, y: -1080, width: 1920, height: 1080)
    private let hostFrame = CGRect(x: 2560, y: -1080, width: 1920, height: 30)
    private let itemBounds = CGRect(x: 4000, y: -1077, width: 100, height: 24)

    private func matches(
        bundleIdentifier: String? = "com.apple.MenuBarAgent",
        layer: Int = Int(CGWindowLevelForKey(.mainMenuWindow)),
        frame: CGRect? = nil,
        bounds: CGRect? = nil
    ) -> Bool {
        HiddenBarIconCaptureService.isMenuBarHostingWindow(
            bundleIdentifier: bundleIdentifier,
            layer: layer,
            frame: frame ?? hostFrame,
            displayFrame: displayFrame,
            itemBounds: bounds ?? itemBounds
        )
    }

    func testAcceptsHostOnDisplayAbovePrimary() {
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(bounds: hostFrame))
    }

    func testRejectsOtherOwnersAndWindowLayers() {
        XCTAssertFalse(matches(bundleIdentifier: nil))
        XCTAssertFalse(matches(bundleIdentifier: "com.example.StatusItem"))
        XCTAssertFalse(matches(layer: Int(CGWindowLevelForKey(.statusWindow))))
        XCTAssertFalse(matches(layer: Int(CGWindowLevelForKey(.normalWindow))))
    }

    func testRejectsOtherDisplayAndNonMenuBarFrames() {
        XCTAssertFalse(matches(frame: CGRect(x: 0, y: 0, width: 2560, height: 30)))
        XCTAssertFalse(matches(frame: hostFrame.offsetBy(dx: 0, dy: 30)))
        XCTAssertFalse(matches(frame: CGRect(x: 2560, y: -1080, width: 1800, height: 30)))
        XCTAssertFalse(matches(frame: displayFrame))
        XCTAssertFalse(matches(frame: CGRect(x: 2560, y: -1080, width: 1920, height: 0)))
    }

    func testRejectsHostThatDoesNotContainAllRequestedItems() {
        XCTAssertFalse(matches(bounds: CGRect(x: 4470, y: -1077, width: 24, height: 24)))
        XCTAssertFalse(matches(bounds: CGRect(x: 4000, y: -1055, width: 24, height: 24)))
    }

    func testCropsRelativeToHostInsteadOfRequestedItems() {
        XCTAssertEqual(
            HiddenBarIconCaptureService.cropRects(bounds: [itemBounds], union: hostFrame, scale: 1),
            [CGRect(x: 1440, y: 3, width: 100, height: 24)]
        )
        XCTAssertEqual(
            HiddenBarIconCaptureService.cropRects(bounds: [itemBounds], union: hostFrame, scale: 2),
            [CGRect(x: 2880, y: 6, width: 200, height: 48)]
        )
    }

    func testFractionalItemBoundsExpandToWholePixels() {
        let bounds = CGRect(x: 3000.25, y: -1077.75, width: 24.25, height: 20.25)
        XCTAssertEqual(
            HiddenBarIconCaptureService.cropRects(bounds: [bounds], union: hostFrame, scale: 2),
            [CGRect(x: 880, y: 4, width: 49, height: 41)]
        )
    }

    func testCroppedIconEqualityIgnoresPixelsOutsideBounds() throws {
        let original = try capturedIcon(iconRed: 1, neighborGreen: 0)
        let neighborChanged = try capturedIcon(iconRed: 1, neighborGreen: 1)
        let iconChanged = try capturedIcon(iconRed: 0.5, neighborGreen: 0)

        XCTAssertTrue(HiddenBarIconCache.isVisuallyEqual(original, neighborChanged))
        XCTAssertFalse(HiddenBarIconCache.isVisuallyEqual(original, iconChanged))
        XCTAssertEqual(original.image.bytesPerRow, original.image.width * 4)
        let bytes = try XCTUnwrap(original.image.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(bytes), original.image.width * original.image.height * 4)
    }

    private func capturedIcon(iconRed: CGFloat, neighborGreen: CGFloat) throws -> CapturedIcon {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 100,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let iconRect = CGRect(x: 20, y: 0, width: 24, height: 24)
        context.setFillColor(CGColor(red: iconRed, green: 0, blue: 0, alpha: 1))
        context.fill(iconRect)
        context.setFillColor(CGColor(red: 0, green: neighborGreen, blue: 0, alpha: 1))
        context.fill(CGRect(x: 80, y: 0, width: 20, height: 24))
        let composite = try XCTUnwrap(context.makeImage())
        let image = try XCTUnwrap(HiddenBarIconCaptureService.isolatedCrop(composite, to: iconRect))
        return CapturedIcon(image: image, scale: 2)
    }
}
