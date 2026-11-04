// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct NiriPicturePreparation {
    let isSettled: Bool
    var warmCandidates: [WindowToken: CGSize] = [:]
    var motionCandidates: [WindowToken: CGSize] = [:]
}

struct NiriPictureCaptureKey: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let displayId: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat
    let size: CGSize

    func hasSameContext(as other: Self) -> Bool {
        workspaceId == other.workspaceId && displayId == other.displayId
            && displayFrame == other.displayFrame && scale == other.scale
    }

    init(plan: WorkspaceLayoutPlan, size: CGSize) {
        workspaceId = plan.workspaceId
        displayId = plan.monitor.displayId
        displayFrame = plan.monitor.frame
        scale = plan.monitor.scale
        self.size = size
    }
}

@MainActor
final class NiriCapturedPicture {
    let key: NiriPictureCaptureKey
    var image: CGImage?
    var task: Task<Void, Never>?

    init(key: NiriPictureCaptureKey, image: CGImage? = nil) {
        self.key = key
        self.image = image
    }
}

struct NiriPictureWarmState {
    var isMoving = false
    var capturedThisMotion: Set<WindowToken> = []
    var warmCandidates: Set<WindowToken> = []
    var motionCandidates: Set<WindowToken> = []
}

struct NiriPendingPictureCapture {
    let key: NiriPictureCaptureKey
    let targetFrame: CGRect
}
