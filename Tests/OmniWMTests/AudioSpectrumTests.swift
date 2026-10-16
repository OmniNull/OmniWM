// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAudioTap
import Synchronization
import XCTest

@MainActor
final class AudioSpectrumTests: XCTestCase {
    private final class Signal: AudioSpectrumSource {
        let sampleRate = 48000.0
        let step: UInt64
        let sample: (UInt64) -> Float
        private var cursor: UInt64 = 0

        init(step: UInt64 = 1600, sample: @escaping (UInt64) -> Float) {
            self.step = step
            self.sample = sample
        }

        var position: UInt64 {
            cursor += step
            return cursor
        }

        func read(from start: UInt64, into samples: UnsafeMutableBufferPointer<Float>) -> Bool {
            for index in samples.indices {
                samples[index] = sample(start + UInt64(index))
            }
            return true
        }

        func stop() {}
    }

    private final class Counter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func add() {
            count.withLock { $0 += 1 }
        }
    }

    private final class Captures: Sendable {
        let bands = ShellSpectrumBands()
        let opened = Counter()
        let stopped = Counter()
        let requested = Counter()
        let access: AppVolumeAccess

        init(access: AppVolumeAccess = .granted) {
            self.access = access
        }

        var capture: AudioSpectrumCapture {
            AudioSpectrumCapture(
                bands: bands,
                status: { [access] in access },
                request: { [requested] _ in
                    requested.add()
                    return true
                },
                open: { [opened, stopped] _, _ in
                    opened.add()
                    return Stoppable(stopped: stopped)
                }
            )
        }
    }

    private final class Stoppable: AudioSpectrumSource {
        let sampleRate = 48000.0
        private let stopped: Counter
        private var cursor: UInt64 = 0

        init(stopped: Counter) {
            self.stopped = stopped
        }

        var position: UInt64 {
            cursor += 1600
            return cursor
        }

        func read(from start: UInt64, into samples: UnsafeMutableBufferPointer<Float>) -> Bool {
            for index in samples.indices {
                samples[index] = 0.5 * sin(2 * .pi * 440 * Float(start + UInt64(index)) / 48000)
            }
            return true
        }

        func stop() {
            stopped.add()
        }
    }

    private static func sine(_ frequency: Double, amplitude: Float = 0.5) -> (UInt64) -> Float {
        { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 48000)) }
    }

    func testTheRingMixesFramesToMonoAndRefusesOverwrittenSamples() {
        XCTAssertNil(omni_audio_ring_create(2, 6))
        XCTAssertNil(omni_audio_ring_create(0, 8))
        guard let ring = omni_audio_ring_create(2, 8) else { return XCTFail("The ring was not created") }
        defer { omni_audio_ring_destroy(ring) }
        var read = [Float](repeating: -1, count: 8)
        XCTAssertFalse(omni_audio_ring_read(ring, 0, &read, 1))

        let first: [Float] = [1, 3, 2, 4, 5, 7]
        omni_audio_ring_write(ring, first, 3)
        XCTAssertEqual(omni_audio_ring_position(ring), 3)
        XCTAssertTrue(omni_audio_ring_read(ring, 0, &read, 3))
        XCTAssertEqual(Array(read.prefix(3)), [2, 3, 6])
        XCTAssertFalse(omni_audio_ring_read(ring, 1, &read, 3))

        let second = (0 ..< 16).map { Float($0 / 2 + 10) }
        omni_audio_ring_write(ring, second, 8)
        XCTAssertEqual(omni_audio_ring_position(ring), 11)
        XCTAssertFalse(omni_audio_ring_read(ring, 2, &read, 1))
        XCTAssertTrue(omni_audio_ring_read(ring, 3, &read, 8))
        XCTAssertEqual(read, (10 ... 17).map(Float.init))
        XCTAssertFalse(omni_audio_ring_read(ring, 3, &read, 9))
    }

    func testASineLightsItsOwnBandAndSilenceStaysDark() throws {
        let analyzer = try XCTUnwrap(ShellSpectrumAnalyzer(sampleRate: 48000))
        let tone = Signal(sample: Self.sine(1000))
        for _ in 0 ..< 30 {
            analyzer.analyze(tone)
        }
        let bars = analyzer.bars
        XCTAssertEqual(bars.count, ShellSpectrumAnalyzer.bandCount)
        let band = try XCTUnwrap(analyzer.band(containing: 1000))
        XCTAssertEqual(bars[band], bars.max())
        XCTAssertGreaterThan(bars[band], 0.9)
        XCTAssertTrue(bars.indices.filter { abs($0 - band) > 1 }.allSatisfy { bars[$0] < bars[band] })
        XCTAssertLessThan(bars[0], 0.01)

        let quiet = try XCTUnwrap(ShellSpectrumAnalyzer(sampleRate: 48000))
        let silence = Signal { _ in 0 }
        for _ in 0 ..< 200 {
            quiet.analyze(silence)
        }
        quiet.estimateTempo()
        XCTAssertEqual(quiet.bars, [Float](repeating: 0, count: ShellSpectrumAnalyzer.bandCount))
        XCTAssertNil(quiet.bpm)
    }

    func testAClickTrainGivesItsTempo() throws {
        for bpm in [96.0, 120.0, 150.0] {
            let analyzer = try XCTUnwrap(ShellSpectrumAnalyzer(sampleRate: 48000))
            let period = UInt64(48000 * 60 / bpm)
            let clicks = Signal { index in
                index % period < 480 ? 0.8 * Float(sin(2 * .pi * 2000 * Double(index) / 48000)) : 0
            }
            for _ in 0 ..< 200 {
                analyzer.analyze(clicks)
            }
            analyzer.estimateTempo()
            XCTAssertEqual(try XCTUnwrap(analyzer.bpm), bpm, accuracy: 2, "\(bpm) BPM")
        }
        let steady = try XCTUnwrap(ShellSpectrumAnalyzer(sampleRate: 48000))
        let tone = Signal(sample: Self.sine(440))
        for _ in 0 ..< 200 {
            steady.analyze(tone)
        }
        steady.estimateTempo()
        XCTAssertNil(steady.bpm)
    }

    func testTheEngineTapsOnlyWhileListenedToAndWithAccess() async {
        let captures = Captures()
        let monitor = AudioSpectrumMonitor(capture: captures.capture)
        var changes: [ShellSpectrum?] = []
        monitor.onChange = { changes.append($0) }
        XCTAssertNil(monitor.value)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value, ShellSpectrum())
        await until { changes.contains { $0?.bars.isEmpty == false } }
        XCTAssertEqual(captures.opened.value, 1)
        XCTAssertEqual(monitor.value?.access, .granted)
        XCTAssertEqual(monitor.value?.bars.count, ShellSpectrumAnalyzer.bandCount)
        let bands = captures.bands.current
        XCTAssertTrue((0 ..< ShellSpectrumBands.Bars.count).contains { bands[$0] > 0 })
        monitor.setListening(false)
        XCTAssertNil(monitor.value)
        await until { captures.stopped.value == 1 }
        let cleared = captures.bands.current
        XCTAssertTrue((0 ..< ShellSpectrumBands.Bars.count).allSatisfy { cleared[$0] == 0 })

        let denied = Captures(access: .denied)
        let refused = AudioSpectrumMonitor(capture: denied.capture)
        refused.onChange = { _ in }
        refused.setListening(true)
        await until { refused.value?.access == .denied }
        XCTAssertEqual(denied.opened.value, 0)
        XCTAssertEqual(denied.requested.value, 0)
        refused.setListening(false)

        let unasked = Captures(access: .unknown)
        let asking = AudioSpectrumMonitor(capture: unasked.capture)
        asking.setListening(true)
        await until { unasked.requested.value == 1 }
        XCTAssertEqual(unasked.opened.value, 0)
        asking.setListening(false)
    }

    func testTheFeedStartsTheSpectrumOnlyForAReader() async {
        let captures = Captures()
        let devices = ShellDevices(spectrum: AudioSpectrumMonitor(capture: captures.capture))
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        feed.setDemand(ShellDataKey.clock.bit, cadence: .of([(ShellDataKey.clock.bit, nil)]))
        XCTAssertNil(feed.current.spectrum)
        feed.setDemand(ShellDataKey.spectrum.bit, cadence: .of([(ShellDataKey.spectrum.bit, nil)]))
        XCTAssertEqual(feed.current.spectrum, ShellSpectrum())
        await until { feed.current.spectrum?.bars.isEmpty == false }
        feed.setDemand(ShellDataKey.clock.bit, cadence: .of([(ShellDataKey.clock.bit, nil)]))
        XCTAssertNil(feed.current.spectrum)
        await until { captures.stopped.value == 1 }
        XCTAssertEqual(captures.opened.value, 1)
    }

    private final class Renders {
        var sequences: [Int] = []
    }

    func testTempoReadersRenderOnlyWhenTheTempoChanges() async {
        let bar = ShellBarKey(monitor: Monitor.ID(displayId: 92_410))
        let renders = Renders()
        let outbox = ShellWidgetOutbox { batch in
            if let tree = batch["tempo"]?.trees[ShellTreeKey(bar: bar, view: .bar)] {
                renders.sequences.append(tree.sequence)
            }
        }
        let package = ShellWidgetPackage(name: "tempo", generation: 1, outbox: outbox)
        let failure = await package.load(source: """
        local count = 0
        function render(ctx)
            count += 1
            return ui.text{ text = tostring(ctx.data.tempo) .. " " .. count }
        end
        """)
        XCTAssertNil(failure)
        var data = ShellWidgetData()
        data.spectrum = ShellSpectrum(access: .granted, bars: [0.1], bpm: 120)
        await package.receive(.update(data))
        await package.receive(.bars([bar: ShellBarData()]))
        for level: Float in [0.2, 0.3, 0.4] {
            data.spectrum?.bars = [level]
            await package.receive(.update(data))
        }
        data.spectrum?.bpm = 96
        await package.receive(.update(data))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(renders.sequences.last, 2)
        await package.close()

        let captures = Captures()
        let devices = ShellDevices(spectrum: AudioSpectrumMonitor(capture: captures.capture))
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        feed.setDemand(ShellDataKey.tempo.bit, cadence: .of([(ShellDataKey.tempo.bit, nil)]))
        await until { captures.opened.value == 1 }
        feed.setDemand(0, cadence: .of([]))
        await until { captures.stopped.value == 1 }
    }
}
