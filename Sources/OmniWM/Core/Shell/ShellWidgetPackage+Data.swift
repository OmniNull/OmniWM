// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension ShellWidgetPackage {
    func hydrate(_ key: ShellBarKey, _ instance: OpaquePointer) {
        guard let state = states[key], state.pendingData != 0 else { return }
        let changed = state.pendingData
        state.pendingData = 0
        updateClock(instance, current, changed)
        updateDevices(instance, current, changed)
        updateAudio(instance, current, changed)
        updateServices(instance, current, changed)
        updateDeviceSources(instance, current, changed)
        update(instance, world: current.world, changed: changed)
    }

    private func updateClock(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        if changed & ShellDataKey.clock.bit != 0 {
            setString(instance, .clock, next.clock)
        }
        if changed & ShellDataKey.date.bit != 0 {
            setString(instance, .date, next.date)
        }
        if changed & ShellDataKey.seconds.bit != 0 {
            setNumber(instance, .seconds, next.seconds)
        }
        if changed & ShellDataKey.cpu.bit != 0 {
            setValue(instance, .cpu) { writer in next.cpu.map { writer.number($0) } ?? writer.null() }
        }
        if changed & ShellDataKey.memory.bit != 0 {
            setNumber(instance, .memory, next.memory)
        }
        if changed & ShellDataKey.gpu.bit != 0 {
            setValue(instance, .gpu) { writer in next.gpu.map { writer.number($0) } ?? writer.null() }
        }
        if changed & ShellDataKey.disk.bit != 0 {
            setValue(instance, .disk) { writer in next.disk.map { writer.number($0) } ?? writer.null() }
        }
    }

    private func updateDevices(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        if changed & ShellDataKey.battery.bit != 0 {
            setValue(instance, .battery) { writer in
                if let battery = next.battery {
                    writer.number(battery)
                } else {
                    writer.null()
                }
            }
        }
        if changed & ShellDataKey.charging.bit != 0 {
            setValue(instance, .charging) { $0.bool(next.charging) }
        }
        if changed & ShellDataKey.power.bit != 0 {
            setValue(instance, .power) { writer in
                guard let power = next.power else { return writer.null() }
                power.write(into: &writer)
            }
        }
        if changed & ShellDataKey.network.bit != 0 {
            setValue(instance, .network) { writer in
                guard let network = next.network else { return writer.null() }
                writer.map(2)
                writer.key("down")
                writer.number(network.down)
                writer.key("up")
                writer.number(network.up)
            }
        }
        if changed & ShellDataKey.hiddenBar.bit != 0 {
            setValue(instance, .hiddenBar) { next.hiddenBar.write(into: &$0) }
        }
    }

    private func updateAudio(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        if changed & ShellDataKey.volume.bit != 0 {
            setValue(instance, .volume) { writer in
                next.volume.map { writer.number($0) } ?? writer.null()
            }
        }
        if changed & ShellDataKey.muted.bit != 0 {
            setValue(instance, .muted) { writer in next.muted.map { writer.bool($0) } ?? writer.null() }
        }
        if changed & ShellDataKey.outputs.bit != 0 {
            setValue(instance, .outputs) { writer in
                guard let outputs = next.outputs else { return writer.null() }
                writer.array(outputs.count)
                for output in outputs {
                    output.write(into: &writer)
                }
            }
        }
        if changed & ShellDataKey.audioApps.bit != 0 {
            setValue(instance, .audioApps) { writer in
                guard let apps = next.audioApps else { return writer.null() }
                apps.write(into: &writer)
            }
        }
        if changed & ShellDataKey.media.bit != 0 {
            setValue(instance, .media) { writer in
                guard let media = next.media else { return writer.null() }
                media.write(into: &writer)
            }
        }
        if changed & ShellDataKey.tempo.bit != 0 {
            setValue(instance, .tempo) { writer in next.spectrum?.bpm.map { writer.number($0) } ?? writer.null() }
        }
    }

    private func updateServices(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        updatePersonalServices(instance, next, changed)
        if changed & ShellDataKey.badges.bit != 0 {
            setValue(instance, .badges) { writer in
                writer.map(next.badges.count)
                for (bundleID, label) in next.badges {
                    writer.key(bundleID)
                    writer.string(label)
                }
            }
        }
        if changed & ShellDataKey.system.bit != 0 {
            setValue(instance, .system) { writer in
                guard let system = next.system else { return writer.null() }
                system.write(into: &writer)
            }
        }
        if changed & ShellDataKey.vars.bit != 0 {
            setValue(instance, .vars) { writer in
                writer.map(next.vars.count)
                for (name, value) in next.vars {
                    writer.key(name)
                    writer.string(value)
                }
            }
        }
    }

    private func updatePersonalServices(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        if changed & ShellDataKey.weather.bit != 0 {
            setValue(instance, .weather) { writer in
                guard let weather = next.weather else { return writer.null() }
                weather.write(into: &writer)
            }
        }
        if changed & ShellDataKey.reminders.bit != 0 {
            setValue(instance, .reminders) { writer in
                guard let reminders = next.reminders else { return writer.null() }
                reminders.write(into: &writer)
            }
        }
        if changed & ShellDataKey.calendar.bit != 0 {
            setValue(instance, .calendar) { writer in
                guard let calendar = next.calendar else { return writer.null() }
                calendar.write(into: &writer)
            }
        }
    }

    private func updateDeviceSources(
        _ instance: OpaquePointer,
        _ next: borrowing ShellWidgetData,
        _ changed: UInt64
    ) {
        if changed & ShellDataKey.inputSource.bit != 0 {
            setValue(instance, .inputSource) { writer in
                next.inputSource.map { $0.write(into: &writer) } ?? writer.null()
            }
        }
        if changed & ShellDataKey.privacy.bit != 0 {
            setValue(instance, .privacy) { writer in next.privacy.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.wifi.bit != 0 {
            setValue(instance, .wifi) { writer in next.wifi.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.bluetooth.bit != 0 {
            setValue(instance, .bluetooth) { writer in next.bluetooth.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.user.bit != 0 {
            setValue(instance, .user) { writer in next.user.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.thermal.bit != 0 {
            setValue(instance, .thermal) { writer in next.thermal.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.networkHistory.bit != 0 {
            setValue(instance, .networkHistory) { writer in
                next.networkHistory.map { $0.write(into: &writer) } ?? writer.null()
            }
        }
        if changed & ShellDataKey.appearance.bit != 0 {
            setValue(instance, .appearance) { writer in
                next.appearance.map { $0.write(into: &writer) } ?? writer.null()
            }
        }
        if changed & ShellDataKey.lyrics.bit != 0 {
            setValue(instance, .lyrics) { writer in next.lyrics.map { $0.write(into: &writer) } ?? writer.null() }
        }
        if changed & ShellDataKey.spectrum.bit != 0 {
            setValue(instance, .spectrum) { writer in next.spectrum.map { $0.write(into: &writer) } ?? writer.null() }
        }
    }

    private func update(_ instance: OpaquePointer, world: borrowing ShellWorldData, changed: UInt64) {
        if changed & ShellDataKey.menuApp.bit != 0 {
            setValue(instance, .menuApp) { writer in
                world.menuApp.map { $0.write(into: &writer) } ?? writer.null()
            }
        }
        if changed & ShellDataKey.workspace.bit != 0 {
            setString(instance, .workspace, world.workspace)
        }
        if changed & ShellDataKey.app.bit != 0 {
            setString(instance, .app, world.app)
        }
        if changed & ShellDataKey.bundle.bit != 0 {
            setString(instance, .bundle, world.bundle)
        }
        if changed & ShellDataKey.title.bit != 0 {
            setString(instance, .title, world.title)
        }
        guard changed & ShellDataKey.workspaces.bit != 0 else { return }
        setValue(instance, .workspaces) { writer in
            writer.array(world.workspaces.count)
            for workspace in world.workspaces {
                writer.map(5)
                writer.key("id")
                writer.string(workspace.id)
                writer.key("name")
                writer.string(workspace.name)
                writer.key("focused")
                writer.bool(workspace.focused)
                writer.key("visible")
                writer.bool(workspace.visible)
                writer.key("windows")
                writer.number(Double(workspace.windows))
            }
        }
    }

    private func setString(_ instance: OpaquePointer, _ key: ShellDataKey, _ value: String) {
        _ = omni_instance_set_string(instance, key.rawValue, value, value.utf8.count)
    }

    private func setNumber(_ instance: OpaquePointer, _ key: ShellDataKey, _ value: Double) {
        _ = omni_instance_set_number(instance, key.rawValue, value)
    }

    func setValue(
        _ instance: OpaquePointer,
        _ key: ShellDataKey,
        _ write: (inout ShellValueWriter) -> Void
    ) {
        valueWriter.reset()
        write(&valueWriter)
        _ = valueWriter.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(instance, key.rawValue, $0.baseAddress, $0.count)
        }
    }
}
