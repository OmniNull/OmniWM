// swift-tools-version: 6.4
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyMacOSLibraryDirectory = "\(packageDirectory)/Frameworks/GhosttyKit.xcframework/macos-arm64"

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
        .library(
            name: "OmniWMNowPlaying",
            type: .dynamic,
            targets: ["OmniWMNowPlaying"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "OmniWMIPC",
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
                .treatAllWarnings(as: .error),
                .treatWarning("unused-command-line-argument", as: .warning)
            ]
        ),
        .target(
            name: "OmniWMScriptHost",
            dependencies: ["OmniWMLuau"],
            path: "Sources/OmniWMScriptHost",
            cxxSettings: [
                .treatAllWarnings(as: .error),
                .treatWarning("unused-command-line-argument", as: .warning)
            ]
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
                "OmniWMIPC",
                "OmniWMAudioTap",
                "OmniWMLayerCorners",
                "OmniWMLauncherSPI",
                "OmniWMMaterialColor",
                "OmniWMScriptHost",
                "OmniWMShellCore",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources"),
                .copy("Core/IssueReporter/Prompts"),
                .copy("ShellDefault"),
                .copy("ShellStyles"),
                .copy("Fonts")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error),
                .interoperabilityMode(.C),
                .unsafeFlags(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "FoundationModels"])
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
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
                .unsafeFlags(["-weak_framework", "FoundationModels"])
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
            dependencies: ["OmniWMIPC"],
            path: "Sources/OmniWMCtl",
            resources: [
                .embedInCode("Completions/completion.zsh"),
                .embedInCode("Completions/completion.bash"),
                .embedInCode("Completions/completion.fish"),
                .embedInCode("Completions/completion.nu")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: [
                "OmniWM", "OmniWMAudioTap", "OmniWMCtl", "OmniWMLayerCorners", "OmniWMMaterialColor",
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
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
