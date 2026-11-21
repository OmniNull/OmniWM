// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreAudio
import CoreMediaIO
@testable import OmniWM
import OmniWMAudioTap
import XCTest

@MainActor
final class AudioPropertyListenerTests: XCTestCase {
    private final class Capture {
        let released: XCTestExpectation?

        init(_ released: XCTestExpectation? = nil) {
            self.released = released
        }

        deinit {
            released?.fulfill()
        }
    }

    func testNativeAudioBlockOwnsItsCaptureUntilDestroyed() {
        weak var capture: Capture?
        let native = {
            let value = Capture()
            capture = value
            return omni_audio_listener_block_create { _, _ in withExtendedLifetime(value) {} }
        }()
        XCTAssertNotNil(capture)
        omni_audio_listener_block_destroy(native)
        XCTAssertNil(capture)
    }

    func testNativeVideoBlockOwnsItsCaptureUntilDestroyed() {
        weak var capture: Capture?
        let native = {
            let value = Capture()
            capture = value
            return omni_video_listener_block_create { _, _ in withExtendedLifetime(value) {} }
        }()
        XCTAssertNotNil(capture)
        omni_video_listener_block_destroy(native)
        XCTAssertNil(capture)
    }

    func testAudioRemovalReleasesTheFrameworksCapturedState() async throws {
        let released = expectation(description: "Core Audio released its listener")
        let listener = try XCTUnwrap(Self.audioListener(released))
        listener.remove(on: .main)
        await fulfillment(of: [released], timeout: failureBound)
    }

    func testVideoRemovalReleasesTheFrameworksCapturedState() async throws {
        let released = expectation(description: "Core Media IO released its listener")
        let listener = try XCTUnwrap(Self.videoListener(released))
        listener.remove(on: .main)
        await fulfillment(of: [released], timeout: failureBound)
    }

    func testFailedVideoRegistrationReleasesItsCapturedState() async {
        let released = expectation(description: "Rejected camera listener released")
        let listener = Self.videoListener(released, object: CMIOObjectID(kCMIOObjectUnknown))
        XCTAssertNil(listener)
        await fulfillment(of: [released], timeout: failureBound)
    }

    func testFailedAudioRegistrationReleasesItsCapturedState() async {
        let released = expectation(description: "Rejected audio listener released")
        let listener = Self.audioListener(released, object: AudioObjectID(kAudioObjectUnknown))
        XCTAssertNil(listener)
        await fulfillment(of: [released], timeout: failureBound)
    }

    private static func audioListener(
        _ released: XCTestExpectation,
        object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)
    ) -> AudioPropertyListener? {
        let capture = Capture(released)
        return AudioPropertyListener.listen(to: object, address: ShellAudio.devicesAddress, queue: .main) { _, _ in
            withExtendedLifetime(capture) {}
        }
    }

    private static func videoListener(
        _ released: XCTestExpectation,
        object: CMIOObjectID = CMIOObjectID(kCMIOObjectSystemObject)
    ) -> VideoPropertyListener? {
        let capture = Capture(released)
        let address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        return VideoPropertyListener.listen(to: object, address: address, queue: .main) { _, _ in
            withExtendedLifetime(capture) {}
        }
    }
}
