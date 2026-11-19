// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct ShellBetterDisplayClient: Sendable {
    struct Level: Equatable, Sendable {
        let value: Double?
    }

    var runningPID: @MainActor @Sendable () -> pid_t?
    var brightness: @Sendable ([UUID]) async -> [UUID: Level]
    var nightShift: @Sendable () async -> Bool?
    var setBrightness: @Sendable (pid_t, UUID, Double) async -> Bool
    var setNightShift: @Sendable (pid_t, Bool) async -> Bool
    var openMenu: @Sendable (pid_t) async -> Bool

    static let live = client(runningPID: currentPID, request: BetterDisplayNotification.request)

    @MainActor
    fileprivate static func currentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "pro.betterdisplay.BetterDisplay")
            .first { !$0.isTerminated }?.processIdentifier
    }

    // Each compound operation keeps the identity of the running app that answered its first request.
    typealias Request = @Sendable (pid_t, String, [String: String?]) async -> String?

    static func client(
        runningPID: @escaping @MainActor @Sendable () -> pid_t?,
        request: @escaping Request
    ) -> Self {
        @Sendable func connectedLevel(_ pid: pid_t, _ id: UUID) async -> Level? {
            guard await request(pid, "get", ["UUID": id.uuidString, "connected": nil]) == "on" else { return nil }
            guard let text = await request(pid, "get", ["UUID": id.uuidString, "brightness": nil]),
                  let value = Double(text), (0 ... 1).contains(value) else { return Level(value: nil) }
            return Level(value: value)
        }

        @Sendable func devices(_ pid: pid_t) async -> Set<UUID> {
            guard let payload = await request(pid, "get", ["type": "Display", "identifiers": nil]) else { return [] }
            return displayIDs(payload)
        }

        @Sendable func nightShift(_ pid: pid_t) async -> Bool? {
            switch await request(pid, "get", ["nightShift": nil]) {
            case "on": true
            case "off": false
            default: nil
            }
        }

        return Self(
            runningPID: runningPID,
            brightness: { ids in
                guard !ids.isEmpty, let pid = await runningPID() else { return [:] }
                let targets = await devices(pid).intersection(ids)
                return await withTaskGroup(of: (UUID, Level?).self) { group in
                    for id in targets { group.addTask { await (id, connectedLevel(pid, id)) } }
                    var levels: [UUID: Level] = [:]
                    for await (id, value) in group { levels[id] = value }
                    return await runningPID() == pid ? levels : [:]
                }
            },
            nightShift: {
                guard let pid = await runningPID() else { return nil }
                return await nightShift(pid)
            },
            setBrightness: { pid, id, value in
                guard (0 ... 1).contains(value), await runningPID() == pid,
                      await devices(pid).contains(id), await connectedLevel(pid, id)?.value != nil else { return false }
                return await request(pid, "set", ["UUID": id.uuidString, "brightness": String(value)]) != nil
            },
            setNightShift: { pid, enabled in
                guard await runningPID() == pid, await nightShift(pid) != nil else { return false }
                return await request(pid, "set", ["nightShift": enabled ? "on" : "off"]) != nil
            },
            openMenu: { pid in
                guard await runningPID() == pid else { return false }
                return await request(pid, "set", ["appMenu": "on"]) != nil
            }
        )
    }

    static func displayIDs(_ payload: String) -> Set<UUID> {
        // The integration returns either a JSON array or comma-separated identifier objects.
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let array = trimmed.hasPrefix("[") ? trimmed : "[\(trimmed)]"
        guard let entries = (try? JSONSerialization.jsonObject(with: Data(array.utf8))) as? [Any] else { return [] }
        var ids: Set<UUID> = []
        var duplicates: Set<UUID> = []
        for case let display as [String: Any] in entries {
            guard display["deviceType"] as? String == "Display", let text = display["UUID"] as? String,
                  let id = UUID(uuidString: text) else { continue }
            if !ids.insert(id).inserted { duplicates.insert(id) }
        }
        return ids.subtracting(duplicates)
    }
}

// https://betterdisplay.pro/guide/integration/third-party-apps/
private enum BetterDisplayNotification {
    struct Command: Encodable {
        let uuid: String
        let commands: [String]
        let parameters: [String: String?]
    }

    struct Response: Decodable {
        let uuid: String
        let result: Bool?
        let payload: String?
    }

    @MainActor
    static func request(_ pid: pid_t, _ command: String, _ parameters: [String: String?]) async -> String? {
        let id = UUID().uuidString
        let envelope = Command(uuid: id, commands: [command], parameters: parameters)
        guard !Task.isCancelled, ShellBetterDisplayClient.currentPID() == pid,
              let data = try? JSONEncoder().encode(envelope) else { return nil }
        let center = DistributedNotificationCenter.default()
        let (stream, reply) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(1))
        let observer = center.addObserver(
            forName: .init("pro.betterdisplay.BetterDisplay.response"), object: nil, queue: .main
        ) { notification in
            guard let text = notification.object as? String,
                  let response = try? JSONDecoder().decode(Response.self, from: Data(text.utf8)),
                  response.uuid == id else { return }
            if response.result != false {
                reply.yield((response.payload ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            reply.finish()
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(1))
            reply.finish()
        }
        defer {
            timeout.cancel()
            center.removeObserver(observer)
            reply.finish()
        }
        center.postNotificationName(
            .init("pro.betterdisplay.BetterDisplay.request"), object: String(decoding: data, as: UTF8.self),
            userInfo: nil, deliverImmediately: true
        )
        for await result in stream {
            return !Task.isCancelled && ShellBetterDisplayClient.currentPID() == pid ? result : nil
        }
        return nil
    }
}
