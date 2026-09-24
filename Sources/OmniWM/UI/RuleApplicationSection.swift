// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct RuleApplicationSection: View {
    @Binding var draft: AppRuleDraft
    let controller: WMController

    @State private var runningApps: [RunningAppInfo] = []
    @State private var isPickerPresented = false
    @State private var selectedAppId: RunningAppInfo.ID?

    var body: some View {
        Section("Application") {
            TextField("Bundle ID", text: $draft.bundleId)
                .textFieldStyle(.roundedBorder)
            if let error = draft.bundleIdError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Pick from running apps") {
                refreshRunningApps()
                isPickerPresented = true
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running Apps")
                        .font(.headline)

                    if runningApps.isEmpty {
                        SettingsCaption(localized: "No running apps found")
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(runningApps) { app in
                                    Button {
                                        selectApp(app)
                                    } label: {
                                        RunningAppRow(app: app)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 280)
                        .scrollIndicators(.visible)
                    }
                }
                .padding(12)
                .frame(width: 420)
                .onExitCommand {
                    isPickerPresented = false
                }
            }

            if let windowSize = selectedAppInfo?.trackedWindowSize {
                Button {
                    useCurrentWindowSize(windowSize)
                } label: {
                    Label(
                        "Use current size: \(Int(windowSize.width)) × \(Int(windowSize.height)) px",
                        systemImage: "arrow.down.doc"
                    )
                }
                .buttonStyle(.bordered)
            }

            Toggle("Also match by app name", isOn: $draft.appNameMatcherEnabled)
            if draft.appNameMatcherEnabled {
                TextField("App name contains, e.g. Preview", text: $draft.appNameSubstring)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsCaption(
                localized: "Bundle ID is the app's runtime identifier (e.g. com.apple.finder). Some apps have none — leave it blank and match by app name or title instead. A codesign identifier won't match."
            )

            if let identifierHint = draft.identifierHint {
                Text(identifierHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var selectedAppInfo: RunningAppInfo? {
        selectedAppId.flatMap { selectedAppId in
            runningApps.first { $0.id == selectedAppId }
        }
    }

    private func selectApp(_ app: RunningAppInfo) {
        selectedAppId = app.id
        draft.selectApplication(bundleId: app.bundleId, appName: app.appName)
        isPickerPresented = false
    }

    private func refreshRunningApps() {
        runningApps = controller.runningAppsForRulePicker()
    }

    private func useCurrentWindowSize(_ size: CGSize) {
        draft.minWidth = size.width
        draft.minHeight = size.height
        draft.minWidthEnabled = true
        draft.minHeightEnabled = true
    }
}

private struct RunningAppRow: View {
    let app: RunningAppInfo

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app")
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(app.bundleId ?? String(localized: "No bundle ID"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let windowSize = app.trackedWindowSize {
                Text("\(Int(windowSize.width))×\(Int(windowSize.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(app.appName), \(app.bundleId ?? String(localized: "no bundle ID"))"))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let windowSize = app.trackedWindowSize else {
            return String(localized: "Running application")
        }
        return String(localized: "\(Int(windowSize.width)) by \(Int(windowSize.height)) pixels")
    }
}
