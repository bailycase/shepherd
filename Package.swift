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
