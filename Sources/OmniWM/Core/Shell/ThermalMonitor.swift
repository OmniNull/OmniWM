// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import IOKit
import Metal
import Synchronization

struct ShellThermal: Equatable, Sendable, ShellValueWritable {
    var cpu: Double?
    var gpu: Double?
    var gpuName: String?

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("cpu")
        cpu.map { writer.number($0) } ?? writer.null()
        writer.key("gpu")
        gpu.map { writer.number($0) } ?? writer.null()
        writer.key("gpuName")
        gpuName.map { writer.string($0) } ?? writer.null()
    }
}

final class ShellSMC: Sendable {
    enum Sensor: Equatable, Sendable {
        case cpu
        case gpu
    }

    private static let size = 80
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    static func sensor(_ key: String) -> Sensor? {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") {
            return .cpu
        }
        return key.hasPrefix("Tg") ? .gpu : nil
    }

    static func plausible(_ value: Double) -> Bool {
        (10 ... 110).contains(value)
    }

    func temperatureKeys() -> [(key: UInt32, sensor: Sensor)] {
        guard let count = read(Self.code("#KEY"), size: 4).map({ $0.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } })
        else {
            return []
        }
        return (0 ..< count).compactMap { index in
            var input = [UInt8](repeating: 0, count: Self.size)
            input[42] = 8
            withUnsafeBytes(of: index) { input.replaceSubrange(44 ..< 48, with: $0) }
            guard let output = call(input) else { return nil }
            let key = output.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard let sensor = Self.sensor(Self.name(key)), info(key)?.type == Self.code("flt ") else { return nil }
            return (key, sensor)
        }
    }

    func temperature(_ key: UInt32) -> Double? {
        guard let bytes = read(key, size: 4) else { return nil }
        let value = Double(bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        return Self.plausible(value) ? value : nil
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        var input = [UInt8](repeating: 0, count: Self.size)
        withUnsafeBytes(of: key) { input.replaceSubrange(0 ..< 4, with: $0) }
        input[42] = 9
        guard let output = call(input) else { return nil }
        let size = output[28 ..< 32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let type = output[32 ..< 36].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return (size, type)
    }

    private func read(_ key: UInt32, size: UInt32) -> ArraySlice<UInt8>? {
        guard let info = info(key) else { return nil }
        var input = [UInt8](repeating: 0, count: Self.size)
        withUnsafeBytes(of: key) { input.replaceSubrange(0 ..< 4, with: $0) }
        withUnsafeBytes(of: info.size) { input.replaceSubrange(28 ..< 32, with: $0) }
        input[42] = 5
        guard info.size >= size, let output = call(input) else { return nil }
        return output[48 ..< 48 + Int(min(info.size, 32))]
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.size)
        var outputSize = Self.size
        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    inputBytes.baseAddress,
                    Self.size,
                    outputBytes.baseAddress,
                    &outputSize
                )
            }
        }
        return result == KERN_SUCCESS && output[40] == 0 ? output : nil
    }

    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func name(_ code: UInt32) -> String {
        String(decoding: withUnsafeBytes(of: code.bigEndian) { Array($0) }, as: UTF8.self)
    }
}

@MainActor
final class ThermalMonitor: ShellDeviceSource {
    static let interval = DispatchTimeInterval.seconds(2)
    private nonisolated static let queue = DispatchQueue(label: "com.barut.OmniWM.shell.thermal", qos: .utility)
    private struct Sensors: Sendable {
        let smc: ShellSMC?
        let keys: [(key: UInt32, sensor: ShellSMC.Sensor)]
        let gpuName: String?
    }

    private nonisolated static let sensors = Mutex<Sensors?>(nil)

    private(set) var value: ShellThermal?
    var onChange: ((ShellThermal?) -> Void)?
    private var timer: DispatchSourceTimer?

    func setListening(_ listening: Bool) {
        guard listening != (timer != nil) else { return }
        timer?.cancel()
        timer = nil
        guard listening else {
            value = nil
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(500))
        timer.setEventHandler { @Sendable [weak self] in
            let reading = Self.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.received(reading)
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func received(_ reading: ShellThermal) {
        guard timer != nil, reading != value else { return }
        value = reading
        onChange?(reading)
    }

    private nonisolated static func sample() -> ShellThermal {
        let sensors = sensors.withLock { cached in
            if cached == nil {
                let smc = ShellSMC()
                cached = Sensors(
                    smc: smc,
                    keys: smc?.temperatureKeys() ?? [],
                    gpuName: MTLCreateSystemDefaultDevice()?.name
                )
            }
            return cached
        }
        let average = { (sensor: ShellSMC.Sensor) -> Double? in
            let values = sensors?.keys.filter { $0.sensor == sensor }.compactMap { sensors?.smc?.temperature($0.key) }
                ?? []
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return ShellThermal(cpu: average(.cpu), gpu: average(.gpu), gpuName: sensors?.gpuName)
    }
}
