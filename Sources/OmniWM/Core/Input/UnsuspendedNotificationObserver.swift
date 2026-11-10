// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NotificationCenter {
    // AppKit suspends the distributed center once the app resigns active, and block observers then coalesce:
    // a layout switch reached them only with the next distributed notification, seconds later.
    func addUnsuspendedObserver(
        forName name: Notification.Name,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        let observer = UnsuspendedNotificationObserver(block)
        let selector = #selector(UnsuspendedNotificationObserver.receive(_:))
        if let distributed = self as? DistributedNotificationCenter {
            distributed.addObserver(
                observer,
                selector: selector,
                name: name,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        } else {
            addObserver(observer, selector: selector, name: name, object: nil)
        }
        return observer
    }
}

private final class UnsuspendedNotificationObserver: NSObject, Sendable {
    private let block: @Sendable (Notification) -> Void

    init(_ block: @escaping @Sendable (Notification) -> Void) {
        self.block = block
    }

    @objc func receive(_ notification: Notification) {
        block(notification)
    }
}
