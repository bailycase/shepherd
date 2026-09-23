// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [.macOS("26.0"), .iOS("27.0")],
    products: [
        .library(name: "ShepherdCore", targets: ["ShepherdCore"]),
        .library(name: "ShepherdProtocol", targets: ["ShepherdProtocol"]),
        .library(name: "ShepherdRemote", targets: ["ShepherdRemote"]),
        .library(name: "ShepherdSessions", targets: ["ShepherdSessions"]),
        .library(name: "TerminalSurfaceKit", targets: ["TerminalSurfaceKit"]),
        .library(name: "ShepherdApp", targets: ["ShepherdApp"]),
        .executable(name: "shepherd-cli", targets: ["shepherd-cli"]),
    ],
    dependencies: [
        .package(path: "Vendor/libghostty-spm"),
        // Night Watch, the design system: its own package (see Packages/ShepherdUI).
        .package(path: "Packages/ShepherdUI"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.18.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    ],
    targets: [
        .target(name: "ShepherdCore"),
        .target(name: "ShepherdProtocol", dependencies: ["ShepherdCore"]),
        // Remote client (TCP NDJSON to a Shepherd host) + logging.
        .target(
            name: "ShepherdRemote",
            dependencies: ["ShepherdCore", "ShepherdProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The pty child side (fork → exec) in C: nothing in Swift may run between fork and exec.
        .target(name: "ShepherdPTYSpawn"),
        .target(
            name: "ShepherdSessions",
            dependencies: [
                "ShepherdCore", "ShepherdProtocol", "ShepherdRemote", "ShepherdPTYSpawn",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TerminalSurfaceKit",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm")
            ],
            exclude: ["NOTES.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ShepherdApp",
            dependencies: [
                "ShepherdCore", "ShepherdProtocol", "ShepherdSessions", "TerminalSurfaceKit",
                .product(name: "ShepherdUI", package: "ShepherdUI"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "shepherd-cli",
            dependencies: ["ShepherdCore", "ShepherdProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests come in two tiers (see AGENTS.md "Testing"):
        //   *UnitTests — pure logic: no processes, sockets, windows, or sleeps. `swift test --filter UnitTests`.
        //   *IntegrationTests and ShepherdPreviewTests — real servers, stub pi, git, AppKit
        //   windows, rendered previews. `swift test --filter "IntegrationTests|PreviewTests"`.
        .testTarget(name: "ShepherdCoreUnitTests", dependencies: ["ShepherdCore"]),
        .testTarget(name: "ShepherdProtocolUnitTests", dependencies: ["ShepherdProtocol"]),
        .testTarget(name: "ShepherdUIUnitTests", dependencies: [.product(name: "ShepherdUI", package: "ShepherdUI")]),
        .testTarget(name: "ShepherdRemoteUnitTests", dependencies: ["ShepherdCore", "ShepherdProtocol", "ShepherdRemote"]),
        .testTarget(name: "ShepherdSessionsUnitTests", dependencies: ["ShepherdSessions"]),
        .testTarget(name: "ShepherdAppUnitTests", dependencies: ["ShepherdApp"]),
        .testTarget(name: "ShepherdCLIUnitTests", dependencies: ["shepherd-cli"]),
        .testTarget(name: "TerminalSurfaceKitUnitTests", dependencies: ["TerminalSurfaceKit"]),
        .target(
            name: "ShepherdTestSupport",
            dependencies: ["ShepherdCore", "ShepherdProtocol", "ShepherdSessions"],
            path: "Tests/ShepherdTestSupport",
            resources: [.copy("Resources/stub-pi.py")]
        ),
        .testTarget(name: "ShepherdSessionsIntegrationTests", dependencies: ["ShepherdSessions", "ShepherdTestSupport"]),
        .testTarget(
            name: "ShepherdAppIntegrationTests",
            dependencies: ["ShepherdApp", "TerminalSurfaceKit", "ShepherdTestSupport", .product(name: "ShepherdUI", package: "ShepherdUI")]
        ),
        .testTarget(
            name: "ShepherdPreviewTests",
            dependencies: ["ShepherdApp", "ShepherdTestSupport", .product(name: "ShepherdUI", package: "ShepherdUI")]
        ),
    ]
)
