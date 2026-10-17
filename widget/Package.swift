// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwapWidget",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeSwapWidget", targets: ["ClaudeSwapWidget"]),
        .executable(name: "ClaudeBarFanHelper", targets: ["ClaudeBarFanHelper"])
    ],
    dependencies: [
        // Sparkle 2 — in-app auto-update. EdDSA-signed appcast.
        // See packaging/Info.plist for SUFeedURL + SUPublicEDKey, and
        // .github/workflows/release.yml for the signing pipeline.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // AppleSMC access shared by the app (sensor reads) and the root fan
        // helper (fan writes).
        .target(
            name: "SMCKit",
            path: "Sources/SMCKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency=complete")]
        ),
        // Tiny setuid-root tool the app installs to change fan speed.
        .executableTarget(
            name: "ClaudeBarFanHelper",
            dependencies: ["SMCKit"],
            path: "Sources/ClaudeBarFanHelper"
        ),
        .executableTarget(
            name: "ClaudeSwapWidget",
            dependencies: [
                "SMCKit",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClaudeSwapWidget",
            resources: [.process("Resources")],
            swiftSettings: [
                // Prepare for Swift 6: surface every actor-isolation,
                // Sendable, and global-state issue as a warning today so the
                // language-mode flip later doesn't avalanche into hard errors.
                .enableExperimentalFeature("StrictConcurrency=complete")
            ]
        ),
        .testTarget(
            name: "ClaudeSwapWidgetTests",
            dependencies: ["ClaudeSwapWidget", "SMCKit"],
            path: "Tests/ClaudeSwapWidgetTests"
        )
    ]
)
