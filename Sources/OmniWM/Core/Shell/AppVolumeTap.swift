// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import OmniWMAudioTap

final class AppVolumeTap {
    let objects: [AudioObjectID]
    let output: String
    private let session: AudioTapSession

    init(objects: [AudioObjectID], output: String, gain level: Float) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.name = "OmniWM App Volume"
        session = try AudioTapSession(
            description,
            output: output,
            render: omni_audio_gain_render,
            client: { omni_audio_gain_create($0, level) },
            destroy: omni_audio_gain_destroy
        )
        self.objects = objects
        self.output = output
    }

    func setGain(_ level: Float) {
        omni_audio_gain_set(session.client, level)
    }

    func stop() {
        session.stop()
    }
}

final class AudioTapSession {
    enum Failure: Error {
        case output
        case tap(OSStatus)
        case format
        case aggregate(OSStatus)
        case render(OSStatus)
    }

    let client: OpaquePointer
    let sampleRate: Double
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID
    private let destroy: (OpaquePointer) -> Void

    init(
        _ description: CATapDescription,
        output: String,
        render: AudioDeviceIOProc,
        client make: (UInt32) -> OpaquePointer?,
        destroy: @escaping (OpaquePointer) -> Void
    ) throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else { throw Failure.tap(tapStatus) }
        guard let format = Self.format(of: tap), let client = make(format.mChannelsPerFrame) else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure.format
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            Self.aggregateConfiguration(name: description.name, output: output, tap: description.uuid) as CFDictionary,
            &aggregate
        )
        guard aggregateStatus == noErr else {
            destroy(client)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure.aggregate(aggregateStatus)
        }
        var proc: AudioDeviceIOProcID?
        var renderStatus = AudioDeviceCreateIOProcID(aggregate, render, UnsafeMutableRawPointer(client), &proc)
        if renderStatus == noErr, let proc {
            Self.readOnlyTheTap(of: aggregate, with: proc)
            renderStatus = AudioDeviceStart(aggregate, proc)
            if renderStatus != noErr {
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
        }
        guard renderStatus == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            destroy(client)
            AudioHardwareDestroyProcessTap(tap)
            throw Failure.render(renderStatus)
        }
        self.client = client
        sampleRate = format.mSampleRate
        self.tap = tap
        self.aggregate = aggregate
        self.proc = proc
        self.destroy = destroy
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mChannelsPerFrame == 1 || format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        else {
            return nil
        }
        return format
    }

    private static func aggregateConfiguration(name: String, output: String, tap: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: ShellAudio.privateDeviceUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
    }

    private static func readOnlyTheTap(of aggregate: AudioObjectID, with proc: AudioDeviceIOProcID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr,
              let streamsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn),
              Int(size) >= flagsOffset
        else {
            return
        }
        let usage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { usage.deallocate() }
        usage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        usage.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, usage) == noErr else { return }
        let streams = Int(usage.load(fromByteOffset: streamsOffset, as: UInt32.self))
        guard streams > 1, flagsOffset + streams * MemoryLayout<UInt32>.size <= Int(size) else { return }
        for stream in 0 ..< streams {
            usage.storeBytes(
                of: UInt32(stream == streams - 1 ? 1 : 0),
                toByteOffset: flagsOffset + stream * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )
        }
        let status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, size, usage)
        if status != noErr {
            Log.shell.error("An audio tap could not leave the output's inputs off: \(status)")
        }
    }

    func stop() {
        AudioDeviceStop(aggregate, proc)
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
        destroy(client)
    }
}
