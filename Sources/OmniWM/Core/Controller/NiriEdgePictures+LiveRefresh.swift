// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriEdgePictures {
    static let liveRefreshInterval: Duration = .milliseconds(200)

    static func startLiveCadence(
        interval: Duration,
        tick: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                tick()
            }
        }
        return { task.cancel() }
    }

    private func isRestingPicture(_ token: WindowToken, picture: Picture) -> Bool {
        picture.isResting && picture.surface != nil && isCaptureEligible(token)
    }

    func reconcileLiveRefresh() {
        let needed = pictures.contains { isRestingPicture($0.key, picture: $0.value) }
        if needed {
            guard cancelLiveRefresh == nil else { return }
            cancelLiveRefresh = startCadence(Self.liveRefreshInterval) { [weak self] in self?.refreshRestingPictures() }
        } else {
            cancelLiveRefresh?()
            cancelLiveRefresh = nil
        }
    }

    func refreshRestingPictures() {
        guard !isOverviewOpen(), !isUnderMemoryPressure else { return }
        for (token, picture) in pictures where isRestingPicture(token, picture: picture) {
            guard picture.surface?.isVisibleForCapture == true,
                  let captured = capturedPictures[token], captured.task == nil else { continue }
            requestPicture(token, key: captured.key, refresh: true)
        }
    }
}
