// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreAudio
import OmniWMAudioTap
import XCTest

final class AppVolumeRenderTests: XCTestCase {
    private func render(
        source: [Float],
        sourceChannels: UInt32,
        inputs: [(channels: UInt32, samples: [Float])] = [],
        outputs: [(channels: UInt32, frames: Int)],
        gain: Float,
        tapChannels: UInt32? = nil
    ) throws -> [[Float]] {
        let state = try XCTUnwrap(omni_audio_gain_create(tapChannels ?? sourceChannels, gain))
        defer { omni_audio_gain_destroy(state) }
        let buffers = inputs + [(sourceChannels, source)]
        let input = AudioBufferList.allocate(maximumBuffers: buffers.count)
        let output = AudioBufferList.allocate(maximumBuffers: outputs.count)
        var storage: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            storage.forEach { $0.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        for (index, buffer) in buffers.enumerated() {
            let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: buffer.samples.count)
            _ = samples.initialize(from: buffer.samples)
            storage.append(samples)
            input[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples.baseAddress)
            )
        }
        for (index, buffer) in outputs.enumerated() {
            let count = Int(buffer.channels) * buffer.frames
            let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            samples.initialize(repeating: 9)
            storage.append(samples)
            output[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples.baseAddress)
            )
        }
        var time = AudioTimeStamp()
        XCTAssertEqual(
            omni_audio_gain_render(
                0,
                &time,
                input.unsafePointer,
                &time,
                output.unsafeMutablePointer,
                &time,
                UnsafeMutableRawPointer(state)
            ),
            noErr
        )
        return storage.suffix(outputs.count).map(Array.init)
    }

    func testStereoSourceIsScaledIntoTheFrontChannelsAndTheRestIsSilenced() throws {
        let rendered = try render(
            source: [1, -1, 0.5, -0.5],
            sourceChannels: 2,
            outputs: [(channels: 4, frames: 2)],
            gain: 0.5
        )
        XCTAssertEqual(rendered, [[0.5, -0.5, 0, 0, 0.25, -0.25, 0, 0]])
    }

    func testTheTapIsTheLastMatchingInputAfterADeviceMicrophone() throws {
        let rendered = try render(
            source: [1, 1],
            sourceChannels: 2,
            inputs: [(channels: 2, samples: [7, 7])],
            outputs: [(channels: 2, frames: 1)],
            gain: 1
        )
        XCTAssertEqual(rendered, [[1, 1]])
    }

    func testMonoSourceFeedsBothFrontChannelsAndMonoOutputFoldsStereo() throws {
        XCTAssertEqual(
            try render(source: [0.8], sourceChannels: 1, outputs: [(channels: 2, frames: 1)], gain: 1),
            [[0.8, 0.8]]
        )
        XCTAssertEqual(
            try render(source: [1, 0], sourceChannels: 2, outputs: [(channels: 1, frames: 1)], gain: 1),
            [[0.5]]
        )
    }

    func testSplitOutputBuffersCountChannelsAcrossBuffers() throws {
        let rendered = try render(
            source: [1, 2],
            sourceChannels: 2,
            outputs: [(channels: 1, frames: 1), (channels: 1, frames: 1), (channels: 1, frames: 1)],
            gain: 1
        )
        XCTAssertEqual(rendered, [[1], [2], [0]])
    }

    func testMissingTapAndMutedGainWriteSilenceAndShortTapsLeaveNoStaleFrames() throws {
        XCTAssertEqual(
            try render(source: [1, 1], sourceChannels: 2, outputs: [(channels: 2, frames: 2)], gain: 1),
            [[1, 1, 0, 0]]
        )
        XCTAssertEqual(
            try render(source: [1, 1], sourceChannels: 2, outputs: [(channels: 2, frames: 1)], gain: 0),
            [[0, 0]]
        )
        XCTAssertEqual(
            try render(source: [1], sourceChannels: 1, outputs: [(channels: 2, frames: 1)], gain: 1, tapChannels: 2),
            [[0, 0]]
        )
        XCTAssertEqual(
            try render(
                source: [1],
                sourceChannels: 1,
                inputs: [(channels: 2, samples: [3, 3])],
                outputs: [(channels: 2, frames: 1)],
                gain: 1
            ),
            [[1, 1]]
        )
        let state = try XCTUnwrap(omni_audio_gain_create(2, 1))
        omni_audio_gain_set(state, 0.25)
        omni_audio_gain_destroy(state)
        XCTAssertNil(omni_audio_gain_create(0, 1))
    }
}
