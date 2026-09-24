// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct TrackpadGesturesSettingsPanel: View {
    private enum FocusedControl: Hashable {
        case action(GestureAssignmentAction)
        case resolution(String)
    }

    @Bindable var settings: SettingsStore
    let monitors: [Monitor]
    @State private var editor = GestureAssignmentEditor()
    @AccessibilityFocusState private var focusedProposal: GestureAssignmentAction?
    @FocusState private var focusedControl: FocusedControl?

    init(
        settings: SettingsStore,
        monitors: [Monitor],
        editor: GestureAssignmentEditor = GestureAssignmentEditor()
    ) {
        self.settings = settings
        self.monitors = monitors
        _editor = State(initialValue: editor)
    }

    var body: some View {
        Section("Trackpad Gestures") {
            SettingsCaption(
                localized: "Choose fingers for each action. You can configure a gesture before turning it on."
            )
            ForEach(GestureAssignmentAction.allCases) { action in
                gestureRow(action)
            }
        }
        .onChange(of: settings.gestures.export()) { _, _ in refreshProposal() }
        .onChange(of: settings.monitors.orientationOverrides) { _, _ in refreshProposal() }
        .onChange(of: monitors) { _, _ in refreshProposal() }
        .onChange(of: editor.proposal?.edit) { previous, edit in
            focusedProposal = edit?.action
            if let resolution = editor.proposal?.resolutions.first {
                focusedControl = .resolution(resolution.id)
            } else if let previous {
                focusedControl = .action(previous.action)
            }
        }
        sharedControls
    }

    private func gestureRow(_ action: GestureAssignmentAction) -> some View {
        let gestures = settings.gestures.export()
        let enabled = action.isEnabled(in: gestures)
        let conflict = enabled ? nil : GestureAssignmentEditor.conflict(
            enabling: action, settings: settings, monitors: monitors
        )
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                gestureDetails(action)
                    .padding(.top, 8)
            } label: {
                gestureControls(action, needsSetup: conflict != nil)
            }
            .accessibilityLabel("\(action.title) details")
            SettingsCaption(description(for: action))
            if let proposal = editor.proposal, proposal.edit.action == action {
                proposalView(proposal)
            } else if let conflict {
                Label("Off · \(conflict.localizedDescription)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if action.fingerCount(in: gestures) == 2 {
                Label("Two-finger gestures can intercept normal scrolling in apps.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func gestureControls(_ action: GestureAssignmentAction, needsSetup: Bool) -> some View {
        HStack(spacing: 12) {
            Text(action.title)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("\(action.title) fingers", selection: Binding(
                get: { action.fingerCount(in: settings.gestures.export()) },
                set: { submit(action, .fingers($0)) }
            )) {
                ForEach(action.supportedFingerCounts, id: \.self) { fingers in
                    Text("\(fingers) fingers").tag(fingers)
                }
            }
            .labelsHidden()
            .frame(width: 112)
            .accessibilityIdentifier("gesture-\(action.rawValue)-fingers")
            if needsSetup {
                Button("Set Up…") { submit(action, .enabled(true)) }
                    .focused($focusedControl, equals: .action(action))
                    .frame(width: 80, alignment: .trailing)
                    .accessibilityLabel("Set up \(action.title)")
                    .accessibilityHint("Review conflicting assignments and choose which gestures to turn off.")
            } else {
                Toggle("\(action.title)", isOn: Binding(
                    get: { action.isEnabled(in: settings.gestures.export()) },
                    set: { submit(action, .enabled($0)) }
                ))
                .toggleStyle(.switch)
                .focused($focusedControl, equals: .action(action))
                .labelsHidden()
                .frame(width: 80, alignment: .trailing)
                .accessibilityIdentifier("gesture-\(action.rawValue)-enabled")
            }
        }
    }

    private func proposalView(_ proposal: GestureAssignmentProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not applied · \(proposal.edit.summary)", systemImage: "exclamationmark.triangle")
                .fontWeight(.medium)
                .accessibilityFocused($focusedProposal, equals: proposal.edit.action)
            if proposal.refreshed {
                Text("Your settings or displays changed. Review the updated choices before applying.")
            }
            if let conflict = proposal.conflict {
                Text(conflict.localizedDescription)
            }
            ForEach(proposal.resolutions) { resolution in
                VStack(alignment: .leading, spacing: 4) {
                    if !resolution.disabledActions.isEmpty {
                        Text(resolution.title(for: proposal.edit))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        editor.confirm(resolution, settings: settings, monitors: monitors)
                    } label: {
                        Text(proposal.edit.summary)
                    }
                    .accessibilityLabel(resolution.title(for: proposal.edit))
                    .focused($focusedControl, equals: .resolution(resolution.id))
                    if resolution.disablesMouseWheelScrolling {
                        Text("Also turns off modifier + mouse-wheel column scrolling.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("Cancel", action: editor.cancel)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func gestureDetails(_ action: GestureAssignmentAction) -> some View {
        switch action {
        case .columns:
            columnDetails
        case .workspaces:
            Picker("Swipe axis", selection: Binding(
                get: { settings.gestures.workspaceSwipeAxis },
                set: { submit(.workspaces, .workspaceAxis($0)) }
            )) {
                ForEach(WorkspaceSwipeAxis.allCases) { axis in
                    Text(axis.localizedDisplayName).tag(axis)
                }
            }
            SettingsCaption(
                localized: "When sharing fingers with column scrolling in Niri, workspace swipes use the perpendicular direction on each display. The selected axis applies without column scrolling."
            )
        case .overview:
            SettingsCaption(
                localized: "Swipe up to open and down to close. Thumbnails follow your fingers; move past halfway or flick to commit. Lift all fingers between gestures."
            )
        case .move:
            SettingsCaption(
                localized: "Point at a tiled window and drag without clicking. Drop over another window to swap. Movement stays on the starting display; lift your fingers to drop."
            )
        case .resize:
            SettingsCaption(
                localized: "Point at a tiled window and drag without clicking. Resize pulls the nearest movable edges. Lift your fingers to finish."
            )
        }
    }

    private var columnDetails: some View {
        Group {
            SettingsSliderRow(
                label: String(localized: "Scroll sensitivity"),
                value: Bindable(settings.gestures).scrollSensitivity,
                range: 0.1 ... 100.0,
                step: 0.1,
                valueText: String(
                    localized: "\(settings.gestures.scrollSensitivity.formatted(.number.precision(.fractionLength(1))))x"
                )
            )
            Picker("Trackpad scroll style", selection: Bindable(settings.gestures).trackpadScrollStyle) {
                ForEach(TrackpadScrollStyle.allCases) { style in
                    Text(style.localizedDisplayName).tag(style)
                }
            }
            SettingsCaption(settings.gestures.trackpadScrollStyle == .momentum
                ? String(localized: "Free inertial scrolling with rubber-band edges.")
                : String(localized: "Scroll snaps to the nearest column."))
            Picker("Mouse scroll modifier", selection: Bindable(settings.gestures).scrollModifierKey) {
                ForEach(ScrollModifierKey.allCases, id: \.self) { key in
                    Text(key.localizedDisplayName).tag(key)
                }
            }
            SettingsCaption(
                localized: "Hold this modifier and scroll the mouse wheel to scroll columns. Turning off Scroll columns disables both trackpad and modified mouse-wheel column scrolling."
            )
        }
    }

    private var sharedControls: some View {
        Section("Shared Gesture Controls") {
            SettingsSliderRow(
                label: String(localized: "Move & resize sensitivity"),
                value: Bindable(settings.gestures).windowGestureSensitivity,
                range: GestureSettings.windowGestureSensitivityRange,
                step: 0.1,
                valueText: String(
                    localized: "\(settings.gestures.windowGestureSensitivity.formatted(.number.precision(.fractionLength(1))))x"
                )
            )
            SettingsCaption(localized: "At 1.0x, sweeping the whole trackpad travels across the whole screen.")
            Toggle("Invert Direction (Natural)", isOn: Bindable(settings.gestures).invertDirection)
            SettingsCaption(settings.gestures.invertDirection
                ? String(localized: "Affects column scrolling and workspace swipes. Swipe right = scroll right.")
                : String(localized: "Affects column scrolling and workspace swipes. Swipe right = scroll left."))
        }
    }

    private func description(for action: GestureAssignmentAction) -> String {
        switch action {
        case .columns:
            String(localized: "Scroll along the Niri layout direction. Also enables modified mouse-wheel scrolling.")
        case .workspaces:
            if settings.gestures.workspaceSwipeAxisLockedToVertical {
                String(localized: "Switch workspaces under the pointer; perpendicular to column scrolling in Niri.")
            } else {
                String(
                    localized: "Switch workspaces under the pointer with \(settings.gestures.workspaceSwipeAxis.localizedSwipePhrase)."
                )
            }
        case .overview:
            String(localized: "Swipe up to open Overview and down to close it.")
        case .move:
            String(localized: "Drag without clicking to swap tiled windows on the same display.")
        case .resize:
            String(localized: "Drag without clicking to resize the nearest movable window edges.")
        }
    }

    private func submit(_ action: GestureAssignmentAction, _ change: GestureAssignmentEdit.Change) {
        editor.submit(.init(action: action, change: change), settings: settings, monitors: monitors)
    }

    private func refreshProposal() {
        editor.refresh(settings: settings, monitors: monitors)
    }
}
