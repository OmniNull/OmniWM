// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreAudio
import Foundation
import OmniWMAudioTap

struct AudioSpectrumCapture: Sendable {
    var bands = ShellSpectrumBands.live
    var status: @Sendable () -> AppVolumeAccess
    var request: @Sendable (_ answered: @escaping @Sendable () -> Void) -> Bool
    var open: @Sendable (_ queue: DispatchSerialQueue, _ changed: @escaping @Sendable () -> Void) throws
        -> any AudioSpectrumSource

    static let live = AudioSpectrumCapture(
        status: { AudioCapturePermission.status ?? .granted },
        request: { answered in AudioCapturePermission.request { _ in answered() } },
        open: { queue, changed in try AudioSpectrumTap(queue: queue, changed: changed) }
    )
}

@MainActor
final class AudioSpectrumMonitor: ShellDeviceSource {
    private(set) var value: ShellSpectrum?
    var onChange: ((ShellSpectrum?) -> Void)?
    private let capture: AudioSpectrumCapture
    private var listening = false
    private var version = 0

    private lazy var engine = AudioSpectrumEngine(capture: capture) { [weak self] version, spectrum in
        Task { @MainActor in
            self?.received(spectrum, version: version)
        }
    }

    init(capture: AudioSpectrumCapture = .live) {
        self.capture = capture
    }

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        version += 1
        value = listening ? ShellSpectrum() : nil
        let version = version
        Task { [engine] in
            await engine.update(version: version, listening: listening)
        }
    }

    private func received(_ spectrum: ShellSpectrum, version: Int) {
        guard listening, version == self.version, spectrum != value else { return }
        value = spectrum
        onChange?(spectrum)
    }
}

actor AudioSpectrumEngine {
    private static let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / 30)
    private static let reportEvery = 8
    private static let tempoEvery = 30

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.spectrum", qos: .utility)
    private let capture: AudioSpectrumCapture
    private let deliver: @Sendable (Int, ShellSpectrum) -> Void
    private var version = 0
    private var listening = false
    private var requestingAccess = false
    private var source: (any AudioSpectrumSource)?
    private var analyzer: ShellSpectrumAnalyzer?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var reported: ShellSpectrum?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(capture: AudioSpectrumCapture, deliver: @escaping @Sendable (Int, ShellSpectrum) -> Void) {
        self.capture = capture
        self.deliver = deliver
    }

    func update(version: Int, listening: Bool) {
        guard version > self.version else { return }
        self.version = version
        self.listening = listening
        reported = nil
        reconcile()
    }

    private func reconcile() {
        guard listening else { return close() }
        let access = checkAccess()
        guard access == .granted else {
            close()
            return report(ShellSpectrum(access: access))
        }
        guard source == nil else { return }
        do {
            let source = try capture.open(queue) { [weak self] in
                self?.assumeIsolated { $0.outputChanged() }
            }
            guard let analyzer = ShellSpectrumAnalyzer(sampleRate: source.sampleRate) else {
                source.stop()
                return report(ShellSpectrum(access: .granted))
            }
            self.source = source
            self.analyzer = analyzer
            startTimer()
        } catch {
            Log.shell.error("The audio spectrum could not tap system audio: \(error)")
            report(ShellSpectrum(access: .granted))
        }
    }

    private func checkAccess() -> AppVolumeAccess {
        let status = capture.status()
        if status == .unknown, !requestingAccess {
            requestingAccess = capture.request { [weak self] in
                Task {
                    await self?.accessAnswered()
                }
            }
        }
        return status
    }

    private func accessAnswered() {
        requestingAccess = false
        reconcile()
    }

    private func outputChanged() {
        close()
        reconcile()
    }

    private func close() {
        timer?.cancel()
        timer = nil
        if source != nil {
            capture.bands.store(.init(repeating: 0))
        }
        source?.stop()
        source = nil
        analyzer = nil
        ticks = 0
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let source, let analyzer else { return }
        analyzer.analyze(source)
        var bars = ShellSpectrumBands.Bars(repeating: 0)
        analyzer.fill(&bars)
        capture.bands.store(bars)
        ticks += 1
        if ticks % Self.tempoEvery == 0 {
            analyzer.estimateTempo()
        }
        if ticks % Self.reportEvery == 0 {
            report(ShellSpectrum(
                access: .granted,
                bars: (0 ..< ShellSpectrumBands.Bars.count).map { (bars[$0] * 100).rounded() / 100 },
                bpm: analyzer.bpm?.rounded()
            ))
        }
    }

    private func report(_ spectrum: ShellSpectrum) {
        guard spectrum != reported else { return }
        reported = spectrum
        deliver(version, spectrum)
    }
}

final class AudioSpectrumTap: AudioSpectrumSource {
    private static let capacity: UInt32 = 1 << 15

    private let session: AudioTapSession
    private let queue: DispatchSerialQueue
    private let listener: AudioObjectPropertyListenerBlock

    var sampleRate: Double {
        session.sampleRate
    }

    var position: UInt64 {
        omni_audio_ring_position(session.client)
    }

    init(queue: DispatchSerialQueue, changed: @escaping @Sendable () -> Void) throws {
        guard let output = ShellAudio.defaultOutput().flatMap(ShellAudio.uid(of:)) else {
            throw AudioTapSession.Failure.output
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.name = "OmniWM Spectrum"
        session = try AudioTapSession(
            description,
            output: output,
            render: omni_audio_ring_capture,
            client: { omni_audio_ring_create($0, Self.capacity) },
            destroy: omni_audio_ring_destroy
        )
        self.queue = queue
        listener = { _, _ in changed() }
        var address = ShellAudio.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    func read(from start: UInt64, into samples: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard let base = samples.baseAddress else { return false }
        return omni_audio_ring_read(session.client, start, base, UInt32(samples.count))
    }

    func stop() {
        var address = ShellAudio.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        session.stop()
    }
}
