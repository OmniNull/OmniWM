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
            name: "OmniWMMenuBarAssertion",
            path: "Sources/OmniWMMenuBarAssertion",
            cSettings: [
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
            name: "OmniWM",
            dependencies: [
                "GhosttyKit",
                "OmniWMIPC",
                "OmniWMMenuBarAssertion",
                "OmniWMLayerCorners",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources"),
                .copy("Core/IssueReporter/Prompts")
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
            dependencies: ["OmniWM", "OmniWMCtl", "OmniWMLayerCorners"],
            path: "Tests/OmniWMTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .treatAllWarnings(as: .error)
            ]
        )
    ]
)
