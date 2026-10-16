// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class AppVolumeMixerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMAppVolumeMixerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func settings() -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    func testAppCommandsParseAndApplyWithinRange() {
        XCTAssertEqual(
            ShellVolumeCommand(words: ["app", "com.example.player", "set", "30"]),
            .app("com.example.player", .set(percent: 30))
        )
        XCTAssertEqual(
            ShellVolumeCommand(words: ["app", "com.example.player", "mute"]),
            .app("com.example.player", .toggleMute)
        )
        XCTAssertEqual(
            ShellVolumeCommand(words: ["app", "com.example.player", "reset"]),
            .app("com.example.player", .reset)
        )
        XCTAssertEqual(ShellVolumeCommand(words: ["permission"]), .permission)
        XCTAssertNil(ShellVolumeCommand(words: ["app", "com.example.player"]))
        XCTAssertNil(ShellVolumeCommand(words: ["app", "com.example.player", "set", "loud"]))

        let muted = AppVolumeSetting(volume: 40, muted: true)
        XCTAssertEqual(
            AppVolumeCommand.set(percent: 140).applied(to: muted),
            AppVolumeSetting(volume: 100, muted: false)
        )
        XCTAssertEqual(AppVolumeCommand.set(percent: -5).applied(to: muted), AppVolumeSetting(volume: 0, muted: false))
        XCTAssertEqual(AppVolumeCommand.toggleMute.applied(to: muted), AppVolumeSetting(volume: 40, muted: false))
        XCTAssertEqual(AppVolumeCommand.reset.applied(to: muted), AppVolumeSetting())
        XCTAssertEqual(muted.gain, 0)
        XCTAssertEqual(AppVolumeSetting(volume: 25).gain, 0.25)
        XCTAssertTrue(AppVolumeSetting().isUnity)
        XCTAssertFalse(AppVolumeSetting(volume: 100, muted: true).isUnity)
    }

    func testGainOnlyChangesSkipTheProcessScan() {
        let a = "invalid.omniwm.test.a"
        let b = "invalid.omniwm.test.b"
        let request = { (version: Int, volumes: [String: AppVolumeSetting], listing: Bool) in
            AppVolumeEngine.Request(version: version, volumes: volumes, listing: listing)
        }
        let quieter = request(1, [a: AppVolumeSetting(volume: 30)], false)
        let gainOnly = { (next: AppVolumeEngine.Request, tapped: [String]) in
            AppVolumeEngine.changesOnlyGains(from: quieter, to: next, tapped: tapped)
        }
        XCTAssertTrue(gainOnly(request(2, [a: AppVolumeSetting(volume: 40)], false), [a]))
        XCTAssertTrue(gainOnly(request(2, [a: AppVolumeSetting(volume: 30, muted: true)], false), [a]))
        XCTAssertFalse(gainOnly(request(2, [a: AppVolumeSetting(volume: 40)], false), []))
        XCTAssertFalse(gainOnly(
            request(2, [a: AppVolumeSetting(volume: 30), b: AppVolumeSetting(volume: 50)], false),
            [a]
        ))
        XCTAssertFalse(gainOnly(request(2, [:], false), [a]))
        XCTAssertFalse(gainOnly(request(2, [a: AppVolumeSetting(volume: 40)], true), [a]))
    }

    func testVolumesPersistPerBundleAndUnityRemovesTheEntry() async {
        let store = settings()
        let mixer = AppVolumeMixer(settings: store)
        var changes: [ShellAudioApps] = []
        mixer.onChange = { changes.append($0) }

        mixer.perform(.set(percent: 30), on: "invalid.omniwm.test.player")
        mixer.perform(.toggleMute, on: "invalid.omniwm.test.player")
        XCTAssertEqual(store.appVolumes, ["invalid.omniwm.test.player": AppVolumeSetting(volume: 30, muted: true)])
        XCTAssertEqual(changes.count, 2)

        mixer.perform(.reset, on: "invalid.omniwm.test.player")
        XCTAssertEqual(store.appVolumes, [:])
        mixer.perform(.set(percent: 100), on: "invalid.omniwm.test.other")
        XCTAssertEqual(store.appVolumes, [:])
        XCTAssertEqual(changes.count, 3)
        await mixer.stop()
    }

    func testTheFeedListsAudioAppsOnlyWhileTheyAreRead() async {
        let mixer = AppVolumeMixer(settings: settings())
        let feed = ShellDataFeed(appVolumes: mixer, deliver: { _ in })
        feed.start()
        XCTAssertNil(feed.current.audioApps)
        XCTAssertNil(mixer.onChange)

        feed.setDemand(ShellDataKey.audioApps.bit, cadence: .of([(ShellDataKey.audioApps.bit, nil)]))
        XCTAssertEqual(feed.current.audioApps, mixer.apps)
        XCTAssertNotNil(mixer.onChange)

        feed.setDemand(ShellDataKey.volume.bit, cadence: .of([(ShellDataKey.volume.bit, nil)]))
        XCTAssertNil(feed.current.audioApps)
        XCTAssertNil(mixer.onChange)

        feed.setDemand(ShellDataKey.audioApps.bit, cadence: .of([(ShellDataKey.audioApps.bit, nil)]))
        feed.stop()
        XCTAssertNil(mixer.onChange)
        await mixer.stop()
    }

    func testTheVolumePopoutShowsPlayingAndAdjustedAppsWithTheirControls() throws {
        let widget = try ShellRenderedWidget("volume")
        widget.set("volume") { $0.number(40) }
        let apps = { (access: AppVolumeAccess) in
            ShellAudioApps(access: access, apps: [
                ShellAudioApp(id: "com.example.idle", name: "Idle", playing: false, volume: 100, muted: false),
                ShellAudioApp(id: "com.example.music", name: "Music", playing: true, volume: 100, muted: false),
                ShellAudioApp(id: "com.example.quiet", name: "Quiet", playing: false, volume: 30, muted: true)
            ])
        }
        widget.set("audioApps") { apps(.granted).write(into: &$0) }
        let nodes = widget.renderPopout()
        let actions = nodes.map { widget.text.string($0.content.action) }
        XCTAssertTrue(actions.contains("volume app com.example.music mute"))
        XCTAssertTrue(actions.contains("volume app com.example.quiet mute"))
        XCTAssertFalse(actions.contains("volume app com.example.idle mute"))
        XCTAssertFalse(actions.contains("volume permission"))
        let sliders = nodes.filter { $0.kind == .slider }.map(\.content.action)
        XCTAssertEqual(sliders.count, 3)
        var event = ShellEvent(button: .left)
        event.value = 0.3
        event.phase = .changed
        XCTAssertEqual(
            widget.invoke(sliders[1], view: OMNI_VIEW_POPOUT, event: event),
            ["volume app com.example.music set 30"]
        )

        widget.set("audioApps") { apps(.denied).write(into: &$0) }
        XCTAssertTrue(widget.renderPopout().map { widget.text.string($0.content.action) }.contains("volume permission"))
    }
}
