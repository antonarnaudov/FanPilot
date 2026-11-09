// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanPilot",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "FanPilotApp", targets: ["FanPilotApp"]),
        .executable(name: "fanpilotd", targets: ["fanpilotd"]),
        .executable(name: "fanpilotctl", targets: ["fanpilotctl"]),
        .library(name: "FanPilotCore", targets: ["FanPilotCore"]),
    ],
    targets: [
        // C layout of the AppleSMC user-client structure (guaranteed 80 bytes).
        .target(name: "CSMC"),
        // Talking to the SMC: read / write keys, encode / decode values.
        .target(
            name: "SMCKit",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Sensors, fans, the control engine, config and the app <-> helper protocol.
        .target(
            name: "FanPilotCore",
            dependencies: ["SMCKit"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // The root helper daemon that runs the control loop.
        .executableTarget(
            name: "fanpilotd",
            dependencies: ["FanPilotCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        // Command-line tool: status, sensors, test, recovery.
        .executableTarget(name: "fanpilotctl", dependencies: ["FanPilotCore"]),
        // The menu bar app.
        .executableTarget(
            name: "FanPilotApp",
            dependencies: ["FanPilotCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "FanPilotCoreTests", dependencies: ["FanPilotCore", "SMCKit"]),
    ],
    swiftLanguageModes: [.v5]
)
