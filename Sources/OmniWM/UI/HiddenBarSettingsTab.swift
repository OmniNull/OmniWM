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
    @State private var editError: String?

    var body: some View {
        Form {
            if let override = settings.hiddenBar.profileOverride {
                Section {
                    Label(
                        String(
                            localized: "Settings are saved for the “\(override.profile)” shell profile."
                        ),
                        systemImage: "paintbrush"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section("Hidden Bar") {
                Button("Reset Hidden Bar to Style Defaults") {
                    Task {
                        do {
                            try await ShellSettingsEdits.reset(
                                table: "hiddenBar",
                                settings: settings,
                                controller: controller
                            )
                        } catch {
                            editError = error.localizedDescription
                        }
                    }
                }
                .id("Reset Hidden Bar to Style Defaults")
                Toggle("Enable Hidden Bar", isOn: enabledBinding)
                    .id("Enable Hidden Bar")
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
                        .id("Open Full Disk Access Settings")
                }
            }
            .id("Hidden Bar")

            if settings.hiddenBar.resolvedEnabled {
                appsSection
                    .disabled(!controller.isHiddenBarHidingAvailable)
                panelSection
                    .disabled(!controller.isHiddenBarHidingAvailable)
            }
        }
        .formStyle(.grouped)
        .shellSettingsError($editError)
        .task(id: settings.hiddenBar.resolvedEnabled) {
            let allowance = controller.hiddenBarSystemSettingsAllowance()
            rows = settings.hiddenBar.resolvedEnabled
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
        .id("Apps to Hide")
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
                valueText: String(localized: "\(Int(settings.hiddenBar.resolvedRehideIntervalSeconds)) s")
            )
            .id("Rehide Delay")
            SettingsCaption(
                localized: "How long a clicked icon stays revealed. The countdown pauses while its menu is open."
            )
        }
        .id("Hidden Icons Bar")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.hiddenBar.resolvedEnabled },
            set: { setProfileValue($0, key: "enabled") }
        )
    }

    private var rehideIntervalBinding: Binding<Double> {
        Binding(
            get: { settings.hiddenBar.resolvedRehideIntervalSeconds },
            set: { setProfileValue(
                HiddenBarSettingsPolicy.validatedRehideIntervalSeconds($0),
                key: "rehideIntervalSeconds"
            ) }
        )
    }

    private func setProfileValue(_ value: some Encodable, key: String) {
        Task {
            do {
                try await ShellSettingsEdits.set(
                    value,
                    key: key,
                    table: "hiddenBar",
                    settings: settings,
                    controller: controller
                )
            } catch {
                editError = error.localizedDescription
            }
        }
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
