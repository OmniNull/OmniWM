// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreBluetooth
import IOBluetooth
import IOKit

enum ShellBluetoothCommand: Equatable, Sendable {
    case authorize

    init?(words: [String]) {
        guard words == ["authorize"] else { return nil }
        self = .authorize
    }
}

struct ShellBluetoothDevice: Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var connected: Bool
    var battery: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
}

struct ShellBluetooth: Equatable, Sendable, ShellValueWritable {
    var power = false
    var access = "notDetermined"
    var devices: [ShellBluetoothDevice] = []

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("power")
        writer.bool(power)
        writer.key("access")
        writer.string(access)
        writer.key("devices")
        writer.array(devices.count)
        for device in devices {
            writer.map(8)
            writer.key("id")
            writer.string(device.id)
            writer.key("name")
            writer.string(device.name)
            writer.key("kind")
            writer.string(device.kind)
            writer.key("connected")
            writer.bool(device.connected)
            for (key, level) in [
                ("battery", device.battery),
                ("left", device.left),
                ("right", device.right),
                ("case", device.caseLevel)
            ] {
                writer.key(key)
                level.map { writer.number(Double($0)) } ?? writer.null()
            }
        }
    }

    static func access(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
    }

    static func kind(major: BluetoothDeviceClassMajor, minor: BluetoothDeviceClassMinor) -> String {
        switch Int(major) {
        case kBluetoothDeviceClassMajorAudio: "headphones"
        case kBluetoothDeviceClassMajorComputer: "computer"
        case kBluetoothDeviceClassMajorPhone: "phone"
        case kBluetoothDeviceClassMajorPeripheral:
            if Int(minor) & kBluetoothDeviceClassMinorPeripheral1Keyboard != 0 {
                "keyboard"
            } else if Int(minor) & kBluetoothDeviceClassMinorPeripheral1Pointing != 0 {
                "mouse"
            } else {
                "gamepad"
            }
        default: "other"
        }
    }

    static func address(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    static func level(_ value: Any?) -> Int? {
        (value as? NSNumber).flatMap { (1 ... 100).contains($0.intValue) ? $0.intValue : nil }
    }
}

@MainActor
final class BluetoothMonitor: NSObject, ShellDeviceSource, CBCentralManagerDelegate {
    static let batteryRefresh = DispatchTimeInterval.seconds(60)

    private(set) var value: ShellBluetooth?
    var onChange: ((ShellBluetooth?) -> Void)?
    private var listening = false
    private var central: CBCentralManager?
    private var connections: IOBluetoothUserNotification?
    private var disconnections: [String: IOBluetoothUserNotification] = [:]
    private var batteryTimer: DispatchSourceTimer?

    var isWatching: Bool {
        connections != nil
    }

    func setListening(_ listening: Bool) {
        guard listening != self.listening else { return }
        self.listening = listening
        guard listening else {
            stopWatching()
            value = nil
            return
        }
        watchIfAllowed()
        refresh()
    }

    func perform(_ command: ShellBluetoothCommand) {
        switch command {
        case .authorize:
            if CBCentralManager.authorization == .notDetermined {
                central = central ?? CBCentralManager(delegate: self, queue: .main)
            } else if let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            watchIfAllowed()
            refresh()
        }
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        refresh()
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        disconnections[device.addressString ?? ""] = nil
        refresh()
    }

    private func watchIfAllowed() {
        guard listening, CBCentralManager.authorization != .notDetermined else { return }
        central = central ?? CBCentralManager(delegate: self, queue: .main)
        guard !isWatching, CBCentralManager.authorization == .allowedAlways else { return }
        connections = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(connected(_:device:))
        )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.batteryRefresh, repeating: Self.batteryRefresh, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        batteryTimer = timer
    }

    private func stopWatching() {
        connections?.unregister()
        connections = nil
        disconnections.values.forEach { $0.unregister() }
        disconnections = [:]
        batteryTimer?.cancel()
        batteryTimer = nil
        central?.delegate = nil
        central = nil
    }

    private func refresh() {
        guard listening else { return }
        let access = ShellBluetooth.access(CBCentralManager.authorization)
        var next = ShellBluetooth(access: access)
        if isWatching {
            next.power = central?.state == .poweredOn
            next.devices = next.power ? devices() : []
        }
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    private func devices() -> [ShellBluetoothDevice] {
        let batteries = Self.hidBatteries()
        let paired = IOBluetoothDevice.pairedDevices()?.compactMap { $0 as? IOBluetoothDevice } ?? []
        return paired.compactMap { device -> ShellBluetoothDevice? in
            guard let address = device.addressString else { return nil }
            let connected = device.isConnected()
            if connected, disconnections[address] == nil {
                disconnections[address] = device.register(
                    forDisconnectNotification: self,
                    selector: #selector(disconnected(_:device:))
                )
            }
            var entry = ShellBluetoothDevice(
                id: address,
                name: device.nameOrAddress ?? address,
                kind: ShellBluetooth.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor),
                connected: connected
            )
            guard connected else { return entry }
            entry.left = Self.level(device, "batteryPercentLeft")
            entry.right = Self.level(device, "batteryPercentRight")
            entry.caseLevel = Self.level(device, "batteryPercentCase")
            entry.battery = batteries[ShellBluetooth.address(address)] ?? Self.level(device, "batteryPercentSingle")
                ?? [entry.left, entry.right].compactMap(\.self).min()
            return entry
        }.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    private static func level(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return ShellBluetooth.level(device.value(forKey: key))
    }

    private static func hidBatteries() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var batteries: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = { (key: String) in
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let address = property("DeviceAddress") as? String,
                  let level = ShellBluetooth.level(property("BatteryPercent"))
            else {
                continue
            }
            batteries[ShellBluetooth.address(address)] = level
        }
        return batteries
    }
}
