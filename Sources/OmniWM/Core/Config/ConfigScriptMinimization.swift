// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@MainActor
final class ConfigScriptMinimization {
    @MainActor
    struct Batch {
        let root: WindowToken
        private var children = InlineArray<128, WindowToken?>(repeating: nil)
        private(set) var count = 0
        private(set) var missed = 0

        init(root: WindowToken) {
            self.root = root
            precondition(children.count == 2 * ConfigScriptCallbackQueue.windowStateCapacity)
        }

        mutating func append(_ token: WindowToken, observer: ConfigScriptEventObservers) {
            if count >= ConfigScriptCallbackQueue.windowStateCapacity,
               !observer.hasPendingMinimize(token, epoch: observer.nativeInput.session.epoch)
            {
                missed += 1
                return
            }
            children[count] = token
            count += 1
        }

        func publish(minimized: Bool, observer: ConfigScriptEventObservers, in manager: WorkspaceManager) {
            observer.windowStateChanged(.windowMinimize, token: root, value: .minimized(minimized), in: manager)
            for index in 0 ..< count {
                observer.windowStateChanged(
                    .windowMinimize,
                    token: children[index]!,
                    value: .minimized(minimized),
                    in: manager
                )
            }
            if missed > 0 {
                observer.recordMissedMinimizations(missed)
            }
        }
    }

    var active: Batch?
}
