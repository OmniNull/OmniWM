// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
    let inputSource = InputSourceController()
    let privacy = PrivacyMonitor()
    let wifi = WiFiMonitor()
    let bluetooth = BluetoothMonitor()
    let user = UserMonitor()
    let thermal = ThermalMonitor()
    let appearance = AppearanceMonitor()
    let spectrum: AudioSpectrumMonitor

    init(spectrum: AudioSpectrumMonitor = AudioSpectrumMonitor()) {
        self.spectrum = spectrum
    }
}

extension ShellDataFeed {
    func listenToDevices(_ devices: ShellDevices) {
        listen(devices.inputSource, !paused && demands(.inputSource), into: \.inputSource)
        listen(devices.privacy, !paused && demands(.privacy), into: \.privacy)
        listen(devices.wifi, !paused && demands(.wifi), into: \.wifi)
        listen(devices.bluetooth, !paused && demands(.bluetooth), into: \.bluetooth)
        listen(devices.user, !paused && demands(.user), into: \.user)
        listen(devices.thermal, !paused && demands(.thermal), into: \.thermal)
        listen(devices.appearance, !paused && demands(.appearance), into: \.appearance)
        listen(devices.spectrum, !paused && (demands(.spectrum) || demands(.tempo)), into: \.spectrum)
    }

    func stopDevices(_ devices: ShellDevices) {
        listen(devices.inputSource, false, into: \.inputSource)
        listen(devices.privacy, false, into: \.privacy)
        listen(devices.wifi, false, into: \.wifi)
        listen(devices.bluetooth, false, into: \.bluetooth)
        listen(devices.user, false, into: \.user)
        listen(devices.thermal, false, into: \.thermal)
        listen(devices.appearance, false, into: \.appearance)
        listen(devices.spectrum, false, into: \.spectrum)
    }

    private func listen<Source: ShellDeviceSource>(
        _ source: Source,
        _ listening: Bool,
        into path: WritableKeyPath<ShellWidgetData, Source.Value?>
    ) {
        source.setListening(listening)
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
