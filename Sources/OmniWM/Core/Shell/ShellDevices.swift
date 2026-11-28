// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

protocol ShellValueWritable {
    func write(into writer: inout ShellValueWriter)
}

@MainActor
protocol ShellDeviceSource: AnyObject {
    associatedtype Value: Equatable
    var value: Value? { get }
    var onChange: ((Value?) -> Void)? { get set }
    func setListening(_ listening: Bool)
}

@MainActor
final class ShellDevices {
    let inputSource: InputSourceController
    let privacy = PrivacyMonitor()
    let wifi: WiFiMonitor
    let wifiNetworks: WiFiNetworksMonitor
    let connection = ConnectionMonitor()
    let bluetooth = BluetoothMonitor()
    let user = UserMonitor()
    let thermal = ThermalMonitor()
    let appearance = AppearanceMonitor()
    let brightness: ShellDisplayBrightness
    let betterDisplay: ShellBetterDisplayMonitor
    let nightShift: ShellNightShiftMonitor
    let spectrum: AudioSpectrumMonitor

    init(
        inputSource: InputSourceController = InputSourceController(),
        wifi: WiFiMonitor = WiFiMonitor(),
        wifiNetworks: WiFiNetworksMonitor = WiFiNetworksMonitor(),
        brightness: ShellDisplayBrightness = ShellDisplayBrightness(),
        betterDisplay: ShellBetterDisplayMonitor = ShellBetterDisplayMonitor(),
        nightShift: ShellNightShiftMonitor = ShellNightShiftMonitor(),
        spectrum: AudioSpectrumMonitor = AudioSpectrumMonitor()
    ) {
        self.inputSource = inputSource
        self.wifi = wifi
        self.wifiNetworks = wifiNetworks
        self.brightness = brightness
        self.betterDisplay = betterDisplay
        self.nightShift = nightShift
        self.spectrum = spectrum
        betterDisplay.onBrightnessSupportLoss = brightness.refresh
        betterDisplay.onNightShiftSupportLoss = nightShift.refresh
    }

    func perform(_ command: ShellWiFiCommand) {
        switch command {
        case .authorize: wifi.authorize()
        case .scan: wifiNetworks.scan()
        case let .join(id): wifiNetworks.join(id)
        }
    }
}

extension ShellDataFeed {
    func listenToDevices(_ devices: ShellDevices) {
        listen(devices.inputSource, !paused && demands(.inputSource), into: \.inputSource)
        listen(devices.privacy, !paused && demands(.privacy), into: \.privacy)
        listen(devices.wifi, !paused && demands(.wifi), into: \.wifi)
        listen(devices.wifiNetworks, !paused && demands(.wifiNetworks), into: \.wifiNetworks)
        listen(devices.connection, !paused && demands(.connection), into: \.connection)
        listen(devices.bluetooth, !paused && demands(.bluetooth), into: \.bluetooth)
        listen(devices.user, !paused && demands(.user), into: \.user)
        listen(devices.thermal, !paused && demands(.thermal), into: \.thermal)
        listen(devices.appearance, !paused && demands(.appearance), into: \.appearance)
        listenToDisplays(devices)
        listen(devices.spectrum, !paused && (demands(.spectrum) || demands(.tempo)), into: \.spectrum)
    }

    private func listenToDisplays(_ devices: ShellDevices) {
        let brightness = !paused && demands(.brightness)
        let nightShift = !paused && demands(.nightShift)
        // Starting BetterDisplay can refresh both natives synchronously. Bind their values together afterward.
        devices.brightness.onChange = nil
        devices.nightShift.onChange = nil
        devices.brightness.setListening(brightness)
        devices.nightShift.setListening(nightShift)
        listen(devices.betterDisplay, !paused && demands(.betterDisplay), into: \.betterDisplay)
        bind(devices.brightness, brightness, into: \.brightness)
        bind(devices.nightShift, nightShift, into: \.nightShift)
    }

    func stopDevices(_ devices: ShellDevices) {
        listen(devices.inputSource, false, into: \.inputSource)
        listen(devices.privacy, false, into: \.privacy)
        listen(devices.wifi, false, into: \.wifi)
        listen(devices.wifiNetworks, false, into: \.wifiNetworks)
        listen(devices.connection, false, into: \.connection)
        listen(devices.bluetooth, false, into: \.bluetooth)
        listen(devices.user, false, into: \.user)
        listen(devices.thermal, false, into: \.thermal)
        listen(devices.appearance, false, into: \.appearance)
        listen(devices.brightness, false, into: \.brightness)
        listen(devices.betterDisplay, false, into: \.betterDisplay)
        listen(devices.nightShift, false, into: \.nightShift)
        listen(devices.spectrum, false, into: \.spectrum)
    }

    private func listen<Source: ShellDeviceSource>(
        _ source: Source,
        _ listening: Bool,
        into path: WritableKeyPath<ShellWidgetData, Source.Value?>
    ) {
        source.setListening(listening)
        bind(source, listening, into: path)
    }

    private func bind<Source: ShellDeviceSource>(
        _ source: Source,
        _ listening: Bool,
        into path: WritableKeyPath<ShellWidgetData, Source.Value?>
    ) {
        guard listening else {
            source.onChange = nil
            data[keyPath: path] = nil
            return
        }
        source.onChange = { [weak self] value in
            guard let self, data[keyPath: path] != value else { return }
            data[keyPath: path] = value
            publish()
        }
        data[keyPath: path] = source.value
    }
}
