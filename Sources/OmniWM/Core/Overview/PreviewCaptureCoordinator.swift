// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Dispatch
import ScreenCaptureKit

@MainActor
final class PreviewCaptureCoordinator {
    static let shared = PreviewCaptureCoordinator()

    struct SharedPreview {
        let frame: OverviewPreviewFrame
        let capturedAt: UInt64
    }

    private final class WeakCapture {
        weak var capture: OverviewThumbnailCapture?

        init(_ capture: OverviewThumbnailCapture) {
            self.capture = capture
        }
    }

    private struct RetainedFrame {
        let bytes: Int
        var lastUse: UInt64 = 0
        var pinned = false
        var holders: [(capture: OverviewThumbnailCapture, handle: WindowHandle)] = []
    }

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let memoryPressure: any DispatchSourceMemoryPressure
    private var captures: [WeakCapture] = []
    private var windowsByToken: [WindowToken: SCWindow] = [:]
    private var discoveryTask: Task<Int?, Never>?
    private var clock: UInt64 = 0

    init(ownedWindowRegistry: OwnedWindowRegistry = .shared) {
        self.ownedWindowRegistry = ownedWindowRegistry
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseCaches(reason: .memoryPressure) }
        }
        memoryPressure.activate()
    }

    isolated deinit {
        memoryPressure.cancel()
    }

    func register(_ capture: OverviewThumbnailCapture) {
        captures.append(WeakCapture(capture))
    }

    func nextUse() -> UInt64 {
        clock &+= 1
        return clock
    }

    func window(for token: WindowToken) async -> (window: SCWindow?, discoveredCount: Int?) {
        if let window = windowsByToken[token] { return (window, nil) }
        if let discoveryTask {
            _ = await discoveryTask.value
            return (windowsByToken[token], nil)
        }
        let task = Task { @MainActor [weak self] () -> Int? in
            guard let self else { return nil }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                windowsByToken = Dictionary(uniqueKeysWithValues: content.windows.compactMap { window in
                    guard let app = window.owningApplication,
                          ownedWindowRegistry.isCaptureEligible(windowNumber: Int(window.windowID))
                    else { return nil }
                    return (WindowToken(pid: app.processID, windowId: Int(window.windowID)), window)
                })
                return windowsByToken.count
            } catch {
                ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
                FallbackFiringRecorder.shared.note(.capture, "overviewContentException")
                return nil
            }
        }
        discoveryTask = task
        let discoveredCount = await task.value
        discoveryTask = nil
        return (windowsByToken[token], discoveredCount)
    }

    func sharedPreview(
        for token: WindowToken,
        excluding requester: OverviewThumbnailCapture? = nil,
        satisfying request: OverviewPreviewRequest? = nil
    ) -> SharedPreview? {
        var newest: SharedPreview?
        for capture in liveCaptures() where capture !== requester {
            guard let candidate = capture.retainedPreview(matching: token),
                  request.map({ candidate.frame.covers($0) }) ?? true,
                  candidate.capturedAt > newest?.capturedAt ?? 0
            else { continue }
            newest = candidate
        }
        return newest
    }

    func trimRetainedPreviews() {
        let captures = liveCaptures()
        guard let budget = captures.map(\.maximumRetainedBytes).max() else { return }
        var frames: [ObjectIdentifier: RetainedFrame] = [:]
        for capture in captures {
            let pinned = capture.isPresenting
            capture.forEachRetainedPreview { handle, frame, lastUse in
                let key = ObjectIdentifier(frame)
                var entry = frames[key] ?? RetainedFrame(bytes: frame.surface.allocationSize)
                entry.lastUse = max(entry.lastUse, lastUse)
                entry.pinned = entry.pinned || pinned
                entry.holders.append((capture, handle))
                frames[key] = entry
            }
        }
        guard frames.values.reduce(0, { $0 + $1.bytes }) > budget else { return }
        var remaining = budget - frames.values.filter(\.pinned).reduce(0) { $0 + $1.bytes }
        for entry in frames.values.filter({ !$0.pinned }).sorted(by: { $0.lastUse > $1.lastUse }) {
            if entry.bytes <= remaining {
                remaining -= entry.bytes
            } else {
                for holder in entry.holders {
                    holder.capture.evictRetainedPreview(for: holder.handle)
                }
            }
        }
    }

    func windowRemoved(_ token: WindowToken) {
        windowsByToken[token] = nil
        for capture in liveCaptures() {
            capture.remove(token: token)
        }
    }

    func releaseCaches(reason: OverviewThumbnailCapture.CacheReleaseReason) {
        for capture in liveCaptures() {
            capture.releaseCache(reason: reason)
        }
    }

    private func liveCaptures() -> [OverviewThumbnailCapture] {
        captures.removeAll { $0.capture == nil }
        return captures.compactMap(\.capture)
    }
}

extension OverviewThumbnailCapture {
    enum CacheReleaseReason {
        case memoryPressure, shutdown, explicitRelease

        var traceReason: OverviewFrameTrace.PreviewReason {
            switch self {
            case .memoryPressure: .memoryPressure
            case .shutdown: .shutdown
            case .explicitRelease: .explicitRelease
            }
        }
    }
}
