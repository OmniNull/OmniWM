// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation

@MainActor
final class KeyboardLayoutObserver {
    static let shared = KeyboardLayoutObserver()

    private let center: NotificationCenter
    private var observer: (any NSObjectProtocol)?
    private var onChange: (@MainActor () -> Void)?

    init(notificationCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        center = notificationCenter
    }

    func observe(_ onChange: (@MainActor () -> Void)?) {
        self.onChange = onChange
        guard (onChange == nil) != (observer == nil) else { return }
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
            return
        }
        observer = center.addUnsuspendedObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onChange?()
            }
        }
    }
}
