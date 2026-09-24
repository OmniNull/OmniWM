// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
enum HiddenBarSettingsEdits {
    static func setEnabled(_ enabled: Bool, apply: (Bool) -> Void) {
        apply(enabled)
    }

    static func setHidden(
        _ hidden: Bool,
        bundleID: String,
        settings: SettingsStore,
        reconcile: () -> Void
    ) {
        var bundleIDs = settings.hiddenBar.hiddenBundleIDs
        if hidden {
            if !bundleIDs.contains(bundleID) {
                bundleIDs.append(bundleID)
            }
        } else {
            bundleIDs.removeAll { $0 == bundleID }
        }
        let normalized = HiddenBarSettingsPolicy.normalizedBundleIDs(bundleIDs)
        guard settings.hiddenBar.hiddenBundleIDs != normalized else { return }
        settings.hiddenBar.hiddenBundleIDs = normalized
        reconcile()
    }

    static func setRehideInterval(_ value: Double, settings: SettingsStore) {
        settings.hiddenBar.rehideIntervalSeconds = HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(value)
    }
}

struct HiddenBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var detectedApps: [DetectedMenuBarApp] = []
    @State private var isDetectingApps = true

    private var rows: [HiddenBarAppRow] {
        var byBundle: [String: HiddenBarAppRow] = [:]
        for app in detectedApps {
            byBundle[app.bundleID] = HiddenBarAppRow(
                bundleID: app.bundleID,
                name: app.name,
                icon: NSRunningApplication(processIdentifier: app.pid)?.icon
            )
        }
        for bundleID in settings.hiddenBar.hiddenBundleIDs where byBundle[bundleID] == nil {
            byBundle[bundleID] = HiddenBarAppRow(
                bundleID: bundleID,
                name: controller.hiddenBarDisplayName(for: bundleID),
                icon: nil
            )
        }
        return byBundle.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Hidden Bar") {
                Toggle("Enable Hidden Bar", isOn: enabledBinding)
                    .disabled(!controller.isHiddenBarHidingAvailable)

                if controller.isHiddenBarHidingAvailable {
                    SettingsCaption(
                        localized: "Hides the selected menu-bar items while enabled. Click an icon in the hidden icons bar to reveal it temporarily."
                    )
                } else {
                    SettingsCaption(localized: "Hiding requires macOS 27 or later.")
                }
            }

            if settings.hiddenBar.enabled {
                appsSection
                    .disabled(!controller.isHiddenBarHidingAvailable)
                panelSection
                    .disabled(!controller.isHiddenBarHidingAvailable)
            }
        }
        .formStyle(.grouped)
        .task {
            isDetectingApps = true
            let apps = await controller.detectMenuBarApps()
            guard !Task.isCancelled else { return }
            detectedApps = apps
            isDetectingApps = false
        }
    }

    private var appsSection: some View {
        Section("Apps to Hide") {
            if isDetectingApps {
                ProgressView("Detecting menu-bar apps…")
            } else if rows.isEmpty {
                SettingsCaption(localized: "No menu-bar apps detected.")
            } else {
                ForEach(rows) { row in
                    Toggle(isOn: binding(for: row.bundleID)) {
                        Label {
                            Text(row.name)
                        } icon: {
                            if let icon = row.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed")
                            }
                        }
                    }
                }
            }
        }
    }

    private var panelSection: some View {
        Section("Hidden Icons Bar") {
            SettingsCaption(
                localized: "Right-click or Option-click the OmniWM menu-bar icon to show the hidden icons below the workspace bar. Click an icon to open its menu."
            )
            SettingsSliderRow(
                label: String(localized: "Rehide Delay"),
                value: rehideIntervalBinding,
                range: 2 ... 30,
                step: 1,
                valueText: String(localized: "\(Int(settings.hiddenBar.rehideIntervalSeconds)) s")
            )
            SettingsCaption(
                localized: "How long a clicked icon stays revealed. The countdown pauses while its menu is open."
            )
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { [settings] in settings.hiddenBar.enabled },
            set: { [controller] enabled in
                HiddenBarSettingsEdits.setEnabled(enabled) {
                    controller.setHiddenBarEnabled($0)
                }
            }
        )
    }

    private var rehideIntervalBinding: Binding<Double> {
        Binding(
            get: { [settings] in settings.hiddenBar.rehideIntervalSeconds },
            set: { [settings] in HiddenBarSettingsEdits.setRehideInterval($0, settings: settings) }
        )
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { [settings, bundleID] in settings.hiddenBar.hiddenBundleIDs.contains(bundleID) },
            set: { [settings, controller, bundleID] isHidden in
                HiddenBarSettingsEdits.setHidden(
                    isHidden,
                    bundleID: bundleID,
                    settings: settings
                ) {
                    controller.updateHiddenBarSettings()
                }
            }
        )
    }
}

private struct HiddenBarAppRow: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?

    var id: String {
        bundleID
    }
}
