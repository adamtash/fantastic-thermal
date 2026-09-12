// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThermalBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ThermalBarCore", targets: ["ThermalBarCore"]),
        .executable(name: "ThermalBar", targets: ["ThermalBar"]),
        .executable(name: "thermalbar-probe", targets: ["ThermalBarProbe"]),
        .executable(name: "ThermalBarHelper", targets: ["ThermalBarHelper"])
    ],
    targets: [
        .target(
            name: "ThermalBarCore",
            path: "Sources/ThermalBarCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ThermalBar",
            dependencies: ["ThermalBarCore"],
            path: "Sources/ThermalBar",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ThermalBarProbe",
            dependencies: ["ThermalBarCore"],
            path: "Sources/ThermalBarProbe"
        ),
        .executableTarget(
            name: "ThermalBarHelper",
            dependencies: ["ThermalBarCore"],
            path: "Sources/ThermalBarHelper",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "ThermalBarTests",
            dependencies: ["ThermalBarCore"],
            path: "Tests/ThermalBarTests"
        )
    ]
)
