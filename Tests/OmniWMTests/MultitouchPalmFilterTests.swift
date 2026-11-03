// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class MultitouchPalmFilterTests: XCTestCase {
    private struct Contact {
        var pathId: Int32
        var state: Int32 = 4
        var fingerId: Int32 = 2
        var majorAxis: Float = 8
        var x: Float = 0.5
        var y: Float = 0.5
    }

    private static let touchStride = 96

    private static func withRawContacts<Result>(
        _ contacts: [Contact],
        _ body: (UnsafeMutableRawPointer?, Int32) -> Result
    ) -> Result {
        let byteCount = max(contacts.count, 1) * touchStride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        for (index, contact) in contacts.enumerated() {
            let base = index * touchStride
            buffer.storeBytes(of: contact.pathId, toByteOffset: base + 16, as: Int32.self)
            buffer.storeBytes(of: contact.state, toByteOffset: base + 20, as: Int32.self)
            buffer.storeBytes(of: contact.fingerId, toByteOffset: base + 24, as: Int32.self)
            buffer.storeBytes(of: contact.x, toByteOffset: base + 32, as: Float.self)
            buffer.storeBytes(of: contact.y, toByteOffset: base + 36, as: Float.self)
            buffer.storeBytes(of: contact.majorAxis, toByteOffset: base + 60, as: Float.self)
        }
        return body(buffer, Int32(contacts.count))
    }

    private func touchCount(_ contacts: [Contact], filter: inout MultitouchPalmFilter) -> Int {
        Self.withRawContacts(contacts) { fingers, count in
            MultitouchGestureSource.buildRawFrame(
                fingers: fingers,
                count: count,
                timestamp: 1,
                palmFilter: &filter
            )
        }.touches.count
    }

    func testFingersBesideRestingPalmCountOnlyFingers() {
        var filter = MultitouchPalmFilter()
        let contacts = [
            Contact(pathId: 1, fingerId: 2, x: 0.45, y: 0.4),
            Contact(pathId: 2, fingerId: 3, x: 0.55, y: 0.45),
            Contact(pathId: 3, fingerId: 7, majorAxis: 14, x: 0.01, y: 0.7)
        ]
        XCTAssertEqual(touchCount(contacts, filter: &filter), 2)
    }

    func testThreeFingersBesideRestingPalmStillCountAsThree() {
        var filter = MultitouchPalmFilter()
        let contacts = [
            Contact(pathId: 1, fingerId: 2, x: 0.42, y: 0.41),
            Contact(pathId: 2, fingerId: 3, x: 0.5, y: 0.57),
            Contact(pathId: 3, fingerId: 4, x: 0.68, y: 0.58),
            Contact(pathId: 4, fingerId: 12, majorAxis: 17, x: 0.07, y: 0.86)
        ]
        XCTAssertEqual(touchCount(contacts, filter: &filter), 3)
    }

    func testOversizedContactIsRejectedDespiteFingerLabel() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 4, fingerId: 1, majorAxis: 24)], filter: &filter), 0)
    }

    func testUnclassifiedFingertipStillCounts() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 1, fingerId: 0)], filter: &filter), 1)
    }

    func testContactLabelledPalmBeforeTouchingStaysRejectedWhenRelabelled() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 5, state: 2, fingerId: 6, majorAxis: 12)], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 5, state: 4, fingerId: 5, majorAxis: 12)], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 5, state: 4, fingerId: 1, majorAxis: 12)], filter: &filter), 0)
    }

    func testPathReusedAfterPalmLiftsCountsAsFinger() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 5, fingerId: 7, majorAxis: 22)], filter: &filter), 0)
        XCTAssertEqual(touchCount([], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 5, fingerId: 2)], filter: &filter), 1)
    }

    func testPalmLandingAgainOnItsPathStaysRejected() {
        var filter = MultitouchPalmFilter()
        let x: Float = 0.05
        let y: Float = 0.73
        let frames = [
            Contact(pathId: 5, state: 4, fingerId: 7, majorAxis: 14.3, x: x, y: y),
            Contact(pathId: 5, state: 7, fingerId: 0, majorAxis: 0, x: x, y: y),
            Contact(pathId: 5, state: 1, fingerId: 0, majorAxis: 13.5, x: x, y: y),
            Contact(pathId: 5, state: 3, fingerId: 3, majorAxis: 13.5, x: x, y: y),
            Contact(pathId: 5, state: 4, fingerId: 3, majorAxis: 13.6, x: x, y: y)
        ]
        for contact in frames {
            XCTAssertEqual(touchCount([Contact(pathId: 1, fingerId: 2), contact], filter: &filter), 1)
        }
    }

    func testPalmOnOtherPathDoesNotOutliveItsContact() {
        var filter = MultitouchPalmFilter()
        let palmAndFinger = [
            Contact(pathId: 1, fingerId: 2),
            Contact(pathId: 6, fingerId: 6, majorAxis: 19, x: 0.99, y: 0.4)
        ]
        XCTAssertEqual(touchCount(palmAndFinger, filter: &filter), 1)
        XCTAssertEqual(touchCount([Contact(pathId: 1, fingerId: 2)], filter: &filter), 1)
        XCTAssertEqual(
            touchCount([Contact(pathId: 1, fingerId: 2), Contact(pathId: 6, fingerId: 3)], filter: &filter),
            2
        )
    }

    func testPalmOnUntrackedPathIdStaysRejectedUntilItLifts() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 200, fingerId: 7, majorAxis: 22)], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 200, fingerId: 2, majorAxis: 12)], filter: &filter), 0)
        XCTAssertEqual(touchCount([], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 200, fingerId: 2)], filter: &filter), 1)
    }

    func testNewRegistrationGenerationForgetsPalms() {
        var filters = MultitouchPalmFilters()
        let palm = [Contact(pathId: 3, fingerId: 7, majorAxis: 22)]
        let finger = [Contact(pathId: 3, fingerId: 2)]
        let first = MultitouchGestureSource.RegistrationToken(generation: 1, slot: 0)
        let second = MultitouchGestureSource.RegistrationToken(generation: 2, slot: 0)

        let palmFrame = Self.withRawContacts(palm) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: 1, token: first)
        }
        XCTAssertEqual(palmFrame.touches.count, 0)

        let fingerFrame = Self.withRawContacts(finger) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: 2, token: second)
        }
        XCTAssertEqual(fingerFrame.touches.count, 1)
    }

    func testFingerPositionsSurviveFiltering() throws {
        var filter = MultitouchPalmFilter()
        let contacts = [
            Contact(pathId: 2, fingerId: 6, majorAxis: 15, x: 0.01, y: 0.9),
            Contact(pathId: 1, fingerId: 2, x: 0.25, y: 0.75)
        ]
        let frame = Self.withRawContacts(contacts) { fingers, count in
            MultitouchGestureSource.buildRawFrame(fingers: fingers, count: count, timestamp: 3, palmFilter: &filter)
        }
        let touch = try XCTUnwrap(frame.touches.first)
        XCTAssertEqual(frame.touches.count, 1)
        XCTAssertEqual(touch.x, 0.25)
        XCTAssertEqual(touch.y, 0.75)
        XCTAssertEqual(frame.timestamp, 3)
    }
}
