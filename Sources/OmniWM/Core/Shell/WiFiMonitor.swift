// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreLocation
import CoreWLAN

enum ShellWiFiCommand: Equatable, Sendable {
    case authorize

    init?(words: [String]) {
        guard words == ["authorize"] else { return nil }
        self = .authorize
    }
}

struct ShellWiFi: Equatable, Sendable, ShellValueWritable {
    var power = false
    var connected = false
    var ssid: String?
    var rssi: Int?
    var band: String?
    var channel: Int?
    var security: String?
    var location = "notDetermined"

    func write(into writer: inout ShellValueWriter) {
        writer.map(8)
        writer.key("power")
        writer.bool(power)
        writer.key("connected")
        writer.bool(connected)
        writer.key("ssid")
        ssid.map { writer.string($0) } ?? writer.null()
        writer.key("rssi")
        rssi.map { writer.number(Double($0)) } ?? writer.null()
        writer.key("band")
        band.map { writer.string($0) } ?? writer.null()
        writer.key("channel")
        channel.map { writer.number(Double($0)) } ?? writer.null()
        writer.key("security")
        security.map { writer.string($0) } ?? writer.null()
        writer.key("location")
        writer.string(location)
    }

    static func band(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    static func security(_ security: CWSecurity) -> String? {
        switch security {
        case .none: "Open"
        case .WEP,
             .dynamicWEP: "WEP"
        case .wpaPersonal: "WPA Personal"
        case .wpaPersonalMixed: "WPA/WPA2 Personal"
        case .wpa2Personal: "WPA2 Personal"
        case .personal: "Personal"
        case .wpaEnterprise: "WPA Enterprise"
        case .wpaEnterpriseMixed: "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: "WPA2 Enterprise"
        case .enterprise: "Enterprise"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Enterprise: "WPA3 Enterprise"
        case .wpa3Transition: "WPA2/WPA3 Personal"
        case .OWE: "Enhanced Open"
        case .oweTransition: "Enhanced Open Transition"
        default: nil
        }
    }

    static func location(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways,
             .authorizedWhenInUse: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
    }
}

private final class WiFiEvents: NSObject, CWEventDelegate, Sendable {
    private let changed: @Sendable () -> Void

    init(_ changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        changed()
    }

    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        changed()
    }
}

@MainActor
final class WiFiMonitor: NSObject, ShellDeviceSource, CLLocationManagerDelegate {
    private static let reader = DispatchQueue(label: "com.barut.OmniWM.shell.wifi", qos: .utility)
    private static let events: [CWEventType] = [.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange]

    private(set) var value: ShellWiFi?
    var onChange: ((ShellWiFi?) -> Void)?
    private var client: CWWiFiClient?
    private var delegate: WiFiEvents?
    private var generation = 0
    private lazy var location = CLLocationManager()

    var isListening: Bool {
        client != nil
    }

    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        generation += 1
        guard listening else {
            do {
                try client?.stopMonitoringAllEvents()
            } catch {
                Log.shell.error("Wi-Fi monitoring did not stop: \(error.localizedDescription)")
            }
            client?.delegate = nil
            client = nil
            delegate = nil
            location.delegate = nil
            value = nil
            return
        }
        let client = CWWiFiClient()
        let delegate = WiFiEvents { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        client.delegate = delegate
        for event in Self.events {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                Log.shell.error("Wi-Fi event \(event.rawValue) is not monitored: \(error.localizedDescription)")
            }
        }
        self.client = client
        self.delegate = delegate
        location.delegate = self
        refresh()
    }

    func perform(_ command: ShellWiFiCommand) {
        switch command {
        case .authorize:
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            } else if let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            refresh()
        }
    }

    private func refresh() {
        guard isListening else { return }
        let generation = generation
        let location = ShellWiFi.location(location.authorizationStatus)
        Self.reader.async { [weak self] in
            let wifi = Self.read(location: location)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.publish(wifi, generation: generation)
                }
            }
        }
    }

    private func publish(_ wifi: ShellWiFi?, generation: Int) {
        guard generation == self.generation, isListening, wifi != value else { return }
        value = wifi
        onChange?(wifi)
    }

    private nonisolated static func read(location: String) -> ShellWiFi? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        var wifi = ShellWiFi(power: interface.powerOn(), location: location)
        let rssi = interface.rssiValue()
        guard wifi.power, rssi != 0 else { return wifi }
        let channel = interface.wlanChannel()
        wifi.connected = true
        wifi.ssid = interface.ssid()
        wifi.rssi = rssi
        wifi.band = channel.flatMap { ShellWiFi.band($0.channelBand) }
        wifi.channel = channel?.channelNumber
        wifi.security = ShellWiFi.security(interface.security())
        return wifi
    }
}
