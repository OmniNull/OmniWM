// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WMController {
    func observePictureCaptureState(
        _ pictures: NiriEdgePictures,
        permission: ScreenCapturePermissionMonitor = .shared
    ) {
        let previews = PreviewCaptureCoordinator.shared
        let permissionObserver = permission.addChangeObserver { [weak self, weak pictures] granted in
            pictures?.reset()
            guard let self else { return }
            workspaceManager.withEngineMutationScope {
                niriEngine?.edgePicturesAvailable = granted
            }
            let workspaces = Set(workspaceManager.monitors.compactMap { monitor -> WorkspaceDescriptor.ID? in
                guard settings.monitors.effectiveOrientation(for: monitor) == .vertical else { return nil }
                return workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
            })
            guard !workspaces.isEmpty else { return }
            layoutRefreshController.requestRelayout(reason: .layoutConfigChanged, affectedWorkspaceIds: workspaces)
        }
        pictures.handleMemoryPressure(previews.isUnderMemoryPressure)
        let pressureObserver = previews.addMemoryPressureObserver { [weak pictures] underPressure in
            pictures?.handleMemoryPressure(underPressure)
        }
        pictures.removeCaptureObservers = {
            permission.removeChangeObserver(permissionObserver)
            previews.removeMemoryPressureObserver(pressureObserver)
        }
    }
}
