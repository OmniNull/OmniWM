// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

actor ShellNotificationsWorker {
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.notifications", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func read(at url: URL) -> ShellNotificationsData {
        ShellNotificationStore.read(at: url)
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

    static func nativeProcesses() -> (pid_t, pid_t)? {
        guard let notificationPID = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.notificationcenterui"
              ).first?.processIdentifier,
              let menuPID = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.MenuBarAgent"
              ).first?.processIdentifier
        else { return nil }
        return (notificationPID, menuPID)
    }
}
