// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
func measureStore(in directory: URL) async throws {
    let location = directory.appendingPathComponent("store")
    let fixture = try ScriptARCFixture(directory: location)
    try await fixture.storeRoutes()
    let reopened = try ScriptARCFixture(directory: location)
    try await reopened.coldStoreRoute()
}

@MainActor
extension ScriptARCFixture {
    private static let occupancySamples = 21
    private static let largeElements = ConfigScriptStore.listLimit
    private static let largeLength = ConfigScriptStore.byteLimit / 2 / largeElements

    var loader: ConfigScriptLoader {
        script.loader
    }

    static func storeLoader(in directory: URL) -> ConfigScriptLoader {
        ConfigScriptLoader(store: ConfigScriptStore(fileURL: directory.appendingPathComponent("script-store.json")))
    }

    private static let storeScript = """
    local wm = omniwm
    local writes = 0
    wm.keymap.set("Control+Option+0", function() end)
    wm.keymap.set("Control+Option+1", function() local count = wm.store.get("audit.count") end)
    wm.keymap.set("Control+Option+2", function() local list = wm.store.get("audit.list") end)
    wm.keymap.set("Control+Option+3", function() wm.store.set("audit.flag", true) end)
    wm.keymap.set("Control+Option+4", function()
        writes += 1
        wm.store.set("audit.count", writes)
    end)
    wm.keymap.set("Control+Option+5", function()
        writes += 1
        for i = 1, 8 do wm.store.set("audit.batch." .. i, writes + i) end
    end)
    wm.keymap.set("Control+Option+6", function()
        writes += 1
        local text = string.rep(if writes % 2 == 0 then "a" else "b", \(largeLength))
        wm.store.set("audit.large", table.create(\(largeElements), text))
    end)
    wm.keymap.set("Control+Option+7", function()
        wm.store.set("audit.list", { "com.apple.Safari", "com.mitchellh.ghostty", "com.apple.TextEdit" })
        wm.store.set("audit.flag", true)
    end)
    """

    fileprivate func storeRoutes() async throws {
        _ = try await acceptTitleScript(Self.storeScript)
        let control = try binding("Control+Option+0")
        let get = try binding("Control+Option+1")
        let getList = try binding("Control+Option+2")
        let equal = try binding("Control+Option+3")
        let changed = try binding("Control+Option+4")
        let batch = try binding("Control+Option+5")
        let large = try binding("Control+Option+6")
        try await storePress(try binding("Control+Option+7"), route: "store/seed", writes: true, report: false)
        try await storePress(changed, route: "store/seed", writes: true, report: false)
        for report in [false, true] {
            try await function(control, route: "store/control", busy: false, report: report)
            try await storePress(get, route: "store/get", writes: false, report: report)
            try await storePress(getList, route: "store/get-list", writes: false, report: report)
            try await storePress(equal, route: "store/equal-set", writes: false, report: report)
            try await storePress(changed, route: "store/changed-set", writes: true, report: report)
            try await storePress(batch, route: "store/batch-8", writes: true, report: report)
            try await storePress(large, route: "store/large-write", writes: true, report: report)
        }
        for (route, command) in [("control", control), ("changed-set", changed), ("large-write", large)] {
            try await reportOccupancy(command, route: route)
        }
    }

    fileprivate func coldStoreRoute() async throws {
        _ = try await acceptTitleScript(Self.storeScript)
        try await function(try binding("Control+Option+0"), route: "store/control", busy: false, report: false)
        try await storePress(try binding("Control+Option+1"), route: "store/cold-get", writes: false, report: true)
    }

    private func storePress(_ command: HotkeyCommand, route: String, writes: Bool, report: Bool) async throws {
        let file = loader.store.fileURL
        let before = SettingsFileAccess.currentFingerprint(at: file)
        precondition(key(command, measured: true) == .executed)
        try await finishWorker(seed: false)
        guard (SettingsFileAccess.currentFingerprint(at: file) != before) == writes else {
            throw ScriptARCError(route +
                (writes ? " must replace the store file once" : " must not write the store file"))
        }
        if report {
            script_arc_report(route, "store/control", 1)
            print("store-writes \(route) \(writes ? 1 : 0)")
        }
    }

    private func reportOccupancy(_ command: HotkeyCommand, route: String) async throws {
        guard let queue = script.callbackQueue else { throw ScriptARCError("Missing callback queue") }
        var samples: [Duration] = []
        samples.reserveCapacity(Self.occupancySamples)
        let clock = ContinuousClock()
        for _ in 0 ..< Self.occupancySamples {
            let start = clock.now
            precondition(key(command, measured: false) == .executed)
            await queue.waitUntilParked()
            samples.append(clock.now - start)
        }
        if let diagnostic = script.diagnostic { throw ScriptARCError(diagnostic) }
        let median = samples.sorted()[samples.count / 2] / .microseconds(1)
        print("store-occupancy \(route) median=\(Int(median.rounded()))us instrumented")
    }
}
