// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [.macOS("26.0")],
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
        .target(
            name: "ShepherdSessions",
            dependencies: [
                "ShepherdCore", "ShepherdProtocol", "ShepherdRemote",
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
        .testTarget(name: "ShepherdCoreTests", dependencies: ["ShepherdCore"]),
        .testTarget(name: "ShepherdProtocolTests", dependencies: ["ShepherdProtocol"]),
        .testTarget(
            name: "ShepherdRemoteTests",
            dependencies: ["ShepherdCore", "ShepherdProtocol", "ShepherdRemote"]
        ),
        .testTarget(name: "ShepherdSessionsTests", dependencies: ["ShepherdSessions"]),
        .testTarget(name: "TerminalSurfaceKitTests", dependencies: ["TerminalSurfaceKit"]),
        .testTarget(name: "ShepherdAppTests", dependencies: ["ShepherdApp"]),
        .testTarget(name: "ShepherdCLITests", dependencies: ["shepherd-cli"]),
    ]
)
