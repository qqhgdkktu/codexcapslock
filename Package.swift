// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexCapsLockIndicator",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "codex-capslock-indicator",
            targets: ["CodexCapsLockIndicator"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "CodexCapsLockIndicator",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CodexCapsLockIndicatorTests",
            dependencies: ["CodexCapsLockIndicator"]
        ),
    ]
)
