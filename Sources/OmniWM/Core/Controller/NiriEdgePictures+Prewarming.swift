// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

extension NiriEdgePictures {
    func needsMotionPreparation(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        warmStates[workspaceId]?.isMoving != true
    }

    func preparePictures(_ plan: WorkspaceLayoutPlan, enabled: Bool) {
        guard enabled else {
            releaseWorkspaceCaptures(plan.workspaceId)
            return
        }
        guard !plan.isInteractiveResize, let preparation = plan.diff.picturePreparation else { return }
        var state = warmStates[plan.workspaceId] ?? NiriPictureWarmState()
        if preparation.isSettled {
            state.isMoving = false
            state.capturedThisMotion.removeAll(keepingCapacity: true)
            state.warmCandidates = Set(preparation.warmCandidates.keys)
            state.motionCandidates.removeAll(keepingCapacity: true)
            warmStates[plan.workspaceId] = state
            if !isUnderMemoryPressure { prepareSettledPictures(preparation, plan: plan) }
        } else {
            state.isMoving = true
            state.motionCandidates.formUnion(preparation.motionCandidates.keys)
            let fresh = preparation.motionCandidates.filter { state.capturedThisMotion.insert($0.key).inserted }
            warmStates[plan.workspaceId] = state
            for (token, size) in fresh {
                requestPicture(token, key: NiriPictureCaptureKey(plan: plan, size: size), refresh: true)
            }
        }
        discardUnusedCaptures(in: plan.workspaceId)
    }

    func prepareSettledPictures(_ preparation: NiriPicturePreparation, plan: WorkspaceLayoutPlan) {
        prepareSpareSurfaces()
        for (token, size) in preparation.warmCandidates {
            guard isCaptureEligible(token) else { remove(token)
                continue
            }
            let key = NiriPictureCaptureKey(plan: plan, size: size)
            guard capturedPictures[token]?.key != key else { continue }
            if let change = plan.diff.frameChanges
                .first(where: { $0.token == token && $0.components.contains(.size) })
            {
                discardCapture(token)
                pendingCaptures[token] = NiriPendingPictureCapture(key: key, targetFrame: change.frame)
            } else {
                requestPicture(token, key: key)
            }
        }
    }

    func preparePicture(_ token: WindowToken, picture: Picture, plan: WorkspaceLayoutPlan) {
        guard isCaptureEligible(token) else { remove(token)
            return
        }
        if let captured = capturedPictures[token],
           captured.key.workspaceId == picture.workspaceId, captured.key.displayId == picture.displayId,
           captured.key.displayFrame == picture.displayFrame, captured.key.scale == plan.monitor.scale
        {
            picture.acceptStill(captured.image)
            present(token, picture: picture)
            return
        }
        let size = plan.diff.picturePreparation?.motionCandidates[token]
            ?? plan.diff.picturePreparation?.warmCandidates[token] ?? picture.geometry.frame.size
        requestPicture(token, key: NiriPictureCaptureKey(plan: plan, size: size))
    }

    func requestPicture(_ token: WindowToken, key: NiriPictureCaptureKey, refresh: Bool = false) {
        guard isCaptureEligible(token) else { remove(token)
            return
        }
        let previous = capturedPictures[token]
        if previous?.key == key, !refresh || previous?.task != nil { return }
        previous?.task?.cancel()
        let captured = NiriCapturedPicture(
            key: key, image: previous?.key.hasSameContext(as: key) == true ? previous?.image : nil
        )
        capturedPictures[token] = captured
        pendingCaptures[token] = nil
        if captured.image == nil { readyTokens.remove(token) }
        captured.task = capture(token) { [weak self, weak captured] image in
            guard let self, let captured, capturedPictures[token] === captured else { return }
            captured.task = nil
            guard isCaptureEligible(token), let image else { return }
            captured.image = image
            readyTokens.insert(token)
            guard let picture = pictures[token], picture.workspaceId == key.workspaceId,
                  picture.displayId == key.displayId, picture.displayFrame == key.displayFrame else { return }
            picture.acceptStill(image)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            present(token, picture: picture)
            CATransaction.commit()
        }
        if let image = captured.image, let picture = pictures[token], picture.content?.image !== image {
            picture.acceptStill(image)
            present(token, picture: picture)
        }
    }

    func finishPendingCapture(_ token: WindowToken, targetFrame: CGRect, applied: Bool) {
        guard let pending = pendingCaptures[token], pending.targetFrame == targetFrame else { return }
        pendingCaptures[token] = nil
        guard warmStates[pending.key.workspaceId]?.warmCandidates.contains(token) == true else { return }
        if applied, !isUnderMemoryPressure {
            requestPicture(token, key: pending.key)
        } else if !applied {
            discardCapture(token)
            capturedPictures[token] = NiriCapturedPicture(key: pending.key)
        }
    }

    func retirePicture(_ token: WindowToken) {
        guard let picture = pictures.removeValue(forKey: token) else { return }
        picture.stream?.stop()
        if let surface = picture.surface {
            surface.observeVisibility(nil)
            surface.hide()
            spareSurfaces.append(surface)
            onPresentationChanged()
        }
        if !retainsCapture(token, in: picture.workspaceId) { discardCapture(token) }
        reconcileLiveStreams()
    }

    private func prepareSpareSurfaces() {
        let capacity = warmStates.values.reduce(0) { $0 + $1.warmCandidates.count }
        while spareSurfaces.count > capacity { spareSurfaces.removeLast().destroy() }
        while spareSurfaces.count < capacity { spareSurfaces.append(makeSurface()) }
    }

    func retainsCapture(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let state = warmStates[workspaceId] else { return false }
        return state.warmCandidates.contains(token) || state.motionCandidates.contains(token)
    }

    func discardCapture(_ token: WindowToken) {
        capturedPictures.removeValue(forKey: token)?.task?.cancel()
        readyTokens.remove(token)
    }

    func discardUnusedCaptures(in workspaceId: WorkspaceDescriptor.ID) {
        for (token, captured) in capturedPictures
            where captured.key.workspaceId == workspaceId && pictures[token] == nil
            && !retainsCapture(token, in: workspaceId)
        { discardCapture(token) }
        for (token, pending) in pendingCaptures
            where pending.key.workspaceId == workspaceId && !retainsCapture(token, in: workspaceId)
        { pendingCaptures[token] = nil }
    }

    func releaseWorkspaceCaptures(_ workspaceId: WorkspaceDescriptor.ID) {
        warmStates[workspaceId] = nil
        for (token, captured) in capturedPictures
            where captured.key.workspaceId == workspaceId { discardCapture(token) }
        for (token, pending) in pendingCaptures
            where pending.key.workspaceId == workspaceId { pendingCaptures[token] = nil }
    }

    func handleMemoryPressure(_ underPressure: Bool) {
        isUnderMemoryPressure = underPressure
        reconcileLiveStreams()
        guard underPressure else { return }
        for surface in spareSurfaces { surface.destroy() }
        spareSurfaces.removeAll()
        for token in capturedPictures.keys where pictures[token]?.content == nil { discardCapture(token) }
        for token in pendingCaptures.keys where pictures[token]?.content == nil { pendingCaptures[token] = nil }
    }
}
