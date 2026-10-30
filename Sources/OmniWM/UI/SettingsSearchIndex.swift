// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SettingsSearchEntry: Identifiable {
    let title: String
    let route: SettingsRoute
    var keywords: [String] = []
    var id: String {
        "\(route.section.rawValue).\(route.tab ?? "").\(route.anchor ?? "").\(route.itemID ?? "").\(title)"
    }

    var context: String {
        [route.section.displayName, route.tab.map(SettingsSearchIndex.tabTitle)].compactMap { $0 }
            .joined(separator: " › ")
    }
}

enum SettingsSearchIndex {
    static func results(for query: String) -> [SettingsSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let text = ([entry.title, entry.context] + entry.keywords).joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    static let entries: [SettingsSearchEntry] = SettingsSection.allCases.map { section in
        SettingsSearchEntry(
            title: section.displayName,
            route: SettingsRoute(section: section),
            keywords: aliases(for: section)
        )
    } + settings + networkSettings

    private static func setting(
        _ title: LocalizedStringResource,
        section: SettingsSection,
        tab: String? = nil,
        anchor: String? = nil,
        itemID: String? = nil
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: title),
            route: SettingsRoute(section: section, tab: tab, anchor: anchor, itemID: itemID)
        )
    }

    private static let settings: [SettingsSearchEntry] = [
        setting("Saved Entries", section: .launcher),
        setting("App Folders", section: .launcher, anchor: "launcher-discovery"),
        setting("Extra CLI Folders", section: .launcher, anchor: "launcher-discovery"),
        setting("Custom Shell Executable", section: .launcher, anchor: "launcher-discovery"),
        setting("Execution Defaults", section: .launcher, anchor: "launcher-execution"),
        setting("Shell", section: .launcher, anchor: "launcher-execution"),
        setting("Terminal", section: .launcher, anchor: "launcher-execution"),
        setting("Language", section: .general, anchor: "Language"),
        setting("App Language", section: .general, anchor: "App Language"),
        setting("Startup", section: .general, anchor: "Startup"),
        setting("Start at Login", section: .general, anchor: "Start at Login"),
        setting("Open Login Items Settings...", section: .general, anchor: "Open Login Items Settings..."),
        setting("Updates", section: .general, anchor: "Updates"),
        setting("Check for Updates Automatically", section: .general, anchor: "Check for Updates Automatically"),
        setting("Check for Updates...", section: .general, anchor: "Check for Updates..."),
        setting("Appearance", section: .appearance, tab: "app", anchor: "Appearance"),
        setting("App Appearance", section: .appearance, tab: "app", anchor: "App Appearance"),
        setting("Show app icons in tab rails", section: .appearance, tab: "app", anchor: "Show app icons in tab rails"),
        setting("Enable Animations", section: .appearance, tab: "app", anchor: "Enable Animations"),
        setting("Tiling Animation Speed", section: .appearance, tab: "app", anchor: "Tiling Animation Speed"),
        setting("Window Borders", section: .appearance, tab: "borders", anchor: "Window Borders"),
        setting("Enable Borders", section: .appearance, tab: "borders", anchor: "Enable Borders"),
        setting("Border Width", section: .appearance, tab: "borders", anchor: "Border Width"),
        setting("Border Color", section: .appearance, tab: "borders", anchor: "Border Color"),
        setting("Gradient Border", section: .appearance, tab: "borders", anchor: "Gradient Border"),
        setting("Gradient Direction", section: .appearance, tab: "borders", anchor: "Gradient Direction"),
        setting("Gradient Start", section: .appearance, tab: "borders", anchor: "Gradient Start"),
        setting("Gradient End", section: .appearance, tab: "borders", anchor: "Gradient End"),
        setting("Glow", section: .appearance, tab: "borders", anchor: "Glow"),
        setting("Glow Radius", section: .appearance, tab: "borders", anchor: "Glow Radius"),
        setting("Glow Opacity", section: .appearance, tab: "borders", anchor: "Glow Opacity"),
        setting("About", section: .appearance, tab: "borders", anchor: "About"),
        setting("Reset", section: .appearance, tab: "borders", anchor: "Reset"),
        setting("Customize", section: .appearance, tab: "borders", anchor: "Customize"),
        setting("Status Bar", section: .menuBar, tab: "status", anchor: "Status Bar"),
        setting("Show Workspace", section: .menuBar, tab: "status", anchor: "Show Workspace"),
        setting("Use Workspace Number", section: .menuBar, tab: "status", anchor: "Use Workspace Number"),
        setting("Show Focused App", section: .menuBar, tab: "status", anchor: "Show Focused App"),
        setting("Show Menu Bar Icon", section: .menuBar, tab: "status", anchor: "Show Menu Bar Icon"),
        setting("Hidden Bar", section: .menuBar, tab: "hidden", anchor: "Hidden Bar"),
        setting("Reset to Style Defaults", section: .menuBar, tab: "hidden", anchor: "Hidden Bar"),
        setting("Enable Hidden Bar", section: .menuBar, tab: "hidden", anchor: "Enable Hidden Bar"),
        setting(
            "Open Full Disk Access Settings",
            section: .menuBar,
            tab: "hidden",
            anchor: "Open Full Disk Access Settings"
        ),
        setting("Apps to Hide", section: .menuBar, tab: "hidden", anchor: "Apps to Hide"),
        setting("Hidden Icons Bar", section: .menuBar, tab: "hidden", anchor: "Hidden Icons Bar"),
        setting("Rehide Delay", section: .menuBar, tab: "hidden", anchor: "Rehide Delay"),
        setting("Layout", section: .layouts, tab: "spacing", anchor: "Layout"),
        setting("Inner Gaps", section: .layouts, tab: "spacing", anchor: "Inner Gaps"),
        setting("Outer Margins", section: .layouts, tab: "spacing", anchor: "Outer Margins"),
        setting("Left", section: .layouts, tab: "spacing", anchor: "Left"),
        setting("Right", section: .layouts, tab: "spacing", anchor: "Right"),
        setting("Top", section: .layouts, tab: "spacing", anchor: "Top"),
        setting("Bottom", section: .layouts, tab: "spacing", anchor: "Bottom"),
        setting("Keep Outer Margins in Full Screen", section: .layouts, tab: "spacing", anchor: "Outer Margins"),
        setting("Niri Layout", section: .layouts, tab: "niri", anchor: "Niri Layout"),
        setting("Visible Containers", section: .layouts, tab: "niri", anchor: "Visible Containers"),
        setting("Infinite Loop Navigation", section: .layouts, tab: "niri", anchor: "Infinite Loop Navigation"),
        setting("Center Focused Column", section: .layouts, tab: "niri", anchor: "Center Focused Column"),
        setting("Always Center Single Column", section: .layouts, tab: "niri", anchor: "Always Center Single Column"),
        setting("Allow Overscroll", section: .layouts, tab: "niri", anchor: "Allow Overscroll"),
        setting("Overscroll Visible Strip", section: .layouts, tab: "niri", anchor: "Overscroll Visible Strip"),
        setting("Gaps at Screen Edges", section: .layouts, tab: "niri", anchor: "Gaps at Screen Edges"),
        setting(
            "Stack Moved Window Into Adjacent Column",
            section: .layouts,
            tab: "niri",
            anchor: "Stack Moved Window Into Adjacent Column"
        ),
        setting("Single Window", section: .layouts, tab: "niri", anchor: "Niri Layout"),
        setting("Resize Increment", section: .layouts, tab: "niri", anchor: "Resize Increment"),
        setting(
            "Default New Container Primary Span",
            section: .layouts,
            tab: "niri",
            anchor: "Default New Container Primary Span"
        ),
        setting("Span Mode", section: .layouts, tab: "niri", anchor: "Span Mode"),
        setting("Custom Span", section: .layouts, tab: "niri", anchor: "Custom Span"),
        setting(
            "Container Primary Span Presets",
            section: .layouts,
            tab: "niri",
            anchor: "Container Primary Span Presets"
        ),
        setting("Add Preset", section: .layouts, tab: "niri", anchor: "Add Preset"),
        setting("Reset Cycle Presets", section: .layouts, tab: "niri", anchor: "Reset Cycle Presets"),
        setting("Dwindle Layout", section: .layouts, tab: "dwindle", anchor: "Dwindle Layout"),
        setting("Smart Split", section: .layouts, tab: "dwindle", anchor: "Smart Split"),
        setting("Move to Root: Stable", section: .layouts, tab: "dwindle", anchor: "Move to Root: Stable"),
        setting("Default Split Ratio", section: .layouts, tab: "dwindle", anchor: "Default Split Ratio"),
        setting("Split Width Multiplier", section: .layouts, tab: "dwindle", anchor: "Split Width Multiplier"),
        setting("Single Window", section: .layouts, tab: "dwindle", anchor: "Dwindle Layout"),
        setting("Use Global Gap Settings", section: .layouts, tab: "dwindle", anchor: "Use Global Gap Settings"),
        setting("Dwindle Gaps", section: .layouts, tab: "dwindle", anchor: "Dwindle Gaps"),
        setting("Inner Gap", section: .layouts, tab: "dwindle", anchor: "Dwindle Gaps"),
        setting("Default Layout", section: .workspaces, anchor: "Default Layout"),
        setting("Layout Algorithm", section: .workspaces, anchor: "Layout Algorithm"),
        setting("Delete Workspace", section: .workspaces, anchor: "Delete Workspace"),
        setting("Cancel", section: .workspaces, anchor: "Cancel"),
        setting("Display Name (optional)", section: .workspaces, anchor: "Display Name (optional)"),
        setting("Layout", section: .workspaces, anchor: "Layout"),
        setting("Home Monitor", section: .workspaces, anchor: "Home Monitor"),
        setting("macOS Arrangement", section: .monitors, anchor: "macOS Arrangement"),
        setting("OmniWM Routing Arrangement", section: .monitors, anchor: "OmniWM Routing Arrangement"),
        setting("Arrangement", section: .monitors, anchor: "Arrangement"),
        setting(
            "Reset Custom Arrangement to macOS Layout",
            section: .monitors,
            anchor: "Reset Custom Arrangement to macOS Layout"
        ),
        setting("Cross-Monitor Behavior", section: .monitors, tab: "behavior", anchor: "Cross-Monitor Behavior"),
        setting(
            "Focus Across Monitor at Edge",
            section: .monitors,
            tab: "behavior",
            anchor: "Focus Across Monitor at Edge"
        ),
        setting(
            "Move Window Across Monitor at Edge",
            section: .monitors,
            tab: "behavior",
            anchor: "Move Window Across Monitor at Edge"
        ),
        setting("Follow Window to Monitor", section: .monitors, tab: "behavior", anchor: "Follow Window to Monitor"),
        setting(
            "Constrain Cursor to Arrangement",
            section: .monitors,
            tab: "behavior",
            anchor: "Constrain Cursor to Arrangement"
        ),
        setting("Monitor Orientation", section: .monitors, tab: "behavior", anchor: "Monitor Orientation"),
        setting("Orientation Override", section: .monitors, tab: "behavior", anchor: "Orientation Override"),
        setting("Reset to Auto", section: .monitors, tab: "behavior", anchor: "Reset to Auto"),
        setting("Overview", section: .overview, anchor: "Overview"),
        setting("Enable Overview", section: .overview, anchor: "Enable Overview"),
        setting("Layout", section: .overview, anchor: "Layout"),
        setting("Zoom", section: .overview, anchor: "Zoom"),
        setting("Input", section: .overview, anchor: "Input"),
        setting("Invert Scrolling Direction", section: .overview, anchor: "Invert Scrolling Direction"),
        setting("Mouse Wheel Speed", section: .overview, anchor: "Mouse Wheel Speed"),
        setting("Toggle Overview Mouse Button", section: .overview, anchor: "Toggle Overview Mouse Button"),
        setting("Appearance", section: .overview, anchor: "Appearance"),
        setting(
            "Selected Border Matches Focus Border",
            section: .overview,
            anchor: "Selected Border Matches Focus Border"
        ),
        setting("macOS Gestures", section: .mouseTrackpad, tab: "trackpad", anchor: "macOS Gestures"),
        setting("Open Trackpad Settings", section: .mouseTrackpad, tab: "trackpad", anchor: "Open Trackpad Settings"),
        setting("Mouse Move & Resize", section: .mouseTrackpad, tab: "mouse", anchor: "Mouse Move & Resize"),
        setting("Left Mouse Move Modifier", section: .mouseTrackpad, tab: "mouse", anchor: "Left Mouse Move Modifier"),
        setting(
            "Dwindle Group Across Displays",
            section: .mouseTrackpad,
            tab: "mouse",
            anchor: "Dwindle Group Across Displays"
        ),
        setting(
            "Right Mouse Resize Modifier",
            section: .mouseTrackpad,
            tab: "mouse",
            anchor: "Right Mouse Resize Modifier"
        ),
        setting("Resize Preview", section: .mouseTrackpad, tab: "mouse", anchor: "Resize Preview"),
        setting(
            "Keep Native Moves Across Displays",
            section: .mouseTrackpad,
            tab: "mouse",
            anchor: "Keep Native Moves Across Displays"
        ),
        setting("Keep Native Edge Resizes", section: .mouseTrackpad, tab: "mouse", anchor: "Keep Native Edge Resizes"),
        setting("Focus Follows Mouse", section: .mouseTrackpad, tab: "mouse", anchor: "Focus Follows Mouse"),
        setting(
            "Enable Focus Follows Mouse",
            section: .mouseTrackpad,
            tab: "mouse",
            anchor: "Enable Focus Follows Mouse"
        ),
        setting(
            "Raise Window When Focus Follows Mouse",
            section: .mouseTrackpad,
            tab: "mouse",
            anchor: "Raise Window When Focus Follows Mouse"
        ),
        setting("Focus Lock Modifier", section: .mouseTrackpad, tab: "mouse", anchor: "Focus Lock Modifier"),
        setting("Edge navigation interval", section: .mouseTrackpad, tab: "mouse", anchor: "Edge navigation interval"),
        setting("Quake Terminal", section: .quakeTerminal, anchor: "Quake Terminal"),
        setting("Enable Quake Terminal", section: .quakeTerminal, anchor: "Enable Quake Terminal"),
        setting("Terminal", section: .quakeTerminal, anchor: "Terminal"),
        setting("Kitty Placement", section: .quakeTerminal, anchor: "Kitty Placement"),
        setting("Override Kitty Placement", section: .quakeTerminal, anchor: "Override Kitty Placement"),
        setting("Kitty Behavior", section: .quakeTerminal, anchor: "Kitty Behavior"),
        setting("Kitty Appearance", section: .quakeTerminal, anchor: "Kitty Appearance"),
        setting("Override Kitty Opacity", section: .quakeTerminal, anchor: "Override Kitty Opacity"),
        setting("foot Placement", section: .quakeTerminal, anchor: "foot Placement"),
        setting("Override foot Placement", section: .quakeTerminal, anchor: "Override foot Placement"),
        setting("foot Behavior", section: .quakeTerminal, anchor: "foot Behavior"),
        setting("foot Appearance", section: .quakeTerminal, anchor: "foot Appearance"),
        setting("Override foot Opacity", section: .quakeTerminal, anchor: "Override foot Opacity"),
        setting("Dim Screen", section: .quakeTerminal, anchor: "Dim Screen"),
        setting("Position & Size", section: .quakeTerminal, anchor: "Position & Size"),
        setting("Position", section: .quakeTerminal, anchor: "Position"),
        setting("Show On", section: .quakeTerminal, anchor: "Show On"),
        setting("Width", section: .quakeTerminal, anchor: "Width"),
        setting("Height", section: .quakeTerminal, anchor: "Height"),
        setting("Reset to Default Position", section: .quakeTerminal, anchor: "Reset to Default Position"),
        setting("Appearance", section: .quakeTerminal, anchor: "Appearance"),
        setting("Background Effect", section: .quakeTerminal, anchor: "Background Effect"),
        setting("Quake Background Opacity", section: .quakeTerminal, anchor: "Quake Background Opacity"),
        setting("Background Blur", section: .quakeTerminal, anchor: "Background Blur"),
        setting("Behavior", section: .quakeTerminal, anchor: "Behavior"),
        setting("Animation Duration", section: .quakeTerminal, anchor: "Animation Duration"),
        setting("Auto-hide on Focus Loss", section: .quakeTerminal, anchor: "Auto-hide on Focus Loss"),
        setting("About", section: .quakeTerminal, anchor: "About"),
        setting("Controls", section: .hotkeys, anchor: "Controls"),
        setting("System Hyper Trigger", section: .hotkeys, anchor: "System Hyper Trigger"),
        setting("Request Permission", section: .hotkeys, anchor: "Request Permission"),
        setting("Reset to Defaults", section: .hotkeys, anchor: "Reset to Defaults"),
        setting("Shortcuts", section: .hotkeys, anchor: "Shortcuts"),
        setting("Command, shortcut, or scope", section: .hotkeys, anchor: "Command, shortcut, or scope"),
        setting("OK", section: .hotkeys, anchor: "OK"),
        setting("Reset Hotkeys", section: .hotkeys, anchor: "Reset Hotkeys"),
        setting("Cancel", section: .hotkeys, anchor: "Cancel"),
        setting("Report Crash…", section: .diagnostics),
        setting("Copy File", section: .diagnostics),
        setting("Reveal", section: .diagnostics),
        setting("Private-API Capability", section: .diagnostics, anchor: "Private-API Capability"),
        setting("Run Private-API Probe", section: .diagnostics, anchor: "Run Private-API Probe"),
        setting("Record a Problem", section: .diagnostics, anchor: "Record a Problem"),
        setting("Start Recording", section: .diagnostics, anchor: "Start Recording"),
        setting("Stop & Save Recording", section: .diagnostics, anchor: "Stop & Save Recording"),
        setting("Measure Performance", section: .diagnostics, anchor: "Measure Performance"),
        setting("Start Performance Capture", section: .diagnostics, anchor: "Start Performance Capture"),
        setting("Stop & Save Performance Capture", section: .diagnostics, anchor: "Stop & Save Performance Capture"),
        setting("Issue", section: .reportIssue, anchor: "Issue"),
        setting("Title", section: .reportIssue, anchor: "Title"),
        setting("Category", section: .reportIssue, anchor: "Category"),
        setting("Context (optional)", section: .reportIssue, anchor: "Context (optional)"),
        setting("Affected app(s)", section: .reportIssue, anchor: "Affected app(s)"),
        setting("Active layout", section: .reportIssue, anchor: "Active layout"),
        setting("Worked in an earlier version?", section: .reportIssue, anchor: "Worked in an earlier version?"),
        setting("Last working version/build", section: .reportIssue, anchor: "Last working version/build"),
        setting("Rewrite & Format with AI", section: .reportIssue, anchor: "Rewrite & Format with AI"),
        setting("Apply", section: .reportIssue, anchor: "Apply"),
        setting("Dismiss", section: .reportIssue, anchor: "Dismiss"),
        setting("Submit to GitHub", section: .reportIssue, anchor: "Submit to GitHub"),
        setting("Discard Draft", section: .reportIssue, anchor: "Discard Draft"),
        setting("Keep Editing", section: .reportIssue, anchor: "Keep Editing"),
        setting("Show guide", section: .reportIssue, anchor: "Show guide"),
        setting("Report another issue", section: .reportIssue, anchor: "Report another issue"),
        setting("Reveal Log Again", section: .reportIssue, anchor: "Reveal Log Again"),
        setting("Diagnostics recording", section: .reportIssue, anchor: "Diagnostics recording"),
        setting("Stop, Save & Include Recording", section: .reportIssue, anchor: "Stop, Save & Include Recording"),
        setting("Additional evidence", section: .reportIssue, anchor: "Additional evidence"),
        setting("Custom Bar", section: .styles, tab: "lanes"),
        setting("Bar Widgets", section: .styles, tab: "lanes"),
        setting("Position", section: .styles, tab: "placement"),
        setting("Notch Mode", section: .styles, tab: "placement"),
        setting("Bar Thickness", section: .styles, tab: "appearance"),
        setting("Background Opacity", section: .styles, tab: "appearance"),
        setting("Notification Badges", section: .styles, tab: "behavior"),
        setting("Auto-Hide", section: .styles, tab: "behavior"),
        setting("Excluded Apps", section: .styles, tab: "apps"),
        setting("Icon Overrides", section: .styles, tab: "apps"),
        setting("Show Dynamic Island", section: .styles, tab: "island", anchor: "placement"),
        setting("Island Widgets", section: .styles, tab: "island"),
        setting("Component Regions", section: .styles, tab: "island"),
        setting("Island Appearance", section: .styles, tab: "island", anchor: "appearance"),
        setting("Island Interaction", section: .styles, tab: "island", anchor: "interaction"),
        setting("Island Motion", section: .styles, tab: "island", anchor: "interaction"),
        setting("Style Profile", section: .styles),
        setting("Color Palette", section: .styles),
        setting("Wallpaper Colors", section: .styles),
        setting("Clock", section: .styles, itemID: "clock"),
        setting("Weather", section: .styles, itemID: "weather"),
        setting("World Clock", section: .styles, itemID: "world-clock"),
        setting("Volume", section: .styles, itemID: "volume"),
        setting("Drawer", section: .styles, tab: "drawers"),
        setting("Settings File", section: .advanced, anchor: "Configuration Files"),
        setting("Shell Folder", section: .advanced, anchor: "Shell Development"),
        setting("IPC", section: .advanced, anchor: "Automation"),
        setting("Command-Line Tools", section: .advanced, anchor: "Command-Line Tools")
    ]
}

extension SettingsSearchIndex {
    private static let networkSettings: [SettingsSearchEntry] = [
        setting("Widget Network Access", section: .network, anchor: NetworkPermissionsPage.widgetsAnchor),
        setting("Programs", section: .network, anchor: NetworkPermissionsPage.programsAnchor),
        setting("Built-in Services", section: .network, anchor: NetworkPermissionsPage.servicesAnchor),
        setting("Lyrics", section: .network, anchor: NetworkPermissionsPage.servicesAnchor)
    ]

    static func tabTitle(_ tab: String) -> String {
        switch tab {
        case "lanes": String(localized: "Bar Widgets")
        case "island": String(localized: "Dynamic Island")
        case "drawers": String(localized: "Drawers")
        case "placement": String(localized: "Placement")
        case "appearance": String(localized: "Appearance")
        case "behavior": String(localized: "Behavior")
        case "apps": String(localized: "Apps")
        case "status": String(localized: "macOS Status Item")
        case "hidden": String(localized: "Hidden Bar")
        default: tab.capitalized
        }
    }

    private static func aliases(for section: SettingsSection) -> [String] {
        switch section {
        case .general: ["language", "startup", "login", "updates"]
        case .appearance: ["theme", "dark", "light", "animations", "corners", "borders", "glow"]
        case .styles: [
                "shell",
                "profile",
                "preset",
                "palette",
                "theme",
                "wallpaper",
                "custom bar",
                "workspace bar",
                "widgets",
                "widget",
                "clock",
                "calendar",
                "weather",
                "media",
                "volume",
                "drawer",
                "dynamic island",
                "lake",
                "focus ribbon",
                "components"
            ]
        case .menuBar: ["status bar", "hidden bar", "menu bar", "icons"]
        case .network: [
                "permissions",
                "network",
                "internet",
                "privacy",
                "hosts",
                "servers",
                "consent",
                "trust",
                "providers",
                "programs",
                "weather",
                "lyrics",
                "organization",
                "mdm"
            ]
        case .layouts: ["spacing", "gaps", "margins", "niri", "dwindle", "columns", "tiling"]
        case .monitors: ["monitors", "displays", "screens", "routing"]
        case .appRules: ["app rules", "float", "tile", "bundle", "match"]
        case .windowSwitcher: ["alt-tab", "command-tab", "option-tab", "app switcher", "previews"]
        case .hotkeys: ["hotkeys", "keyboard", "shortcuts", "hyper", "commands", "pause", "prefix", "mode key"]
        case .advanced: ["config", "toml", "luau", "ipc", "cli", "terminal"]
        default: [section.rawValue]
        }
    }
}
