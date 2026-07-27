// swift-tools-version: 6.4
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyMacOSLibraryDirectory = "\(packageDirectory)/Frameworks/GhosttyKit.xcframework/macos-arm64"

let package = Package(
    name: "OmniWM",
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
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "OmniWMMenuBarAssertion",
            path: "Sources/OmniWMMenuBarAssertion"
        ),
        .target(
            name: "OmniWM",
            dependencies: [
                "GhosttyKit",
                "OmniWMIPC",
                "OmniWMMenuBarAssertion",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/OmniWM",
            resources: [
                .process("Resources"),
                .copy("Core/IssueReporter/Prompts")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OmniWMCtl",
            dependencies: ["OmniWMIPC"],
            path: "Sources/OmniWMCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OmniWMTests",
            dependencies: ["OmniWM", "OmniWMCtl"],
            path: "Tests/OmniWMTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
