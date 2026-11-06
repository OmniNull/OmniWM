// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadScrollTraceTests: XCTestCase {
    func testWorkspaceReleaseTraceRecordsTheActualDecision() throws {
        let recorder = TrackpadScrollTrace.shared
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        let motion = WorkspaceSwipeMotion(
            cumulativeUnits: 180, timestamp: 1.03,
            recognitionMovement: SwipeEvent(delta: 180, timestamp: 1)
        )
        XCTAssertTrue(motion.release(timestamp: 1.04, allowFlick: true, animationTime: 100))
        let line = try XCTUnwrap(recorder.dump().split(separator: "\n").first {
            $0.contains("workspace-presentation renderer=preview action=released")
        })
        let values = Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { field -> (
            String,
            String
        )? in
            let pair = field.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        XCTAssertEqual(
            try XCTUnwrap(values["velocity"].flatMap(Double.init)),
            180 / WorkspaceSwipeMotion.travelUnits / (1.04 - 1)
        )
        XCTAssertGreaterThan(try XCTUnwrap(values["projected"].flatMap(Double.init)), 0.5)
        XCTAssertEqual(values["progress"], "0.0")
        XCTAssertEqual(values["target"], "1.0")
        XCTAssertEqual(values["allowFlick"], "true")
    }

    func testInactiveTraceDoesNotEvaluateRecordsOrAllocateStorage() {
        let recorder = TrackpadScrollTrace.shared
        recorder.endCapture()
        recorder.releaseStorage()
        var evaluations = 0
        let event: () -> TrackpadScrollTrace.Event = {
            evaluations += 1
            return .reset(generation: 1)
        }

        TrackpadScrollTrace.record(event())

        XCTAssertEqual(evaluations, 0)
        XCTAssertFalse(recorder.isStoragePrepared)
        XCTAssertFalse(recorder.isSpareStoragePrepared)
        XCTAssertFalse(recorder.isRetainedStoragePrepared)
        XCTAssertEqual(recorder.dump(), "none")
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        TrackpadScrollTrace.record(event())
        XCTAssertEqual(evaluations, 1)
        XCTAssertTrue(recorder.dump().contains("reset generation=1"))
        recorder.endCapture()
        TrackpadScrollTrace.record(event())
        XCTAssertEqual(evaluations, 1)
    }

    func testTraceRetains4096NewestRecordsAndReportsEvictionAcrossExports() {
        let recorder = TrackpadScrollTrace.shared
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        for generation in UInt(0) ... 4096 {
            TrackpadScrollTrace.record(.reset(generation: generation))
        }
        var lines = recorder.dump().split(separator: "\n")
        XCTAssertEqual(lines.count, 4097)
        XCTAssertEqual(lines.first, "incomplete=true evicted=1")
        XCTAssertTrue(lines[1].hasSuffix("reset generation=1"))
        XCTAssertTrue(lines.last?.hasSuffix("reset generation=4096") == true)

        TrackpadScrollTrace.record(.reset(generation: 4097))
        lines = recorder.dump().split(separator: "\n")
        XCTAssertEqual(lines.count, 4097)
        XCTAssertEqual(lines.first, "incomplete=true evicted=2")
        XCTAssertTrue(lines[1].hasSuffix("reset generation=2"))
        XCTAssertTrue(lines.last?.hasSuffix("reset generation=4097") == true)
        recorder.beginCapture()
        XCTAssertEqual(recorder.dump(), "none")
    }

    func testPhasedScrollPayloadIsUnchangedWhenTraceAddsSenderMetadata() throws {
        let recorder = TrackpadScrollTrace.shared
        recorder.endCapture()
        recorder.releaseStorage()
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 8, wheel2: -3, wheel3: 0
        ))
        event.timestamp = 713_000_000
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let location = CGPoint(x: 800, y: 450)
        let modifiers = CGEventFlags.maskAlternate.rawValue
        let inactive = MouseEventHandler.scrollPayload(event, at: location, modifiersRawValue: modifiers)
        XCTAssertNil(inactive.traceMetadata)

        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        let active = MouseEventHandler.scrollPayload(event, at: location, modifiersRawValue: modifiers)

        XCTAssertTrue(active.payload.matches(inactive.payload))
        XCTAssertEqual(active.payload.location, inactive.payload.location)
        XCTAssertEqual(active.payload.deltaX, inactive.payload.deltaX)
        XCTAssertEqual(active.payload.deltaY, inactive.payload.deltaY)
        XCTAssertNil(active.payload.senderId)
        let metadata = try XCTUnwrap(active.traceMetadata)
        XCTAssertEqual(metadata.eventTimestamp, 713_000_000)
        XCTAssertGreaterThan(metadata.observedAt, 0)
        XCTAssertNotEqual(metadata.senderLookup, .notRequested)
    }
}
