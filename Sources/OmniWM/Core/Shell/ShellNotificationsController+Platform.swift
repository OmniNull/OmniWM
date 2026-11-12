// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

actor ShellNotificationsWorker {
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.notifications", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func read(at url: URL, preferencesURL: URL) -> ShellNotificationsData {
        ShellNotificationStore.read(at: url, preferencesURL: preferencesURL) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }
}

extension ShellNotificationsController {
    struct StorageRevision: Equatable {
        let database: SettingsFileAccess.Fingerprint?
        let wal: SettingsFileAccess.Fingerprint?

        init(database: SettingsFileAccess.Fingerprint? = nil, wal: SettingsFileAccess.Fingerprint? = nil) {
            self.database = database
            self.wal = wal
        }

        static func read(at url: URL) -> Self {
            Self(
                database: SettingsFileAccess.currentFingerprint(at: url),
                wal: SettingsFileAccess.currentFingerprint(at: URL(fileURLWithPath: url.path + "-wal"))
            )
        }
    }

    static func observedPaths(at url: URL, preferencesURL: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        return [
            directory.deletingLastPathComponent(), directory, url,
            URL(fileURLWithPath: url.path + "-wal"),
            preferencesURL.deletingLastPathComponent(), preferencesURL
        ]
    }

    static func nativeProcesses(
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        runningPID: (String) -> pid_t? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        }
    ) -> (pid_t, pid_t)? {
        let menuBarAgent = "com.apple.MenuBarAgent"
        let controlCenter = "com.apple.controlcenter"
        let (clockHost, fallbackClockHost) = osMajorVersion >= 27
            ? (menuBarAgent, controlCenter)
            : (controlCenter, menuBarAgent)
        guard let notificationPID = runningPID("com.apple.notificationcenterui"),
              let menuPID = runningPID(clockHost) ?? runningPID(fallbackClockHost)
        else { return nil }
        return (notificationPID, menuPID)
    }

    static func nativeDismissAll(_ accessibility: ShellNotificationAccessibility) -> DismissAllPerformer {
        { requests, progress in
            guard let (notificationPID, menuPID) = nativeProcesses() else { return .unavailable }
            let updates = AsyncStream<ShellNotificationActionOutcome>.makeStream()
            let consumer = Task {
                for await outcome in updates.stream { progress(outcome) }
            }
            let native = Task {
                let outcome = await accessibility.dismissAll(
                    requests, notificationPID: notificationPID, menuPID: menuPID,
                    progress: { updates.continuation.yield($0) }
                )
                updates.continuation.finish()
                return outcome
            }
            return await withTaskCancellationHandler {
                let outcome = await native.value
                await consumer.value
                return outcome
            } onCancel: {
                native.cancel()
            }
        }
    }
}
