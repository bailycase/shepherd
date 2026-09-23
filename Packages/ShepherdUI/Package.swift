// swift-tools-version: 6.0
import PackageDescription

// Night Watch, Shepherd's design system: the runtime theme model and its tokens, the bundled
// Geist faces, and the shared SwiftUI components. SwiftUI only: no app state. Its unit tests
// live in the root package (Tests/ShepherdUIUnitTests) so `swift test` there stays the single
// test entry point.
let package = Package(
    name: "ShepherdUI",
    platforms: [.macOS("26.0"), .iOS("27.0")],
    products: [
        .library(name: "ShepherdUI", targets: ["ShepherdUI"]),
    ],
    targets: [
        .target(
            name: "ShepherdUI",
            resources: [.copy("Resources/Fonts")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
