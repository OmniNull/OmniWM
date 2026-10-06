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

    static func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct HiddenBarSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController

    @State private var rows: [HiddenBarAppRow] = []

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
                    SettingsCaption(
                        localized: "Hidden Bar requires macOS 27 or later and Full Disk Access. After turning on OmniWM in Full Disk Access, quit and reopen OmniWM."
                    )
                    Button("Open Full Disk Access Settings", action: HiddenBarSettingsEdits.openFullDiskAccessSettings)
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
        .task(id: settings.hiddenBar.enabled) {
            let allowance = controller.hiddenBarSystemSettingsAllowance()
            rows = settings.hiddenBar.enabled
                ? HiddenBarAppRow.rows(allowance: allowance, selected: settings.hiddenBar.hiddenBundleIDs)
                : []
        }
    }

    private var appsSection: some View {
        Section("Apps to Hide") {
            if rows.isEmpty {
                SettingsCaption(localized: "No menu-bar apps detected.")
            } else {
                ForEach(rows) { row in
                    Toggle(isOn: binding(for: row.bundleID)) {
                        Label {
                            Text(row.name)
                            if row.isOffInSystemSettings {
                                Text("Off in System Settings")
                            }
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

struct HiddenBarAppRow: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isOffInSystemSettings: Bool

    var id: String {
        bundleID
    }

    static func rows(
        allowance: [String: Bool],
        selected: [String],
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> [HiddenBarAppRow] {
        Set(allowance.keys).union(selected).compactMap { bundleID -> HiddenBarAppRow? in
            let url = applicationURL(bundleID)
            guard url != nil || selected.contains(bundleID) else { return nil }
            return HiddenBarAppRow(
                bundleID: bundleID,
                name: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                isOffInSystemSettings: allowance[bundleID] == false
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
