// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

struct NiriTopEdgePictureGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    init?(frame: CGRect, displayFrame: CGRect) {
        let visible = frame.intersection(displayFrame)
        guard frame.size.hasFinitePositiveDimensions(), frame.origin.x.isFinite, frame.origin.y.isFinite,
              !visible.isNull, !visible.isEmpty else { return nil }
        self.frame = frame
        visibleFrame = visible
    }

    var pictureFrame: CGRect {
        frame.offsetBy(dx: -visibleFrame.minX, dy: -visibleFrame.minY)
    }
}

@MainActor
protocol NiriTopEdgePictureSurface: AnyObject {
    func update(geometry: NiriTopEdgePictureGeometry, image: CGImage, activate: @escaping @MainActor () -> Void)
    func destroy()
}

@MainActor
final class NiriTopEdgePictures {
    typealias Capture = @MainActor (WindowToken, @escaping @MainActor (CGImage?) -> Void) -> Task<Void, Never>?

    private final class Picture {
        let workspaceId: WorkspaceDescriptor.ID
        let displayId: CGDirectDisplayID
        let displayFrame: CGRect
        var geometry: NiriTopEdgePictureGeometry
        var image: CGImage?
        var task: Task<Void, Never>?
        var surface: (any NiriTopEdgePictureSurface)?
        var revealFrame: CGRect?

        init(
            workspaceId: WorkspaceDescriptor.ID,
            monitor: LayoutMonitorSnapshot,
            geometry: NiriTopEdgePictureGeometry
        ) {
            self.workspaceId = workspaceId
            displayId = monitor.displayId
            displayFrame = monitor.frame
            self.geometry = geometry
        }
    }

    private let capture: Capture
    private let makeSurface: @MainActor () -> any NiriTopEdgePictureSurface
    private let activate: @MainActor (WindowToken, WorkspaceDescriptor.ID) -> Void
    private var pictures: [WindowToken: Picture] = [:]

    init(
        capture: @escaping Capture = NiriTopEdgePictures.captureWindow,
        makeSurface: @escaping @MainActor () -> any NiriTopEdgePictureSurface = { NiriTopEdgePictureWindow() },
        activate: @escaping @MainActor (WindowToken, WorkspaceDescriptor.ID) -> Void
    ) {
        self.capture = capture
        self.makeSurface = makeSurface
        self.activate = activate
    }

    func reconcile(_ plan: WorkspaceLayoutPlan) {
        let enabled = plan.isActiveWorkspace && plan.monitor.orientation == .vertical
        let desired = enabled ? plan.diff.topEdgeHiddenFrames : [:]
        guard !desired.isEmpty || pictures.values.contains(where: { $0.workspaceId == plan.workspaceId })
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (token, picture) in pictures where picture.workspaceId == plan.workspaceId {
            guard enabled, picture.displayId == plan.monitor.displayId,
                  picture.displayFrame == plan.monitor.frame
            else { remove(token)
                continue
            }
            if desired[token] != nil { continue }
            guard let change = plan.diff.frameChanges.first(where: { $0.token == token }),
                  let geometry = NiriTopEdgePictureGeometry(frame: change.frame, displayFrame: plan.monitor.frame)
            else { remove(token)
                continue
            }
            picture.revealFrame = change.frame
            picture.geometry = geometry
            present(token, picture: picture)
        }
        for (token, frame) in desired {
            guard let geometry = NiriTopEdgePictureGeometry(frame: frame, displayFrame: plan.monitor.frame)
            else { remove(token)
                continue
            }
            if let picture = pictures[token] {
                if picture.workspaceId != plan.workspaceId {
                    remove(token)
                } else {
                    picture.revealFrame = nil
                    picture.geometry = geometry
                    present(token, picture: picture)
                    continue
                }
            }
            let picture = Picture(workspaceId: plan.workspaceId, monitor: plan.monitor, geometry: geometry)
            pictures[token] = picture
            picture.task = capture(token) { [weak self, weak picture] image in
                guard let self, let picture, pictures[token] === picture else { return }
                picture.task = nil
                picture.image = image
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                present(token, picture: picture)
                CATransaction.commit()
            }
        }
    }

    func frameApplicationEnded(token: WindowToken, targetFrame: CGRect) {
        guard let picture = pictures[token], picture.revealFrame == targetFrame else { return }
        remove(token)
    }

    func retainCurrentContexts(
        _ isCurrent: (WindowToken, WorkspaceDescriptor.ID, CGDirectDisplayID, CGRect) -> Bool
    ) {
        for (token, picture) in pictures
            where !isCurrent(token, picture.workspaceId, picture.displayId, picture.displayFrame)
        {
            remove(token)
        }
    }

    func retainWorkspaces(_ workspaceIds: Set<WorkspaceDescriptor.ID>) {
        for (token, picture) in pictures where !workspaceIds.contains(picture.workspaceId) {
            remove(token)
        }
    }

    func remove(_ token: WindowToken) {
        guard let picture = pictures.removeValue(forKey: token) else { return }
        picture.task?.cancel()
        picture.surface?.destroy()
    }

    func reset() {
        for token in pictures.keys { remove(token) }
    }

    private func present(_ token: WindowToken, picture: Picture) {
        guard let image = picture.image else { return }
        if picture.surface == nil { picture.surface = makeSurface() }
        picture.surface?.update(geometry: picture.geometry, image: image) { [weak self, weak picture] in
            guard let self, let picture, pictures[token] === picture else { return }
            activate(token, picture.workspaceId)
        }
    }

    static func captureWindow(
        _ token: WindowToken,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) -> Task<Void, Never>? {
        guard ScreenCapturePermissionMonitor.shared.isGranted else { completion(nil)
            return nil
        }
        return Task {
            let image = try? await SkyLight.shared.windowPictureDeferred(for: token)
            guard !Task.isCancelled else { return }
            completion(image)
        }
    }
}

extension WMController {
    func makeTopEdgePictures() -> NiriTopEdgePictures {
        NiriTopEdgePictures(
            makeSurface: { [weak self] in
                NiriTopEdgePictureWindow(orderBelowWindowId: self?.workspaceManager.nativeManagedFocusToken?.windowId)
            },
            activate: { [weak self] in self?.activateTopEdgePicture($0, in: $1) }
        )
    }

    func pruneTopEdgePictures() {
        niriTopEdgePictures.retainCurrentContexts { token, workspaceId, displayId, displayFrame in
            guard let monitor = workspaceManager.monitor(for: workspaceId),
                  monitor.displayId == displayId, monitor.frame == displayFrame,
                  settings.monitors.effectiveOrientation(for: monitor) == .vertical,
                  workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId,
                  workspaceManager.entry(for: token)?.workspaceId == workspaceId,
                  workspaceManager.layoutReason(for: token) != .nativeFullscreen
            else { return false }
            return true
        }
    }

    func activateTopEdgePicture(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) {
        guard let node = niriEngine?.findNode(for: token, in: workspaceId),
              let monitor = workspaceManager.monitor(for: workspaceId),
              workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
        else { return }
        var state = workspaceManager.niriViewportState(for: workspaceId)
        niriLayoutHandler.activateNode(
            node, in: workspaceId, state: &state,
            options: NodeActivationOptions(focusOrigin: .pointerSelection)
        )
        workspaceManager.applySessionPatch(
            .init(workspaceId: workspaceId, viewportState: state, rememberedFocusToken: nil)
        )
    }
}
