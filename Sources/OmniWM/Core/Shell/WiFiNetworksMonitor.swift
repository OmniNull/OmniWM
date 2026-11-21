// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreWLAN
import OmniWMWiFiSPI

struct ShellWiFiNetwork: Equatable, Sendable {
    static let limit = 12

    var id: String
    var ssid: String
    var rssi: Int
    var security: String?
    var secured = false
    var enterprise = false
    var known = false

    init(
        id: String,
        ssid: String,
        rssi: Int,
        security: String? = nil,
        secured: Bool = false,
        enterprise: Bool = false,
        known: Bool = false
    ) {
        self.id = id
        self.ssid = ssid
        self.rssi = rssi
        self.security = security
        self.secured = secured
        self.enterprise = enterprise
        self.known = known
    }

    init?(_ network: CWNetwork) {
        guard let data = network.ssidData, !data.isEmpty, let ssid = network.ssid, !ssid.isEmpty else { return nil }
        self.init(id: Self.id(data), ssid: ssid, rssi: network.rssiValue)
        if let match = Self.enterpriseSecurities.first(where: network.supportsSecurity) {
            security = ShellWiFi.security(match)
            secured = true
            enterprise = true
        } else if let match = Self.personalSecurities.first(where: network.supportsSecurity) {
            security = ShellWiFi.security(match)
            secured = true
        } else if let match = Self.openSecurities.first(where: network.supportsSecurity) {
            security = ShellWiFi.security(match)
        }
    }

    private static let enterpriseSecurities: [CWSecurity] = [
        .wpa3Enterprise, .wpa2Enterprise, .wpaEnterpriseMixed, .wpaEnterprise, .enterprise, .dynamicWEP
    ]
    private static let personalSecurities: [CWSecurity] = [
        .wpa3Personal, .wpa3Transition, .wpa2Personal, .wpaPersonalMixed, .wpaPersonal, .personal, .WEP
    ]
    private static let openSecurities: [CWSecurity] = [.OWE, .oweTransition, .none]

    static func id(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func ssidData(id: String) -> Data? {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.count <= 64 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexValue(bytes[index]), let low = hexValue(bytes[index + 1]) else { return nil }
            data.append(high << 4 | low)
        }
        return data
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    var opensSettings: Bool {
        enterprise || secured && !known
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(8)
        writer.key("id")
        writer.string(id)
        writer.key("ssid")
        writer.string(ssid)
        writer.key("rssi")
        writer.number(Double(rssi))
        writer.key("security")
        security.map { writer.string($0) } ?? writer.null()
        writer.key("secured")
        writer.bool(secured)
        writer.key("enterprise")
        writer.bool(enterprise)
        writer.key("known")
        writer.bool(known)
        writer.key("opensSettings")
        writer.bool(opensSettings)
    }
}

struct ShellWiFiFailure: Equatable, Sendable {
    var id: String
    var message: String

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("id")
        writer.string(id)
        writer.key("message")
        writer.string(message)
    }
}

enum ShellWiFiJoinOutcome: Equatable, Sendable {
    case joined
    case failed(String)
    case needsSettings
}

struct ShellWiFiNetworks: Equatable, Sendable, ShellValueWritable {
    var known: [ShellWiFiNetwork] = []
    var other: [ShellWiFiNetwork] = []
    var scanning = false
    var joining: String?
    var failure: ShellWiFiFailure?

    static func grouped(
        _ candidates: [ShellWiFiNetwork],
        priority: [String],
        current: String?
    ) -> (known: [ShellWiFiNetwork], other: [ShellWiFiNetwork]) {
        var rank: [String: Int] = [:]
        for (index, id) in priority.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        var strongest: [String: ShellWiFiNetwork] = [:]
        for candidate in candidates where candidate.id != current {
            if let existing = strongest[candidate.id],
               existing.secured != candidate.secured ? existing.secured : existing.rssi >= candidate.rssi
            { continue }
            strongest[candidate.id] = candidate
        }
        var known: [(rank: Int, network: ShellWiFiNetwork)] = []
        var other: [ShellWiFiNetwork] = []
        for var network in strongest.values {
            if let index = rank[network.id] {
                network.known = true
                known.append((index, network))
            } else {
                network.known = false
                other.append(network)
            }
        }
        other.sort { ($0.rssi, $1.ssid) > ($1.rssi, $0.ssid) }
        return (
            Array(known.sorted { $0.rank < $1.rank }.map(\.network).prefix(ShellWiFiNetwork.limit)),
            Array(other.prefix(ShellWiFiNetwork.limit))
        )
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(5)
        for (key, networks) in [("known", known), ("other", other)] {
            writer.key(key)
            writer.array(networks.count)
            networks.forEach { $0.write(into: &writer) }
        }
        writer.key("scanning")
        writer.bool(scanning)
        writer.key("joining")
        joining.map { writer.string($0) } ?? writer.null()
        writer.key("failure")
        failure.map { $0.write(into: &writer) } ?? writer.null()
    }
}

private final class WiFiNetworkEvents: NSObject, CWEventDelegate, Sendable {
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

    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        changed()
    }
}

@MainActor
final class WiFiNetworksMonitor: NSObject, ShellDeviceSource {
    static let rescan = DispatchTimeInterval.seconds(10)
    private static let reader = DispatchQueue(label: "com.barut.OmniWM.shell.wifi.networks", qos: .utility)
    static let radio = DispatchQueue(label: "com.barut.OmniWM.shell.wifi.radio", qos: .userInitiated)
    private static let events: [CWEventType] = [.powerDidChange, .ssidDidChange, .scanCacheUpdated]

    typealias Lists = (known: [ShellWiFiNetwork], other: [ShellWiFiNetwork])

    private(set) var value: ShellWiFiNetworks?
    var onChange: ((ShellWiFiNetworks?) -> Void)?
    private var client: CWWiFiClient?
    private var delegate: WiFiNetworkEvents?
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var lists: Lists = ([], [])
    private var scanning = false
    private var joining: String?
    private var failure: ShellWiFiFailure?
    private let read: @Sendable () -> Lists
    private let scanner: @Sendable () -> Void
    private let joiner: @Sendable (ShellWiFiNetwork) -> ShellWiFiJoinOutcome
    private let joinInSettings: @MainActor (ShellWiFiNetwork) async -> String?
    private var settingsJoinTask: Task<Void, Never>?

    init(
        read: @escaping @Sendable () -> Lists = WiFiNetworksMonitor.readLists,
        scan: @escaping @Sendable () -> Void = WiFiNetworksMonitor.scanRadio,
        join: @escaping @Sendable (ShellWiFiNetwork) -> ShellWiFiJoinOutcome = WiFiNetworksMonitor.associate,
        joinInSettings: @escaping @MainActor (ShellWiFiNetwork) async -> String? = WiFiSettingsJoiner.join
    ) {
        self.read = read
        scanner = scan
        joiner = join
        self.joinInSettings = joinInSettings
    }

    deinit {
        settingsJoinTask?.cancel()
    }

    var isListening: Bool {
        timer != nil
    }

    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        generation += 1
        guard listening else {
            timer?.cancel()
            timer = nil
            do {
                try client?.stopMonitoringAllEvents()
            } catch {
                Log.shell.error("Wi-Fi network monitoring did not stop: \(error.localizedDescription)")
            }
            client?.delegate = nil
            client = nil
            delegate = nil
            scanning = false
            if joining == nil {
                lists = ([], [])
                failure = nil
            }
            value = nil
            return
        }
        let client = CWWiFiClient()
        let delegate = WiFiNetworkEvents { [weak self] in
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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.rescan, repeating: Self.rescan, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.scan()
        }
        timer.resume()
        self.timer = timer
        compose()
        refresh()
        scan()
    }

    func scan() {
        guard isListening, !scanning, joining == nil else { return }
        scanning = true
        compose()
        let generation = generation
        let scanner = scanner
        Self.radio.async { [weak self] in
            scanner()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishScan(generation: generation)
                }
            }
        }
    }

    private func finishScan(generation: Int) {
        guard generation == self.generation else { return }
        scanning = false
        refresh()
    }

    func join(_ id: String) {
        guard isListening, joining == nil else { return }
        guard let target = (lists.known + lists.other).first(where: { $0.id == id }) else {
            failure = ShellWiFiFailure(id: id, message: Self.outOfRange)
            compose()
            return
        }
        joining = id
        failure = nil
        compose()
        if target.opensSettings {
            handOff(target)
            return
        }
        let joiner = joiner
        Self.radio.async { [weak self] in
            let outcome = joiner(target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishJoin(target, outcome: outcome)
                }
            }
        }
    }

    private func finishJoin(_ target: ShellWiFiNetwork, outcome: ShellWiFiJoinOutcome) {
        switch outcome {
        case .joined: finish(target.id, failure: nil)
        case let .failed(message): finish(target.id, failure: message)
        case .needsSettings: handOff(target)
        }
    }

    private func handOff(_ target: ShellWiFiNetwork) {
        settingsJoinTask = Task { [weak self, joinInSettings] in
            let message = await joinInSettings(target)
            self?.settingsJoinTask = nil
            self?.finish(target.id, failure: message)
        }
    }

    private func finish(_ id: String, failure message: String?) {
        joining = nil
        failure = message.map { ShellWiFiFailure(id: id, message: $0) }
        compose()
        refresh()
    }

    private func refresh() {
        guard isListening, joining == nil else { return }
        let generation = generation
        let read = read
        Self.reader.async { [weak self] in
            let lists = read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.publish(lists, generation: generation)
                }
            }
        }
    }

    private func publish(_ lists: Lists, generation: Int) {
        guard generation == self.generation, joining == nil else { return }
        self.lists = lists
        compose()
    }

    private func compose() {
        guard isListening else { return }
        let next = ShellWiFiNetworks(
            known: lists.known, other: lists.other, scanning: scanning, joining: joining, failure: failure
        )
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    private nonisolated static func readLists() -> Lists {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let scan = interface.cachedScanResults()
        else {
            return ([], [])
        }
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        let saved = Dictionary(grouping: profiles) { $0.ssidData.map(ShellWiFiNetwork.id) }
        let candidates = scan.filter { network in
            guard let profiles = saved[network.ssidData.map(ShellWiFiNetwork.id)] else { return true }
            return profiles.contains { network.supportsSecurity($0.security) }
        }
        return ShellWiFiNetworks.grouped(
            candidates.compactMap(ShellWiFiNetwork.init),
            priority: profiles.compactMap { $0.ssidData.map(ShellWiFiNetwork.id) },
            current: interface.ssidData().map(ShellWiFiNetwork.id)
        )
    }

    private nonisolated static func scanRadio() {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return }
        do {
            _ = try interface.scanForNetworks(withSSID: nil)
        } catch {
            Log.shell.error("Wi-Fi scan failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static var outOfRange: String {
        String(localized: "Network is no longer in range")
    }

    private nonisolated static func associate(_ network: ShellWiFiNetwork) -> ShellWiFiJoinOutcome {
        guard let ssid = ShellWiFiNetwork.ssidData(id: network.id) else { return .failed(outOfRange) }
        if network.secured {
            var error: NSError?
            if omniwm_wifi_join_known_network(ssid, &error) { return .joined }
            let notInRange = error?.domain == OmniWMWiFiErrorDomain
                && error?.code == OmniWMWiFiError.notInRange.rawValue
            return notInRange ? .failed(outOfRange) : .needsSettings
        }
        guard let interface = CWWiFiClient.shared().interface() else { return .needsSettings }
        let candidates = interface.cachedScanResults()?
            .filter { $0.ssidData == ssid && ShellWiFiNetwork($0)?.secured == false } ?? []
        guard let target = candidates.max(by: { $0.rssiValue < $1.rssiValue }) else { return .failed(outOfRange) }
        do {
            try interface.associate(to: target, password: nil)
            return .joined
        } catch {
            return .needsSettings
        }
    }
}
