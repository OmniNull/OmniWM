// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension WMEvent {
    static func windowAdmitted(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode = .tiling,
        axRef: AXWindowRef,
        ruleEffects: ManagedWindowRuleEffects = .none,
        admissionHints: ManagedWindowAdmissionHints = .none,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory,
        adoptNativeFocus: Bool = false,
        managedReplacementMetadata: ManagedReplacementMetadata? = nil,
        source: WMEventSource
    ) -> WMEvent {
        .windowAdmitted(
            token: token,
            workspaceId: workspaceId,
            monitorId: monitorId,
            mode: mode,
            target: .external(axRef),
            ruleEffects: ruleEffects,
            admissionHints: admissionHints,
            lifetimeAuthority: lifetimeAuthority,
            adoptNativeFocus: adoptNativeFocus,
            managedReplacementMetadata: managedReplacementMetadata,
            source: source
        )
    }
}
