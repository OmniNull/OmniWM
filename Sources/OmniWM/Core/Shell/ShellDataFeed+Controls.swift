// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ShellDataFeed {
    func listenToAwake(_ listening: Bool) {
        guard listening else {
            if let awakeSubscription {
                awakeManager.removeAwakeSubscription(awakeSubscription)
                self.awakeSubscription = nil
            }
            data.awake = nil
            return
        }
        guard awakeSubscription == nil else { return }
        awakeSubscription = awakeManager.subscribeAwake { [weak self] value in
            guard let self, data.awake != value else { return }
            data.awake = value
            publish()
        }
    }

    func listenToMicrophone(_ listening: Bool) {
        guard listening else {
            microphone.onChange = nil
            microphone.setListening(false)
            data.microphone = nil
            return
        }
        microphone.onChange = { [weak self] value in
            guard let self, data.microphone != value else { return }
            data.microphone = value
            publish()
        }
        microphone.setListening(true)
        data.microphone = microphone.value
    }
}
