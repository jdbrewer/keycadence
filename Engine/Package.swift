// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KeycadenceEngine",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "CKeycadence", targets: ["CKeycadence"]),
        .executable(name: "kc-bench", targets: ["kc-bench"]),
    ],
    targets: [
        .target(
            name: "CKeycadence",
            cSettings: [.unsafeFlags(["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter"])],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(name: "kc-bench", dependencies: ["CKeycadence"]),
        .testTarget(name: "CKeycadenceTests", dependencies: ["CKeycadence"]),
    ]
)
