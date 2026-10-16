// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreAudio
import OmniWMAudioTap

struct AppVolumeSetting: Codable, Equatable, Sendable {
    var volume = 100.0
    var muted = false

    var isUnity: Bool {
        volume >= 100 && !muted
    }

    var gain: Float {
        muted ? 0 : Float(min(max(volume, 0), 100) / 100)
    }
}

enum AppVolumeCommand: Equatable, Sendable {
    case set(percent: Double)
    case toggleMute
    case reset

    init?(words: [String]) {
        switch words {
        case ["mute"]: self = .toggleMute
        case ["reset"]: self = .reset
        case let words where words.count == 2 && words[0] == "set":
            guard let percent = Double(words[1]), percent.isFinite else { return nil }
            self = .set(percent: percent)
        default: return nil
        }
    }

    func applied(to setting: AppVolumeSetting) -> AppVolumeSetting {
        switch self {
        case let .set(percent): AppVolumeSetting(volume: min(max(percent, 0), 100).rounded(), muted: false)
        case .toggleMute: AppVolumeSetting(volume: setting.volume, muted: !setting.muted)
        case .reset: AppVolumeSetting()
        }
    }
}

enum AppVolumeAccess: String, Sendable {
    case unknown
    case granted
    case denied
}

struct ShellAudioApp: Equatable, Sendable {
    let id: String
    let name: String
    let playing: Bool
    let volume: Double
    let muted: Bool
}

struct ShellAudioApps: Equatable, Sendable {
    var access = AppVolumeAccess.unknown
    var apps: [ShellAudioApp] = []

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("access")
        writer.string(access.rawValue)
        writer.key("apps")
        writer.array(apps.count)
        for app in apps {
            writer.map(5)
            writer.key("id")
            writer.string(app.id)
            writer.key("name")
            writer.string(app.name)
            writer.key("playing")
            writer.bool(app.playing)
            writer.key("volume")
            writer.number(app.volume)
            writer.key("muted")
            writer.bool(app.muted)
        }
    }
}

struct AppVolumeReport: Equatable, Sendable {
    struct App: Equatable, Sendable {
        let id: String
        let name: String
        let playing: Bool
    }

    var sequence = 0
    var access = AppVolumeAccess.unknown
    var apps: [App] = []
}

@MainActor
final class AppVolumeMixer {
    private let settings: SettingsStore
    private var version = 0
    private var listing = false
    private var report = AppVolumeReport()
    var onChange: (@MainActor (ShellAudioApps) -> Void)?

    private lazy var engine = AppVolumeEngine { [weak self] report in
        guard let mixer = self else { return }
        Task { @MainActor in
            mixer.received(report)
        }
    }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var apps: ShellAudioApps {
        let volumes = settings.appVolumes
        return ShellAudioApps(access: report.access, apps: report.apps.map { app in
            let setting = volumes[app.id] ?? AppVolumeSetting()
            return ShellAudioApp(
                id: app.id,
                name: app.name,
                playing: app.playing,
                volume: setting.volume,
                muted: setting.muted
            )
        })
    }

    func start() {
        guard !settings.appVolumes.isEmpty else { return }
        sync()
    }

    func setListing(_ listing: Bool) {
        guard self.listing != listing else { return }
        self.listing = listing
        sync()
    }

    func perform(_ command: AppVolumeCommand, on bundle: String) {
        var volumes = settings.appVolumes
        let setting = command.applied(to: volumes[bundle] ?? AppVolumeSetting())
        volumes[bundle] = setting.isUnity ? nil : setting
        guard volumes != settings.appVolumes else { return }
        settings.appVolumes = volumes
        sync()
        onChange?(apps)
    }

    func stop() async {
        version += 1
        await engine.update(AppVolumeEngine.Request(version: version, volumes: [:], listing: false))
    }

    private func sync() {
        version += 1
        let request = AppVolumeEngine.Request(version: version, volumes: settings.appVolumes, listing: listing)
        Task { [engine] in
            await engine.update(request)
        }
    }

    private func received(_ report: AppVolumeReport) {
        guard report.sequence > self.report.sequence else { return }
        let previous = apps
        self.report = report
        if apps != previous {
            onChange?(apps)
        }
    }
}

actor AppVolumeEngine {
    struct Request: Sendable {
        let version: Int
        let volumes: [String: AppVolumeSetting]
        let listing: Bool
    }

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.app-volume")
    private let deliver: @Sendable (AppVolumeReport) -> Void
    private var request = Request(version: 0, volumes: [:], listing: false)
    private var taps: [String: AppVolumeTap] = [:]
    private var systemListeners: [Listener] = []
    private var processListeners: [AudioObjectID: Listener] = [:]
    private var access = AppVolumeAccess.unknown
    private var requestingAccess = false
    private var sequence = 0
    private var reported = AppVolumeReport()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(deliver: @escaping @Sendable (AppVolumeReport) -> Void) {
        self.deliver = deliver
    }

    func update(_ request: Request) {
        guard request.version > self.request.version else { return }
        let previous = self.request
        self.request = request
        guard Self.changesOnlyGains(from: previous, to: request, tapped: taps.keys) else {
            reconcile()
            return
        }
        for (bundle, tap) in taps {
            request.volumes[bundle].map { tap.setGain($0.gain) }
        }
    }

    static func changesOnlyGains(from previous: Request, to request: Request, tapped: some Collection<String>) -> Bool {
        let attenuated = request.volumes.filter { !$0.value.isUnity }
        return !tapped.isEmpty && request.listing == previous.listing && attenuated.count == tapped.count
            && tapped.allSatisfy { attenuated[$0] != nil }
    }

    private func reconcile() {
        guard request.listing || request.volumes.values.contains(where: { !$0.isUnity }) else {
            removeListeners()
            for bundle in Array(taps.keys) {
                taps.removeValue(forKey: bundle)?.stop()
            }
            publish([])
            return
        }
        if systemListeners.isEmpty {
            let system = AudioObjectID(kAudioObjectSystemObject)
            listen(to: system, AppAudioProcess.listAddress).map { systemListeners.append($0) }
            listen(to: system, ShellAudio.defaultOutputAddress).map { systemListeners.append($0) }
        }
        let processes = AppAudioProcess.all()
        syncProcessListeners(request.listing ? Set(processes.map(\.object)) : [])
        let output = ShellAudio.defaultOutput().flatMap(ShellAudio.uid(of:))
        let groups = Dictionary(grouping: processes, by: \.app)
        let attenuated = request.volumes.filter { !$0.value.isUnity && groups[$0.key] != nil }
        let permitted = !attenuated.isEmpty && output != nil && checkAccess()
        for bundle in Array(taps.keys) where !permitted || attenuated[bundle] == nil {
            taps.removeValue(forKey: bundle)?.stop()
        }
        for (bundle, setting) in attenuated where permitted {
            let objects = groups[bundle].map { $0.map(\.object).sorted() } ?? []
            if let tap = taps[bundle], tap.objects == objects, tap.output == output {
                tap.setGain(setting.gain)
                continue
            }
            let replacement = output.flatMap { build(objects: objects, output: $0, gain: setting.gain) }
            taps.removeValue(forKey: bundle)?.stop()
            taps[bundle] = replacement
        }
        publish(request.listing ? processes : [])
    }

    private func checkAccess() -> Bool {
        guard let status = AudioCapturePermission.status else { return true }
        access = status
        if status == .unknown, !requestingAccess {
            requestingAccess = AudioCapturePermission.request { [weak self] _ in
                guard let engine = self else { return }
                Task {
                    await engine.accessAnswered()
                }
            }
        }
        return status == .granted
    }

    private func accessAnswered() {
        requestingAccess = false
        reconcile()
    }

    private func build(objects: [AudioObjectID], output: String, gain: Float) -> AppVolumeTap? {
        do {
            return try AppVolumeTap(objects: objects, output: output, gain: gain)
        } catch {
            Log.shell.error("Per-app volume could not attenuate \(objects.count) audio processes: \(error)")
            return nil
        }
    }

    private func publish(_ processes: [AppAudioProcess]) {
        let apps = Dictionary(grouping: processes, by: \.app).map { bundle, members in
            AppVolumeReport.App(id: bundle, name: members[0].name, playing: members.contains(where: \.playing))
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        guard apps != reported.apps || access != reported.access else { return }
        sequence += 1
        reported = AppVolumeReport(sequence: sequence, access: access, apps: apps)
        deliver(reported)
    }

    private func syncProcessListeners(_ objects: Set<AudioObjectID>) {
        for (object, listener) in processListeners where !objects.contains(object) {
            remove(listener)
            processListeners[object] = nil
        }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = listen(to: object, AppAudioProcess.runningOutputAddress)
        }
    }

    private func listen(to object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Listener? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.assumeIsolated { $0.reconcile() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
    }

    private func removeListeners() {
        for listener in systemListeners + processListeners.values {
            remove(listener)
        }
        systemListeners = []
        processListeners = [:]
    }
}

private struct AppAudioProcess {
    let object: AudioObjectID
    let app: String
    let name: String
    let playing: Bool

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    private static let responsiblePID: ResponsiblePID? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "responsibility_get_pid_responsible_for_pid"
    ).map { unsafeBitCast($0, to: ResponsiblePID.self) }

    static var listAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var runningOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func all() -> [AppAudioProcess] {
        var address = listAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let own = getpid()
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
            var pid: pid_t = 0
            guard read(kAudioProcessPropertyPID, of: object, into: &pid), pid > 0, pid != own else { return nil }
            let owner = responsiblePID?(pid) ?? pid
            guard owner != own else { return nil }
            let application = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid)
            guard let bundle = application?.bundleIdentifier ?? bundleID(of: object) else { return nil }
            var running: UInt32 = 0
            _ = read(kAudioProcessPropertyIsRunningOutput, of: object, into: &running)
            return AppAudioProcess(
                object: object,
                app: bundle,
                name: application?.localizedName ?? bundle,
                playing: running != 0
            )
        }
    }

    private static func read<Value>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        into value: inout Value
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var bundle: Unmanaged<CFString>?
        guard read(kAudioProcessPropertyBundleID, of: object, into: &bundle),
              let bundle = bundle?.takeRetainedValue() as String?, !bundle.isEmpty
        else {
            return nil
        }
        return bundle
    }
}
