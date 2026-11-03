// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class MultitouchPalmFilterTests: XCTestCase {
    private struct Contact {
        var pathId: Int32
        var state = multitouchTouchingState
        var fingerId: Int32 = 2
        var majorAxis: Float = 8
        var x: Float = 0.5
        var y: Float = 0.5
    }

    private static let palmFingerId = multitouchFingerIds.upperBound + 1
    private static let oversizedMajorAxis = multitouchPalmMajorAxisMillimeters.nextUp

    private static func withRawContacts<Result>(
        _ contacts: [Contact],
        _ body: (UnsafeMutableRawPointer?, Int32) -> Result
    ) -> Result {
        let byteCount = max(contacts.count, 1) * multitouchTouchStride
        let alignment = max(MemoryLayout<Int32>.alignment, MemoryLayout<Float>.alignment)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        for (index, contact) in contacts.enumerated() {
            let base = index * multitouchTouchStride
            buffer.storeBytes(of: contact.pathId, toByteOffset: base + multitouchPathIdByteOffset, as: Int32.self)
            buffer.storeBytes(of: contact.state, toByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            buffer.storeBytes(of: contact.fingerId, toByteOffset: base + multitouchFingerIdByteOffset, as: Int32.self)
            buffer.storeBytes(of: contact.x, toByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            buffer.storeBytes(of: contact.y, toByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            buffer.storeBytes(of: contact.majorAxis, toByteOffset: base + multitouchMajorAxisByteOffset, as: Float.self)
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
            Contact(pathId: 3, fingerId: Self.palmFingerId, majorAxis: 14, x: 0.01, y: 0.7)
        ]
        XCTAssertEqual(touchCount(contacts, filter: &filter), 2)
    }

    func testThreeFingersBesideRestingPalmStillCountAsThree() {
        var filter = MultitouchPalmFilter()
        let contacts = [
            Contact(pathId: 1, fingerId: 2, x: 0.42, y: 0.41),
            Contact(pathId: 2, fingerId: 3, x: 0.5, y: 0.57),
            Contact(pathId: 3, fingerId: 4, x: 0.68, y: 0.58),
            Contact(pathId: 4, fingerId: Self.palmFingerId, majorAxis: 17, x: 0.07, y: 0.86)
        ]
        XCTAssertEqual(touchCount(contacts, filter: &filter), 3)
    }

    func testOversizedContactIsRejectedDespiteFingerLabel() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(
            touchCount(
                [Contact(pathId: 4, fingerId: multitouchFingerIds.lowerBound, majorAxis: Self.oversizedMajorAxis)],
                filter: &filter
            ),
            0
        )
    }

    func testUnclassifiedFingertipStillCounts() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(touchCount([Contact(pathId: 1, fingerId: multitouchUnclassifiedFingerId)], filter: &filter), 1)
    }

    func testContactLabelledPalmBeforeTouchingStaysRejectedWhenRelabelled() {
        var filter = MultitouchPalmFilter()
        let palm = Contact(pathId: 5, state: 2, fingerId: Self.palmFingerId, majorAxis: 12)
        XCTAssertEqual(touchCount([palm], filter: &filter), 0)
        var finger = palm
        finger.state = multitouchTouchingState
        finger.fingerId = multitouchFingerIds.upperBound
        XCTAssertEqual(touchCount([finger], filter: &filter), 0)
        finger.fingerId = multitouchFingerIds.lowerBound
        XCTAssertEqual(touchCount([finger], filter: &filter), 0)
    }

    func testPathReusedAfterPalmLiftsCountsAsFinger() {
        var filter = MultitouchPalmFilter()
        XCTAssertEqual(
            touchCount(
                [Contact(pathId: 5, fingerId: Self.palmFingerId, majorAxis: Self.oversizedMajorAxis)],
                filter: &filter
            ),
            0
        )
        XCTAssertEqual(touchCount([], filter: &filter), 0)
        XCTAssertEqual(touchCount([Contact(pathId: 5, fingerId: 2)], filter: &filter), 1)
    }

    func testPalmLandingAgainOnItsPathStaysRejected() {
        var filter = MultitouchPalmFilter()
        let x: Float = 0.05
        let y: Float = 0.73
        let frames = [
            Contact(pathId: 5, fingerId: Self.palmFingerId, majorAxis: 14.3, x: x, y: y),
            Contact(pathId: 5, state: 7, fingerId: multitouchUnclassifiedFingerId, majorAxis: 0, x: x, y: y),
            Contact(pathId: 5, state: 1, fingerId: multitouchUnclassifiedFingerId, majorAxis: 13.5, x: x, y: y),
            Contact(pathId: 5, state: 3, fingerId: 3, majorAxis: 13.5, x: x, y: y),
            Contact(pathId: 5, fingerId: 3, majorAxis: 13.6, x: x, y: y)
        ]
        for contact in frames {
            XCTAssertEqual(touchCount([Contact(pathId: 1, fingerId: 2), contact], filter: &filter), 1)
        }
    }

    func testPalmOnOtherPathDoesNotOutliveItsContact() {
        var filter = MultitouchPalmFilter()
        let palmAndFinger = [
            Contact(pathId: 1, fingerId: 2),
            Contact(
                pathId: 6,
                fingerId: Self.palmFingerId,
                majorAxis: multitouchPalmMajorAxisMillimeters.nextDown,
                x: 0.99,
                y: 0.4
            )
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
        let palm = Contact(
            pathId: multitouchTrackedPathCount,
            fingerId: Self.palmFingerId,
            majorAxis: Self.oversizedMajorAxis
        )
        var finger = palm
        finger.fingerId = multitouchFingerIds.lowerBound
        finger.majorAxis = multitouchPalmMajorAxisMillimeters.nextDown
        XCTAssertEqual(touchCount([palm], filter: &filter), 0)
        XCTAssertEqual(touchCount([finger], filter: &filter), 0)
        XCTAssertEqual(touchCount([], filter: &filter), 0)
        XCTAssertEqual(touchCount([finger], filter: &filter), 1)
    }

    func testNewRegistrationGenerationForgetsPalms() {
        var filters = MultitouchPalmFilters()
        let palm = [Contact(pathId: 3, fingerId: Self.palmFingerId, majorAxis: Self.oversizedMajorAxis)]
        let finger = [Contact(pathId: 3, fingerId: 2)]
        let first = MultitouchGestureSource.RegistrationToken(generation: 1, slot: 0)
        let second = MultitouchGestureSource.RegistrationToken(generation: first.generation + 1, slot: first.slot)
        let firstTimestamp: Double = 1
        let secondTimestamp = firstTimestamp.nextUp

        let palmFrame = Self.withRawContacts(palm) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: firstTimestamp, token: first)
        }
        XCTAssertEqual(palmFrame.touches.count, 0)

        let fingerFrame = Self.withRawContacts(finger) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: secondTimestamp, token: second)
        }
        XCTAssertEqual(fingerFrame.touches.count, 1)
    }

    func testOlderRegistrationCannotResetTheCurrentPalmLatch() {
        var filters = MultitouchPalmFilters()
        let palm = Contact(pathId: multitouchTrackedPathCount - 1, fingerId: Self.palmFingerId)
        var finger = palm
        finger.fingerId = multitouchFingerIds.lowerBound
        let older = MultitouchGestureSource.RegistrationToken(generation: 1, slot: 0)
        let current = MultitouchGestureSource.RegistrationToken(generation: older.generation + 1, slot: older.slot)
        let timestamp: Double = 1

        let palmFrame = Self.withRawContacts([palm]) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: timestamp, token: current)
        }
        XCTAssertEqual(palmFrame.touches.count, 0)

        _ = Self.withRawContacts([]) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: timestamp.nextUp, token: older)
        }

        let fingerTimestamp = timestamp.nextUp.nextUp
        let fingerFrame = Self.withRawContacts([finger]) { fingers, count in
            filters.buildRawFrame(fingers: fingers, count: count, timestamp: fingerTimestamp, token: current)
        }
        XCTAssertEqual(fingerFrame.touches.count, 0)
        XCTAssertEqual(fingerFrame.timestamp, fingerTimestamp)
    }

    func testFingerPositionsSurviveFiltering() throws {
        var filter = MultitouchPalmFilter()
        let finger = Contact(pathId: 1, fingerId: 2, x: 0.25, y: 0.75)
        let timestamp: Double = 3
        let contacts = [
            Contact(pathId: 2, fingerId: Self.palmFingerId, majorAxis: 15, x: 0.01, y: 0.9),
            finger
        ]
        let frame = Self.withRawContacts(contacts) { fingers, count in
            MultitouchGestureSource.buildRawFrame(
                fingers: fingers,
                count: count,
                timestamp: timestamp,
                palmFilter: &filter
            )
        }
        let touch = try XCTUnwrap(frame.touches.first)
        XCTAssertEqual(frame.touches.count, 1)
        XCTAssertEqual(touch.x, finger.x)
        XCTAssertEqual(touch.y, finger.y)
        XCTAssertEqual(frame.timestamp, timestamp)
    }
}
