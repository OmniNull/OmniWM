// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Accelerate
import Foundation
import Synchronization

struct ShellSpectrum: Equatable, Sendable, ShellValueWritable {
    var access = AppVolumeAccess.unknown
    var bars: [Float] = []
    var bpm: Double?

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("access")
        writer.string(access.rawValue)
        writer.key("bars")
        writer.array(bars.count)
        for bar in bars {
            writer.number(Double(bar))
        }
        writer.key("bpm")
        bpm.map { writer.number($0) } ?? writer.null()
    }
}

final class ShellSpectrumBands: Sendable {
    typealias Bars = InlineArray<60, Float>

    static let live = ShellSpectrumBands()

    private let bars = Mutex(Bars(repeating: 0))

    var current: Bars {
        bars.withLock { $0 }
    }

    func store(_ next: Bars) {
        bars.withLock { $0 = next }
    }
}

protocol AudioSpectrumSource: AnyObject {
    var sampleRate: Double { get }
    var position: UInt64 { get }
    func read(from start: UInt64, into samples: UnsafeMutableBufferPointer<Float>) -> Bool
    func stop()
}

final class ShellSpectrumAnalyzer {
    static let bandCount = ShellSpectrumBands.Bars.count
    static let window = 2048
    static let hop = 512
    static let onsetWindow = 1024
    private static let lowest = 50.0
    private static let highest = 10000.0
    private static let fall: Float = 0.82
    private static let spread: Float = 1 / 1.5
    private static let silence: Float = 1e-4
    private static let onsetFloor: Float = 0.05
    private static let onsetKernel: [Float] = [1, 2, 3, 2, 1].map { $0 / 9 }
    private static let tempoSeconds = 6.0
    private static let tempoRange = 60.0 ... 200.0

    let sampleRate: Double
    let onsetRate: Double
    private let setup: FFTSetup
    private let windowShape: [Float]
    private let onsetShape: [Float]
    private let edges: [Int]
    private let weights: [Float]
    private var frame: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private var previousOnset: [Float]
    private var onsets: [Float] = []
    private var levels = [Float](repeating: 0, count: bandCount)
    private var sensitivity: Float = 10
    private var settling = true
    private var hopCursor: UInt64?
    private(set) var bpm: Double?

    init?(sampleRate: Double) {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(Self.window))),
            FFTRadix(kFFTRadix2)
        )
        else {
            return nil
        }
        self.sampleRate = sampleRate
        onsetRate = sampleRate / Double(Self.hop)
        self.setup = setup
        windowShape = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.window,
            isHalfWindow: false
        )
        onsetShape = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.onsetWindow,
            isHalfWindow: false
        )
        let resolution = sampleRate / Double(Self.window)
        var edges: [Int] = []
        for band in 0 ... Self.bandCount {
            let frequency = Self.lowest * pow(Self.highest / Self.lowest, Double(band) / Double(Self.bandCount))
            let bin = max(Int((frequency / resolution).rounded()), 1)
            edges.append(max(bin, (edges.last ?? 0) + 1))
        }
        self.edges = edges
        weights = (0 ..< Self.bandCount).map { band in
            Float(((Double(edges[band] + edges[band + 1]) / 2 * resolution) / 1000).squareRoot())
        }
        frame = [Float](repeating: 0, count: Self.window)
        windowed = [Float](repeating: 0, count: Self.window)
        real = [Float](repeating: 0, count: Self.window / 2)
        imaginary = [Float](repeating: 0, count: Self.window / 2)
        power = [Float](repeating: 0, count: Self.window / 2)
        previousOnset = [Float](repeating: 0, count: Self.onsetWindow / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func band(containing frequency: Double) -> Int? {
        let bin = Int((frequency / (sampleRate / Double(Self.window))).rounded())
        return (0 ..< Self.bandCount).first { edges[$0] <= bin && bin < edges[$0 + 1] }
    }

    var bars: [Float] {
        var bars = ShellSpectrumBands.Bars(repeating: 0)
        fill(&bars)
        return (0 ..< Self.bandCount).map { bars[$0] }
    }

    func fill(_ bars: inout ShellSpectrumBands.Bars) {
        var carry: Float = 0
        for index in 0 ..< Self.bandCount {
            carry = max(levels[index], carry * Self.spread)
            bars[index] = carry
        }
        carry = 0
        for index in (0 ..< Self.bandCount).reversed() {
            carry = max(levels[index], carry * Self.spread)
            bars[index] = max(bars[index], carry)
        }
    }

    func analyze(_ source: any AudioSpectrumSource) {
        let position = source.position
        trackOnsets(source, upTo: position)
        guard position >= UInt64(Self.window),
              frame.withUnsafeMutableBufferPointer({ source.read(from: position - UInt64(Self.window), into: $0) })
        else {
            return
        }
        transform(count: Self.window, shape: windowShape)
        let scale = 2 / Float(Self.window)
        var loudest: Float = 0
        var overshoot = false
        for band in 0 ..< Self.bandCount {
            var peak: Float = 0
            for bin in edges[band] ..< min(edges[band + 1], power.count) {
                peak = max(peak, power[bin])
            }
            let amplitude = peak.squareRoot() * scale * weights[band]
            loudest = max(loudest, amplitude)
            levels[band] = max(amplitude * sensitivity, levels[band] * Self.fall)
            if levels[band] > 1 {
                levels[band] = 1
                overshoot = true
            }
        }
        if overshoot {
            sensitivity *= 0.98
            settling = false
        } else if loudest > Self.silence {
            sensitivity *= settling ? 1.1 : 1.002
        }
    }

    func estimateTempo() {
        let needed = Int(onsetRate * Self.tempoSeconds * 2 / 3)
        let mean = onsets.isEmpty ? 0 : vDSP.mean(onsets)
        guard onsets.count >= needed, mean > Self.onsetFloor else {
            bpm = nil
            return
        }
        let centered = vDSP.add(-mean, vDSP.convolve(onsets, withKernel: Self.onsetKernel))
        let energy = vDSP.dot(centered, centered)
        guard energy > 1e-6 else {
            bpm = nil
            return
        }
        let lags = Int(onsetRate * 60 / Self.tempoRange.upperBound) ... Int(onsetRate * 60 / Self.tempoRange.lowerBound)
        let correlations = (lags.lowerBound - 1 ... lags.upperBound + 1).map { lag in
            vDSP.dot(centered[lag...], centered[..<(centered.count - lag)]) / energy
        }
        var best: (lag: Int, score: Float)?
        for lag in lags {
            let correlation = correlations[lag - lags.lowerBound + 1]
            let octaves = log2(onsetRate * 60 / Double(lag) / 120)
            let score = correlation * Float(exp(-octaves * octaves / 2))
            if correlation > 0.1, score > best?.score ?? 0 {
                best = (lag, score)
            }
        }
        guard let best else {
            bpm = nil
            return
        }
        let index = best.lag - lags.lowerBound + 1
        let before = correlations[index - 1], peak = correlations[index], after = correlations[index + 1]
        let curvature = before - 2 * peak + after
        let offset = curvature < 0 ? Double(0.5 * (before - after) / curvature) : 0
        let estimate = onsetRate * 60 / (Double(best.lag) + offset)
        bpm = bpm.map { $0 * 0.7 + estimate * 0.3 } ?? estimate
    }

    private func trackOnsets(_ source: any AudioSpectrumSource, upTo position: UInt64) {
        let hop = UInt64(Self.hop)
        let span = UInt64(Self.onsetWindow)
        let capacity = Int(onsetRate * Self.tempoSeconds)
        var cursor = hopCursor ?? position
        if position > cursor + UInt64(sampleRate) {
            cursor = position
        }
        while cursor + hop <= position {
            cursor += hop
            guard cursor >= span,
                  frame.withUnsafeMutableBufferPointer({ buffer in
                      source.read(from: cursor - span, into: UnsafeMutableBufferPointer(rebasing: buffer[..<Int(span)]))
                  })
            else {
                continue
            }
            transform(count: Self.onsetWindow, shape: onsetShape)
            var flux: Float = 0
            let scale = 200 / Float(Self.onsetWindow)
            for bin in 1 ..< Self.onsetWindow / 2 {
                let magnitude = log1p(power[bin].squareRoot() * scale)
                flux += max(magnitude - previousOnset[bin], 0)
                previousOnset[bin] = magnitude
            }
            onsets.append(flux)
            if onsets.count > capacity {
                onsets.removeFirst(onsets.count - capacity)
            }
        }
        hopCursor = cursor
    }

    private func transform(count: Int, shape: [Float]) {
        let half = count / 2
        vDSP_vmul(frame, 1, shape, 1, &windowed, 1, vDSP_Length(count))
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                windowed.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(count))), FFTDirection(FFT_FORWARD))
                imaginary[0] = 0
                power.withUnsafeMutableBufferPointer { power in
                    vDSP_zvmags(&split, 1, power.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
    }
}
