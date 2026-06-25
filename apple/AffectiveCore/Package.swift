// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AffectiveCoreApple",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AffectiveCoreApple", targets: ["AffectiveCoreApple"]),
    ],
    targets: [
        .executableTarget(
            name: "AffectiveCoreApple",
            path: "Sources/AffectiveCoreApple"
        ),
    ]
)
