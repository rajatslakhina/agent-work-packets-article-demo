// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WorkPackets",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WorkPackets", targets: ["WorkPackets"])
    ],
    targets: [
        .target(name: "WorkPackets"),
        .testTarget(name: "WorkPacketsTests", dependencies: ["WorkPackets"])
    ]
)
