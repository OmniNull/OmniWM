// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import OmniWMLauncherSPI
import SwiftUI

struct CommandPaletteView: View {
    private static let compactModeSpacing: CGFloat = 10

    @Bindable var controller: CommandPaletteController
    @Bindable var motionPolicy: MotionPolicy
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            paletteContent(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .defaultFocus($isSearchFocused, true)
        .onChange(of: controller.isVisible, initial: true) { _, isVisible in
            isSearchFocused = isVisible
        }
        .onChange(of: controller.selectedMode) { _, _ in
            if controller.isVisible {
                isSearchFocused = true
            }
        }
        .onChange(of: controller.isExpanded) { _, _ in
            if controller.isVisible {
                isSearchFocused = true
            }
        }
        .onModifierKeysChanged { _, modifiers in
            controller.launcherShowsPaths = modifiers.contains(.command)
        }
    }

    private func paletteContent(width: CGFloat, height: CGFloat) -> some View {
        let searchWidth = controller.isExpanded
            ? width
            : width - CommandPaletteModePicker.compactWidth - Self.compactModeSpacing

        return VStack(spacing: 0) {
            HStack(spacing: controller.isExpanded ? 0 : Self.compactModeSpacing) {
                searchField
                    .frame(width: searchWidth, height: 56)

                if !controller.isExpanded {
                    CommandPaletteModePicker(
                        selectedMode: controller.selectedMode,
                        isMenuModeAvailable: controller.isMenuModeAvailable,
                        onSelect: { controller.selectMode($0) }
                    )
                }
            }
            .frame(width: width, height: 56)

            if controller.isExpanded {
                expandedContent
            }
        }
        .frame(width: width, height: height)
        .background(alignment: .topLeading) {
            Color.clear
                .frame(
                    width: searchWidth,
                    height: controller.isExpanded ? height : 56
                )
                .omniGlassEffect(in: RoundedRectangle(cornerRadius: 28))
        }
        .clipShape(RoundedRectangle(cornerRadius: controller.isExpanded ? 28 : 0))
    }

    @ViewBuilder
    private var expandedContent: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)

        if controller.selectedMode == .windows {
            HStack(spacing: 10) {
                Button(action: { controller.setMarkOnFocusedWindow() }) {
                    Label("Mark focused window…", systemImage: "tag")
                }
                .accessibilityHint(
                    "Marks the managed window focused before opening this Palette. Shortcut Control-Option-M."
                )
                .help("Mark the captured focused window (Control-Option-M)")

                Button(action: { controller.removeMarkFromSelectedWindow() }) {
                    Label("Remove mark…", systemImage: "tag.slash")
                }
                .accessibilityHint(
                    "Choose a mark to remove from the selected window. Shortcut Control-Option-R."
                )
                .help("Choose a mark to remove from the selected window (Control-Option-R)")
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

        if let actionFeedbackText = controller.actionFeedbackText {
            Text(actionFeedbackText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .accessibilityIdentifier("command-palette-mark-feedback")
        }

        if controller.selectedMode == .clipboard,
           let clipboardErrorText = controller.clipboardErrorText
        {
            Label(clipboardErrorText, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }

        if controller.selectedMode == .clipboard && !controller.isClipboardHistoryEnabled {
            CommandPaletteClipboardDisabledView {
                controller.enableClipboardHistory()
            }
        } else if controller.selectedMode == .menu && controller.isMenuLoading {
            CommandPaletteLoadingView(text: String(localized: "Loading menu items..."))
        } else if controller.selectedMode == .applications && controller.isApplicationLoading
            && controller.applicationSections.isEmpty
        {
            CommandPaletteLoadingView(text: String(localized: "Loading applications…"))
        } else if controller.selectedMode == .files && controller.isFileLoading && controller.fileSections.isEmpty {
            CommandPaletteLoadingView(text: String(localized: "Loading files…"))
        } else if isEmptyStateVisible {
            CommandPaletteEmptyStateView(
                symbolName: emptyStateSymbol,
                text: emptyStateText
            )
        } else if controller.selectedMode == .clipboard {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    CommandPaletteResultsView(controller: controller, motionPolicy: motionPolicy)
                        .frame(width: geometry.size.width * 0.55)
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 1)
                    clipboardPreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if controller.isLauncherMode {
            if controller.selectedMode == .files, controller.isLauncherPreviewVisible {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        launcherResults
                            .frame(width: geometry.size.width * 0.55)
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 1)
                        Group {
                            if let item = controller.selectedLauncherFileResult {
                                CommandPaletteLauncherPreviewView(item: item)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                launcherResults
            }
        } else {
            CommandPaletteResultsView(controller: controller, motionPolicy: motionPolicy)
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Group {
                if controller.isExpanded {
                    CommandPaletteModeIcon(mode: controller.selectedMode, pointSize: 18)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.secondary)

            TextField(searchPlaceholder, text: $controller.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($isSearchFocused)

            if !controller.searchText.isEmpty {
                Button(action: { controller.searchText = "" }, label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
            }

            if controller.isExpanded {
                Menu {
                    ForEach(CommandPaletteMode.allCases, id: \.self) { mode in
                        Button(
                            String(
                                localized: "\(mode.localizedDisplayName)  \(CommandPalettePresentation.modeHint(for: mode).shortcut)"
                            )
                        ) {
                            controller.selectMode(mode)
                        }
                        .disabled(mode == .menu && !controller.isMenuModeAvailable)
                    }
                    if controller.selectedMode == .clipboard,
                       controller.isClipboardHistoryEnabled,
                       controller.clipboardItems.contains(where: { !$0.isPinned })
                    {
                        Divider()
                        Button("Clear Unpinned History", systemImage: "trash") {
                            controller.clearClipboardHistory()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Browse modes")
            }
        }
        .padding(.horizontal, 20)
        .help(statusText)
    }

    private var searchPlaceholder: String {
        switch controller.selectedMode {
        case .windows:
            String(localized: "Search windows...")
        case .menu:
            String(localized: "Search menu items...")
        case .clipboard:
            String(localized: "Search clipboard history...")
        case .commands:
            String(localized: "Search OmniWM commands...")
        case .applications:
            String(localized: "Search applications...")
        case .files:
            String(localized: "Search files...")
        }
    }

    private var statusText: String {
        switch controller.selectedMode {
        case .windows:
            CommandPalettePresentation.windowsStatusText(
                selectedItem: selectedWindowItem,
                isSummonRightAvailable: controller.isSummonRightAvailable,
                isCurrentWorkspaceEmpty: controller.isCurrentWorkspaceEmpty
            )
        case .menu:
            controller.menuStatusText
        case .clipboard:
            controller.clipboardStatusText
        case .commands:
            String(localized: "Enter runs the selected command.")
        case .applications:
            String(localized: "Enter opens the selected application.")
        case .files:
            String(localized: "Enter opens the selected file.")
        }
    }

    private var selectedWindowItem: CommandPaletteWindowItem? {
        guard case let .window(token)? = controller.selectedItemID else { return nil }
        return controller.windows.first { $0.id == token }
    }

    private var isEmptyStateVisible: Bool {
        switch controller.selectedMode {
        case .windows:
            controller.filteredWindowItems.isEmpty
        case .menu:
            !controller.isMenuLoading &&
                (!controller.isMenuModeAvailable || controller.filteredMenuItems.isEmpty)
        case .clipboard:
            controller.isClipboardHistoryEnabled && controller.filteredClipboardItems.isEmpty
        case .commands:
            controller.filteredCommandItems.isEmpty
        case .applications,
             .files:
            false
        }
    }

    private var emptyStateSymbol: String {
        switch controller.selectedMode {
        case .windows:
            "macwindow.on.rectangle"
        case .menu:
            controller.isMenuModeAvailable ? "text.magnifyingglass" : "menubar.rectangle"
        case .clipboard:
            "clipboard"
        case .commands:
            "command"
        case .applications:
            "app.fill"
        case .files:
            "folder"
        }
    }

    private var emptyStateText: String {
        switch controller.selectedMode {
        case .windows:
            return controller.searchText.isEmpty
                ? String(localized: "No windows available")
                : String(localized: "No windows found. Check the mark name or try a title, app, or workspace.")
        case .menu:
            if !controller.isMenuModeAvailable {
                return controller.menuStatusText
            }
            return controller.searchText.isEmpty
                ? String(localized: "No menu items available") : String(localized: "No menu items found")
        case .clipboard:
            return controller.searchText.isEmpty
                ? String(localized: "No clipboard items available") : String(localized: "No clipboard items found")
        case .commands:
            return controller.searchText.isEmpty
                ? String(localized: "No commands available") : String(localized: "No commands found")
        case .applications:
            return String(localized: "No applications found")
        case .files:
            return String(localized: "No files found")
        }
    }
}

struct CommandPaletteModePicker: View {
    private static let buttonSize: CGFloat = 44
    private static let buttonSpacing: CGFloat = 8

    static var compactWidth: CGFloat {
        CGFloat(CommandPaletteMode.allCases.count) * buttonSize
            + CGFloat(CommandPaletteMode.allCases.count - 1) * buttonSpacing
    }

    let selectedMode: CommandPaletteMode
    let isMenuModeAvailable: Bool
    let onSelect: (CommandPaletteMode) -> Void

    var body: some View {
        HStack(spacing: Self.buttonSpacing) {
            ForEach(CommandPaletteMode.allCases, id: \.self) { mode in
                modeButton(mode, enabled: mode != .menu || isMenuModeAvailable)
            }
        }
    }

    private func modeButton(_ mode: CommandPaletteMode, enabled: Bool) -> some View {
        let hint = CommandPalettePresentation.modeHint(for: mode)
        let isSelected = selectedMode == mode
        return Button(action: { onSelect(mode) }, label: {
            CommandPaletteModeIcon(mode: mode, pointSize: 20)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isSelected ? 0.12 : 0))
                        .omniGlassEffect(in: Circle())
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(isSelected ? 0.16 : 0.08),
                            lineWidth: 1
                        )
                }
                .opacity(enabled ? 1 : 0.38)
        })
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(String(localized: "\(hint.title) (\(hint.shortcut))"))
        .accessibilityLabel(hint.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CommandPaletteModeIcon: View {
    @MainActor private static let applicationImage = omniwm_launcher_private_symbol("appstore")

    let mode: CommandPaletteMode
    let pointSize: CGFloat

    var body: some View {
        if mode == .applications, let image = Self.applicationImage {
            Image(nsImage: image.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) ?? image)
                .renderingMode(.template)
        } else {
            Image(systemName: symbolName)
        }
    }

    private var symbolName: String {
        switch mode {
        case .windows: "macwindow.on.rectangle"
        case .menu: "menubar.rectangle"
        case .clipboard: "clipboard"
        case .commands: "command"
        case .applications: "square.grid.3x3"
        case .files: "folder"
        }
    }
}

struct CommandPaletteShortcutBadge: View {
    let text: String
    var prominent = false
    var enabled = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
    }

    private var foregroundColor: Color {
        enabled ? (prominent ? .primary : .secondary) : .secondary
    }

    private var backgroundColor: Color {
        prominent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)
    }

    private var borderColor: Color {
        prominent ? Color.accentColor.opacity(0.22) : Color.clear
    }
}

struct CommandPaletteLoadingView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.85)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CommandPaletteEmptyStateView: View {
    let symbolName: String
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Image(systemName: symbolName)
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CommandPaletteClipboardDisabledView: View {
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("Clipboard history is off")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Button(action: onEnable) {
                Label("Enable", systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
