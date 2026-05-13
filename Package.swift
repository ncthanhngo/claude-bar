// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeWidget",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeWidget", targets: ["ClaudeWidget"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeWidget",
            path: "Sources/ClaudeWidget"
        )
    ]
)
