// swift-tools-version: 6.0

import PackageDescription

let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsDeveloperLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Anton",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Anton", targets: ["GilfoyleApp"]),
        .executable(name: "anton-hook", targets: ["GilfoyleHook"]),
        .executable(name: "anton-self-test", targets: ["GilfoyleSelfTest"]),
        .library(name: "GilfoyleCore", targets: ["GilfoyleCore"])
    ],
    targets: [
        .target(
            name: "GilfoyleCore",
            path: "Sources/GilfoyleCore"
        ),
        .executableTarget(
            name: "GilfoyleHook",
            dependencies: ["GilfoyleCore"],
            path: "Sources/GilfoyleHook"
        ),
        .executableTarget(
            name: "GilfoyleApp",
            dependencies: ["GilfoyleCore"],
            path: "Sources/GilfoyleApp"
        ),
        .executableTarget(
            name: "GilfoyleSelfTest",
            dependencies: ["GilfoyleCore"],
            path: "Sources/GilfoyleSelfTest"
        ),
        .testTarget(
            name: "GilfoyleCoreTests",
            dependencies: ["GilfoyleCore"],
            path: "Tests/GilfoyleCoreTests",
            swiftSettings: [
                // Command Line Tools ships Swift Testing here, but unlike full Xcode
                // does not add the framework search path to SwiftPM test targets.
                .unsafeFlags(["-F", commandLineToolsFrameworks], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-F", commandLineToolsFrameworks,
                        "-Xlinker", "-rpath",
                        "-Xlinker", commandLineToolsFrameworks,
                        "-Xlinker", "-rpath",
                        "-Xlinker", commandLineToolsDeveloperLibraries
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
