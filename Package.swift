// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Hubless",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Hubless",
            path: "Sources/Hubless",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "HublessTests", dependencies: ["Hubless"], path: "Tests/HublessTests"),
    ]
)
