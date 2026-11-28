// swift-tools-version: 6.5
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyMacOSLibraryDirectory = "\(packageDirectory)/Frameworks/GhosttyKit.xcframework/macos-arm64"
let scriptARCDirectory = ProcessInfo.processInfo.environment["OMNIWM_SCRIPT_ARC_DIRECTORY"]
let liveChecks = ProcessInfo.processInfo.environment["OMNIWM_LIVE_CHECKS"] != nil

let package = Package(
    name: "OmniWM",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "OmniWM",
            targets: ["OmniWMApp"]
        ),
        .executable(
            name: "omniwmctl",
            targets: ["OmniWMCtl"]
        ),
        .executable(name: "omniwm-metadata", targets: ["OmniWMMetadataTool"]),
        .library(
            name: "OmniWMNowPlaying",
            type: .dynamic,
            targets: ["OmniWMNowPlaying"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "OmniWMAutomation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWMIPC",
            dependencies: ["OmniWMAutomation"],
            path: "Sources/OmniWMIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWMLayerCorners",
            path: "Sources/OmniWMLayerCorners",
            cSettings: [
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWMAudioTap",
            path: "Sources/OmniWMAudioTap",
            cSettings: [
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWMNowPlaying",
            path: "Sources/OmniWMNowPlaying",
            cSettings: [
                .treatAllWarnings(as: .error)
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "OmniWMLauncherSPI",
            path: "Sources/OmniWMLauncherSPI",
            cSettings: [
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWMWiFiSPI",
            path: "Sources/OmniWMWiFiSPI",
            cSettings: [
                .treatAllWarnings(as: .error)
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN")
            ]
        ),
        .target(
            name: "OmniWMLuau",
            path: "Sources/OmniWMLuau",
            exclude: ["LICENSE.txt", "lua_LICENSE.txt", "VERSION", "Bytecode/src/BytecodeGraph.cpp"],
            cxxSettings: [
                .headerSearchPath("Common/include"),
                .headerSearchPath("Ast/include"),
                .headerSearchPath("Bytecode/include"),
                .headerSearchPath("Compiler/include"),
                .headerSearchPath("VM/include"),
                .headerSearchPath("VM/src"),
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
                .treatAllWarnings(as: .error),
                .treatWarning("unused-command-line-argument", as: .warning)
            ]
        ),
        .target(
            name: "OmniWMScriptHost",
            dependencies: ["OmniWMLuau"],
            path: "Sources/OmniWMScriptHost",
            cxxSettings: [
                .headerSearchPath("../OmniWMLuau/Ast/include"),
                .headerSearchPath("../OmniWMLuau/Common/include"),
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
                .treatAllWarnings(as: .error),
                .treatWarning("unused-command-line-argument", as: .warning)
            ] + (liveChecks ? [.define("OMNIWM_LIVE_CHECKS")] : [])
        ),
        .target(
            name: "OmniWMMetadata",
            dependencies: ["OmniWMScriptHost"]
        ),
        .executableTarget(
            name: "OmniWMMetadataTool",
            dependencies: ["OmniWMMetadata"],
            path: "Scripts/OmniWMMetadataTool"
        ),
        .target(
            name: "OmniWMMaterialColor",
            path: "Sources/OmniWMMaterialColor",
            cxxSettings: [
                .headerSearchPath("."),
                .treatAllWarnings(as: .error),
                .treatWarning("unused-command-line-argument", as: .warning)
            ]
        ),
        .target(
            name: "OmniWMShellCore",
            path: "Sources/OmniWMShellCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .target(
            name: "OmniWM",
            dependencies: [
                "GhosttyKit",
                "OmniWMAutomation",
                "OmniWMIPC",
                "OmniWMAudioTap",
                "OmniWMLayerCorners",
                "OmniWMLauncherSPI",
                "OmniWMWiFiSPI",
                "OmniWMMaterialColor",
                "OmniWMMetadata",
                "OmniWMScriptHost",
                "OmniWMShellCore"
            ],
            path: "Sources/OmniWM",
            exclude: scriptARCDirectory == nil ? [
                "ScriptARCWorkload.swift", "ScriptARCWorkerLifetime.swift", "ScriptARCFocusWorkload.swift",
                "ScriptARCTopologyWorkload.swift", "ScriptARCWindowEvents.swift", "ScriptARCTimerWorkload.swift",
                "ScriptARCWindowTransactions.swift", "ScriptARCEventOwnership.swift", "ScriptARCSnapshotWorkload.swift",
                "ScriptARCWorkspaceKeys.swift", "ScriptARCDwindleWorkload.swift", "ScriptARCGatherWorkload.swift",
                "ScriptARCNamedModeWorkload.swift", "ScriptARCStoreWorkload.swift", "ScriptARCMarkWorkload.swift",
                "ScriptARCDetailsPlatform.swift", "ScriptARCWorkspaceActionWorkload.swift"
            ] : [],
            resources: [
                .process("Resources"),
                .copy("ShellDefault"),
                .copy("ShellApps")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .interoperabilityMode(.C),
                .unsafeFlags([
                    "-Xfrontend", "-disable-round-trip-debug-types"
                ])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-L\(ghosttyMacOSLibraryDirectory)"]),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .executableTarget(
            name: "OmniWMApp",
            dependencies: ["OmniWM"],
            path: "Sources/OmniWMApp",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .executableTarget(
            name: "OmniWMCtl",
            dependencies: ["OmniWMAutomation", "OmniWMIPC"],
            path: "Sources/OmniWMCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: [
                "OmniWM", "OmniWMAudioTap", "OmniWMAutomation", "OmniWMCtl", "OmniWMLayerCorners",
                "OmniWMMaterialColor",
                "OmniWMScriptHost",
                "OmniWMShellCore"
            ],
            path: "Tests/OmniWMTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ] + (liveChecks ? [.define("OMNIWM_LIVE_CHECKS")] : [])
        )
    ],
    cxxLanguageStandard: .cxx17
)

if let auditDirectory = scriptARCDirectory {
    let counters = "ScriptARCCounters"
    package.targets.append(.target(name: counters, path: "Scripts/script-arc-audit/Counters"))
    package.targets.append(.executableTarget(
        name: "ScriptARCRunner", dependencies: ["OmniWM"], path: "Scripts/script-arc-audit/Runner"
    ))
    package.products.append(.executable(name: "script-arc-audit", targets: ["ScriptARCRunner"]))
    let host = package.targets.first { $0.name == "OmniWMScriptHost" }!
    host.cxxSettings = (host.cxxSettings ?? []) + [.define("lua_resume", to: "script_arc_lua_resume")]
    let app = package.targets.first { $0.name == "OmniWM" }!
    app.dependencies.append(.byName(name: counters))
    app.swiftSettings = (app.swiftSettings ?? []) + [.define("OMNIWM_SCRIPT_ARC_AUDIT")]
    app.linkerSettings = (app.linkerSettings ?? []) + [.unsafeFlags(["-L" + auditDirectory, "-lScriptARC"])]
}
