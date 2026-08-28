// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CyaimIM",

    // Duration, Clock and `Task.sleep(for:)` set the floor: iOS 16 / macOS 13 / tvOS 16 / visionOS 1.
    // Those are also the oldest OSes where URLSessionWebSocketTask behaves the same across
    // platforms, so the transport does not need per-OS branches.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],

    products: [
        .library(name: "CyaimIM", targets: ["CyaimIM"]),
    ],

    // Deliberately empty. An IM SDK is a guest in someone else's app: every package it drags in is
    // a version conflict waiting to happen, and a networking dependency is the worst kind because
    // the host app almost certainly already has one. Everything here is Foundation and the
    // concurrency library. Tests use swift-testing, which ships with the Swift 6 toolchain.
    dependencies: [],

    targets: [
        .target(
            name: "CyaimIM",
            dependencies: [],
            swiftSettings: [
                // Strict concurrency is not a stretch goal here. The client is an actor holding
                // per-conversation sequence state that a receive loop, a heartbeat and the app's
                // own tasks all touch; the compiler proving that is worth more than any test.
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CyaimIMTests",
            dependencies: ["CyaimIM"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
