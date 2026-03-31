// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ProjectSidecar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ProjectSidecar",
            path: "Sources/ProjectSidecar",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "ProjectSidecarTests",
            dependencies: ["ProjectSidecar"],
            path: "Tests/ProjectSidecarTests"
        )
    ]
)
