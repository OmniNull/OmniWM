// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

enum ShellPlacement: Sendable {
    case bar
    case island
}

struct ShellBarKey: Hashable, Sendable {
    let monitor: Monitor.ID
    var island = WorkspaceBarIslandSlice.all
    var placement = ShellPlacement.bar
}

struct ShellCommandOrigin {
    let monitor: Monitor.ID
    var anchor: ShellAnchor?
    var event = ShellEvent()
    var widget: String?
    var command: String?
}

enum ShellRequest: Equatable, Sendable {
    static let statusMenuCommand = "shell menu"

    case command(IPCCommandRequest)
    case window(IPCWindowRequest)
    case statusMenu
    case menu(MenuContent)
    case moveFocusedWindow(target: String)
    case hiddenBarActivate(item: String)

    init?(words: [String]) {
        if words == ["shell", "menu"] {
            self = .statusMenu
        } else if words == ["menu", "apple"] {
            self = .menu(.apple)
        } else if words == ["menu", "app"] {
            self = .menu(.application)
        } else if words.count == 3, words[0] == "hidden-bar", words[1] == "activate" {
            self = .hiddenBarActivate(item: words[2])
        } else if words.first == "window" {
            guard let request = IPCWindowRequest(actionWords: Array(words.dropFirst())) else { return nil }
            self = .window(request)
        } else {
            guard let request = IPCCommandRequest(commandWords: words) else { return nil }
            self = .command(request)
        }
    }
}

extension ShellRequest {
    var isHiddenBarActivation: Bool {
        if case .hiddenBarActivate = self { true } else { false }
    }
}

enum ShellSettingsPane: String, Sendable {
    case battery
    case inputSource = "input-source"
    case wifi
    case bluetooth

    var url: URL? {
        let pane = switch self {
        case .battery: "com.apple.Battery-Settings.extension"
        case .inputSource: "com.apple.Keyboard-Settings.extension"
        case .wifi: "com.apple.wifi-settings-extension"
        case .bluetooth: "com.apple.BluetoothSettings"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")
    }
}

enum ShellAction: Equatable, Sendable {
    case wm(ShellRequest)
    case volume(ShellVolumeCommand)
    case media(ShellMediaCommand)
    case calendar(ShellCalendarCommand)
    case reminders(ShellRemindersCommand)
    case inputSource(ShellInputSourceCommand)
    case wifi(ShellWiFiCommand)
    case bluetooth(ShellBluetoothCommand)
    case session(ShellSessionCommand)
    case settings(ShellSettingsPane)
    case toggle(widget: String)

    private static let domains: [String: @Sendable ([String]) -> ShellAction?] = [
        "volume": { ShellVolumeCommand(words: $0).map(ShellAction.volume) },
        "media": { ShellMediaCommand(words: $0).map(ShellAction.media) },
        "calendar": { ShellCalendarCommand(words: $0).map(ShellAction.calendar) },
        "reminders": { ShellRemindersCommand(words: $0).map(ShellAction.reminders) },
        "input-source": { ShellInputSourceCommand(words: $0).map(ShellAction.inputSource) },
        "wifi": { ShellWiFiCommand(words: $0).map(ShellAction.wifi) },
        "bluetooth": { ShellBluetoothCommand(words: $0).map(ShellAction.bluetooth) },
        "session": { ShellSessionCommand(words: $0).map(ShellAction.session) }
    ]

    init?(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 3, words[0] == "shell", words[1] == "toggle" {
            self = .toggle(widget: words[2])
        } else if words.count == 2, words[1] == "settings", let pane = ShellSettingsPane(rawValue: words[0]) {
            self = .settings(pane)
        } else if let parse = words.first.flatMap({ Self.domains[$0] }) {
            guard let action = parse(Array(words.dropFirst())) else { return nil }
            self = action
        } else {
            guard let request = ShellRequest(words: words) else { return nil }
            self = .wm(request)
        }
    }
}

struct ShellMenuRequest {
    let monitor: Monitor.ID
    let target: String
    let anchor: ShellAnchor
    var label: CGRect?
    let view: NSView
}

struct ShellWidgetMenuRequest {
    let widget: String
    let monitor: Monitor.ID
    let anchor: ShellAnchor
    let view: NSView
}

struct ShellPreviewRequest {
    let monitor: Monitor.ID
    let target: String?
    let anchor: CGRect?
}

enum ShellDragRequest {
    case began(monitor: Monitor.ID, target: String, at: CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
}

struct ShellDropTarget: Equatable {
    let target: String
    let frame: CGRect
    let drop: Bool
}

@MainActor
final class ShellWidgetHost {
    static let failureLimit = 5

    struct Trip {
        let source: URL
        let fingerprint: [String: SettingsFileAccess.Fingerprint]
        let failure: ShellScriptFailure
    }

    @MainActor
    final class InstanceState {
        var nodes: [UInt8] = []
        private(set) var unmountedLayout: ShellWidgetLayout?
        var size: CGSize = .zero
        var sequences = InlineArray<2, Int>(repeating: 0)
        var deps: UInt64 = 0
        var popoutDeps: UInt64 = 0
        var surface: ShellWidgetSurface? {
            didSet {
                if surface != nil {
                    unmountedLayout = nil
                }
            }
        }

        func apply(_ tree: ShellWidgetDelivery.Tree, text: ShellTextStore, gestureAcknowledgement: UInt64 = 0) -> Bool {
            nodes = tree.nodes
            deps = tree.demand
            let nextSize: CGSize
            if let surface {
                surface.sequence = tree.sequence
                guard surface.apply(tree.nodes, text: text, gestureAcknowledgement: gestureAcknowledgement)
                else { return false }
                nextSize = surface.size
            } else {
                let layout = unmountedLayout ?? ShellWidgetLayout()
                unmountedLayout = layout
                guard layout.apply(tree.nodes, text: text) else { return false }
                nextSize = layout.size
            }
            sequences[ShellWidgetView.bar.rawValue] = tree.sequence
            guard nextSize != size else { return false }
            size = nextSize
            return true
        }

        func redraw(text: ShellTextStore) {
            guard !nodes.isEmpty, let surface else { return }
            surface.reset(text: text)
            surface.sequence = sequences[ShellWidgetView.bar.rawValue]
            surface.apply(nodes, text: text)
        }

        func reset(text: ShellTextStore) {
            if let surface {
                surface.reset(text: text)
            } else {
                unmountedLayout?.reset()
            }
        }
    }

    @MainActor
    final class WidgetState {
        let name: String
        let sourceURL: URL
        var package: ShellWidgetPackage?
        var loadingPackage: ShellWidgetPackage?
        var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
        var generation = 0
        var loadingGeneration = 0
        var renderedGeneration = 0
        var renderedEpoch = 0
        var fingerprint: [String: SettingsFileAccess.Fingerprint] = [:]
        var text = ShellTextStore()
        var instances: [ShellBarKey: InstanceState] = [:]
        var lastFailure: ShellScriptFailure?
        var fallback: ShellScriptFailure?
        var failures = 0
        var failedDeps: UInt64 = 0
        var backgroundDemand: UInt64 = 0
        var declaration = ShellWidgetDeclaration()
        var assetPackages: [String: URL] = [:]
        var componentDescriptors: [ShellComponentDescriptor] = []

        init(name: String, sourceURL: URL) {
            self.name = name
            self.sourceURL = sourceURL
        }
    }

    let shellDirectory: URL
    let widgetsDirectory: URL
    let resources: ShellResources
    let resourceStore: ShellResourceStore
    lazy var desktopServices = ShellDesktopServices(resources: resourceStore)
    lazy var dropIngress = ShellDropIngress(resources: resourceStore)
    let focusPolicyEngine: FocusPolicyEngine?
    let sessionToken: String
    var config = ShellConfig()
    let configurationCatalogLoader = ShellConfigurationCatalogLoader()
    var configurationCatalog: ShellConfigurationCatalog?
    var configurationCatalogError: String?
    var configurationCatalogRevision = 0
    var configurationCatalogLoading: Int?
    let configurationCoordinator: ShellConfigurationCoordinator
    let ownsConfigurationCoordinator: Bool
    var configurationWriter: ShellIslandConfigWriter? {
        get { configurationCoordinator.writer }
        set { configurationCoordinator.writer = newValue }
    }

    var pendingConfigurationEdits: [ConfigurationSubmission] = []
    var configurationProcessing = false
    var configurationWorkCount = 0
    var configurationEpoch = 0
    let world: @MainActor () -> ShellWorldData
    let vars: @MainActor () -> [String: String]
    let barData: @MainActor () -> [ShellBarKey: ShellBarData]
    let onLayoutChange: @MainActor () -> Void
    let onCommand: @MainActor (ShellRequest, ShellCommandOrigin) -> Void
    let onMenu: @MainActor (ShellMenuRequest) -> Void
    let onPreview: @MainActor (ShellPreviewRequest) -> Void
    let onDrag: @MainActor (ShellDragRequest) -> Void
    let onPopoutChange: @MainActor () -> Void
    let onTitleDemandChange: @MainActor (Bool) -> Void
    var demandsWindowTitles = false
    var layoutGeneration: UInt64 = 0
    var widgets: [String: WidgetState] = [:]
    var trips: [String: Trip] = [:]
    var started = false
    var locked = false
    var displaysAsleep = false
    var nextGeneration = 0
    static var retiringTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    static var traceRetiringTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    static var sealedTraceCapture: UInt64 = 0
    var traceCaptureContext: ShellFrameTraceContext?
    var traceImagesBegin: Task<Void, Never>?
    var feed: ShellDataFeed?
    var observation: ShellDirectoryObservation?
    var wallpaperPalette: ShellWallpaperPaletteWriter?
    var systemColorsObserver: NSObjectProtocol?
    var powerStateObserver: NSObjectProtocol?
    var displaySleepObservers: [NSObjectProtocol] = []
    var watchedPaths: [URL] = []
    var barColors: (accent: SettingsColor?, foreground: SettingsColor?) = (nil, nil)
    let latestData = ShellLatestWidgetData()
    var outbox: ShellWidgetOutbox?
    var bars: [ShellBarKey: ShellBarData] = [:]
    var barShaderViews: [ShellBarKey: ShellBarShaderView] = [:]
    var desiredIslands: [DesiredIslandSurface] = []
    var islandData: [ShellBarKey: ShellBarData] = [:]
    var pickerFocus: ShellPickerFocus?
    weak var focusedSurface: ShellWidgetSurface?
    weak var focusedWindow: NSWindow?
    var focusedWindowSuppression: Bool?
    weak var shellPreviousKeyWindow: NSWindow?
    weak var shellPreviousFirstResponder: NSResponder?
    var islandInputMonitors: [Any]?
    var islandInputGeneration = 0
    var islandDragMonitor: ShellIslandDragMonitor?
    var islandWindows: [Monitor.ID: ShellIsland] = [:]
    var islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    var placedSlots: [Monitor.ID: [WorkspaceBarShellWidget]] = [:]
    var popout: ShellPopout?
    var hiddenBarMenu: ShellHiddenBarMenu?
    var onHiddenBarMenuClose: (@MainActor () -> Void)?
    var closingPopout: ShellPopout?
    var drawer: ShellEdgeDrawer?
    var closingDrawer: ShellEdgeDrawer?
    var drawerKeys: [String: ShellBarKey] = [:]
    var onBadgesDemandChange: (@MainActor (Bool) -> Void)?
    var onConfigChange: (@MainActor (ShellConfig) -> Void)?
    var onWidgetMenu: (@MainActor (ShellWidgetMenuRequest) -> Void)?
    var onToggleNamesChange: (@MainActor () -> Void)?
    var onWidgetsChange: (@MainActor () -> Void)?
    var publishedToggleNames: [String] = []
    var publishedReport: IPCShellWidgetsQueryResult?
    var configProblems: [String] = []
    var reportedMissing: Set<String> = []
    var ownWidgets: Set<String> = []
    var headless: (widget: String, key: ShellBarKey)?
    private(set) lazy var tooltip = ShellTooltip()

    init(
        configDirectory: URL,
        configurationCoordinator: ShellConfigurationCoordinator? = nil,
        resources: ShellResources,
        resourceStore: ShellResourceStore? = nil,
        focusPolicyEngine: FocusPolicyEngine? = nil,
        sessionToken: String = "",
        world: @escaping @MainActor () -> ShellWorldData,
        vars: @escaping @MainActor () -> [String: String],
        bars: @escaping @MainActor () -> [ShellBarKey: ShellBarData],
        onLayoutChange: @escaping @MainActor () -> Void,
        onCommand: @escaping @MainActor (ShellRequest, ShellCommandOrigin) -> Void,
        onMenu: @escaping @MainActor (ShellMenuRequest) -> Void,
        onPreview: @escaping @MainActor (ShellPreviewRequest) -> Void,
        onDrag: @escaping @MainActor (ShellDragRequest) -> Void,
        onPopoutChange: @escaping @MainActor () -> Void,
        onTitleDemandChange: @escaping @MainActor (Bool) -> Void
    ) {
        shellDirectory = Self.shellDirectory(in: configDirectory)
        ownsConfigurationCoordinator = configurationCoordinator == nil
        self.configurationCoordinator = configurationCoordinator ?? ShellConfigurationCoordinator(
            shellDirectory: Self.shellDirectory(in: configDirectory)
        )
        widgetsDirectory = shellDirectory.appendingPathComponent("widgets", isDirectory: true)
        self.resources = resources
        self
            .resourceStore = resourceStore ??
            ShellResourceStore(directory: OmniWMStoragePaths.live.stateDirectory.appendingPathComponent(
                "shell-resources",
                isDirectory: true
            ))
        self.focusPolicyEngine = focusPolicyEngine
        self.sessionToken = sessionToken
        self.world = world
        self.vars = vars
        barData = bars
        self.onLayoutChange = onLayoutChange
        self.onCommand = onCommand
        self.onMenu = onMenu
        self.onPreview = onPreview
        self.onDrag = onDrag
        self.onPopoutChange = onPopoutChange
        self.onTitleDemandChange = onTitleDemandChange
    }

    static var definitionsURL: URL? {
        Bundle.module.url(forResource: "omniwm.d", withExtension: "luau")
    }

    static func shellDirectory(in configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("shell", isDirectory: true)
    }
}
