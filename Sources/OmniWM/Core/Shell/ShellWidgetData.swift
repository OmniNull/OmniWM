// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

enum ShellDataKey: String, CaseIterable, Sendable {
    case clock
    case date
    case seconds
    case cpu
    case memory
    case battery
    case charging
    case gpu
    case disk
    case network
    case volume
    case muted
    case vars
    case weather
    case workspace
    case app
    case bundle
    case title
    case workspaces
    case bar
    case settings
    case hiddenBar
    case system
    case outputs
    case audioApps
    case media
    case calendar
    case power
    case inputSource
    case privacy
    case wifi
    case bluetooth
    case user
    case thermal
    case networkHistory
    case appearance
    case lyrics
    case spectrum
    case tempo
    case island
    case components
    case catalog
    case settingsSchema
    case reminders
    case badges
    case menuApp
    case notifications
    case awake
    case microphone
    case brightness

    private static let order = allCases
    static let table = order.map(\.rawValue).joined(separator: "\n")

    var bit: UInt64 {
        1 << UInt64(Self.order.firstIndex(of: self) ?? 0)
    }
}

enum ShellVM {
    static func make(memoryLimit: Int, fonts: ShellFontSet = .init()) -> OpaquePointer? {
        let keys = ShellDataKey.table
        guard let vm = keys.withCString({ omni_vm_create(memoryLimit, $0, keys.utf8.count) }) else { return nil }
        omni_vm_set_localizer(vm, ShellLocalizer.callback, nil)
        omni_vm_set_formatter(vm, ShellFormatter.callback, nil)
        omni_vm_set_measurer(vm, ShellTextMeasurer.callback, nil)
        guard setFonts(fonts, in: vm) == OMNI_OK else {
            _ = omni_vm_destroy(vm)
            return nil
        }
        return vm
    }

    private static func setFonts(_ fonts: ShellFontSet, in vm: OpaquePointer) -> omni_status {
        let families = fonts.ids.sorted { $0.value < $1.value }
        var storage: [CChar] = []
        let spans = families.map { family in
            let start = storage.count
            storage.append(contentsOf: family.key.utf8.map { CChar(bitPattern: $0) })
            return (start: start, length: storage.count - start, id: family.value)
        }
        return storage.withUnsafeBufferPointer { bytes in
            let entries = spans.map { span in
                omni_font_family(name: bytes.baseAddress?.advanced(by: span.start), length: span.length, id: span.id)
            }
            return entries.withUnsafeBufferPointer { omni_vm_set_fonts(vm, $0.baseAddress, $0.count) }
        }
    }
}

struct ShellNetworkRate: Equatable, Sendable {
    var down = 0.0
    var up = 0.0
}

struct ShellNetworkHistory: Equatable, Sendable, ShellValueWritable {
    static let length = 31

    var down: [Double] = []
    var up: [Double] = []
    var received: UInt64 = 0
    var sent: UInt64 = 0

    mutating func append(_ rate: ShellNetworkRate) {
        down = Array((down + [rate.down]).suffix(Self.length))
        up = Array((up + [rate.up]).suffix(Self.length))
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        for (key, values) in [("down", down), ("up", up)] {
            writer.key(key)
            writer.array(values.count)
            values.forEach { writer.number($0) }
        }
        writer.key("received")
        writer.number(Double(received))
        writer.key("sent")
        writer.number(Double(sent))
    }
}

struct ShellWidgetData: Equatable, Sendable {
    var clock = ""
    var date = ""
    var seconds = 0.0
    var cpu: Double?
    var memory = 0.0
    var battery: Double?
    var charging = false
    var gpu: Double?
    var disk: Double?
    var network: ShellNetworkRate?
    var volume: Double?
    var muted: Bool?
    var awake: ShellAwake?
    var microphone: ShellMicrophone?
    var brightness: ShellBrightness?
    var outputs: [ShellAudioOutput]?
    var audioApps: ShellAudioApps?
    var media: ShellMedia?
    var calendar: ShellCalendar?
    var reminders: ShellReminders?
    var notifications: ShellNotificationsData?
    var badges: [String: String] = [:]
    var power: ShellPower?
    var inputSource: ShellInputSource?
    var privacy: ShellPrivacy?
    var wifi: ShellWiFi?
    var bluetooth: ShellBluetooth?
    var user: ShellUser?
    var thermal: ShellThermal?
    var networkHistory: ShellNetworkHistory?
    var appearance: ShellAppearance?
    var lyrics: ShellLyrics?
    var spectrum: ShellSpectrum?
    var vars: [String: String] = [:]
    var weather: ShellWeather?
    var hiddenBar = ShellHiddenBarData()
    var system: ShellSystemData?
    var world = ShellWorldData()
}

extension ShellWidgetData {
    func changedKeys(from previous: borrowing Self) -> UInt64 {
        Self.changed(.clock, when: clock != previous.clock)
            | Self.changed(.date, when: date != previous.date)
            | Self.changed(.seconds, when: seconds != previous.seconds)
            | Self.changed(.cpu, when: cpu != previous.cpu)
            | Self.changed(.memory, when: memory != previous.memory)
            | Self.changed(.battery, when: battery != previous.battery)
            | Self.changed(.charging, when: charging != previous.charging)
            | Self.changed(.gpu, when: gpu != previous.gpu)
            | Self.changed(.disk, when: disk != previous.disk)
            | Self.changed(.network, when: network != previous.network)
            | Self.changed(.volume, when: volume != previous.volume)
            | Self.changed(.muted, when: muted != previous.muted)
            | Self.changed(.awake, when: awake != previous.awake)
            | Self.changed(.microphone, when: microphone != previous.microphone)
            | Self.changed(.brightness, when: brightness != previous.brightness)
            | Self.changed(.outputs, when: outputs != previous.outputs)
            | Self.changed(.audioApps, when: audioApps != previous.audioApps)
            | Self.changed(.media, when: media != previous.media)
            | Self.changed(.calendar, when: calendar != previous.calendar)
            | Self.changed(.reminders, when: reminders != previous.reminders)
            | Self.changed(.notifications, when: notifications != previous.notifications)
            | Self.changed(.badges, when: badges != previous.badges)
            | Self.changed(.power, when: power != previous.power)
            | Self.changed(.inputSource, when: inputSource != previous.inputSource)
            | Self.changed(.privacy, when: privacy != previous.privacy)
            | Self.changed(.wifi, when: wifi != previous.wifi)
            | Self.changed(.bluetooth, when: bluetooth != previous.bluetooth)
            | Self.changed(.user, when: user != previous.user)
            | Self.changed(.thermal, when: thermal != previous.thermal)
            | Self.changed(.networkHistory, when: networkHistory != previous.networkHistory)
            | Self.changed(.appearance, when: appearance != previous.appearance)
            | Self.changed(.lyrics, when: lyrics != previous.lyrics)
            | Self.changed(.spectrum, when: spectrum != previous.spectrum)
            | Self.changed(.vars, when: vars != previous.vars)
            | Self.changed(.weather, when: weather != previous.weather)
            | Self.changed(.hiddenBar, when: hiddenBar != previous.hiddenBar)
            | Self.changed(.system, when: system != previous.system)
            | Self.changed(.tempo, when: spectrum?.bpm != previous.spectrum?.bpm)
            | Self.changed(.workspace, when: world.workspace != previous.world.workspace)
            | Self.changed(.app, when: world.app != previous.world.app)
            | Self.changed(.bundle, when: world.bundle != previous.world.bundle)
            | Self.changed(.title, when: world.title != previous.world.title)
            | Self.changed(.workspaces, when: world.workspaces != previous.world.workspaces)
            | Self.changed(.menuApp, when: world.menuApp != previous.world.menuApp)
    }

    private static func changed(_ key: ShellDataKey, when differs: Bool) -> UInt64 {
        differs ? key.bit : 0
    }
}
