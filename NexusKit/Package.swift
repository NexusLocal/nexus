// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NexusKit",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "NexusCore", targets: ["NexusCore"]),
        .library(name: "NexusRuntime", targets: ["NexusRuntime"]),
        .library(name: "NexusSupervisor", targets: ["NexusSupervisor"]),
        .library(name: "NexusIPC", targets: ["NexusIPC"]),
        .library(name: "NexusEngine", targets: ["NexusEngine"]),
        .library(name: "NexusCommands", targets: ["NexusCommands"]),
        .library(name: "NexusMCP", targets: ["NexusMCP"]),
        .library(name: "NexusDNS", targets: ["NexusDNS"]),
        .library(name: "NexusMail", targets: ["NexusMail"]),
        .library(name: "NexusTLS", targets: ["NexusTLS"]),
        .library(name: "NexusCrashReports", targets: ["NexusCrashReports"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.33.0"),
    ],
    targets: [
        .target(name: "NexusCore"),
        // The app and nexusd send their crashes to Sentry. The product Sentry is a static library.
        // The build without AppKit is a dynamic framework, and nexusd is a tool without a folder
        // for frameworks, so it would not start.
        .target(name: "NexusCrashReports", dependencies: [
            "NexusCore",
            .product(name: "Sentry", package: "sentry-cocoa"),
        ]),
        .target(name: "NexusDNS", dependencies: ["NexusCore"]),
        .target(name: "NexusMail", dependencies: ["NexusCore"]),
        .target(name: "NexusConfig", dependencies: ["NexusCore"]),
        // The receiver and the store of the dumps that the prepend file of PHP sends.
        .target(name: "NexusDumps", dependencies: ["NexusCore"]),
        .target(name: "NexusTLS", dependencies: [
            "NexusCore",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .target(name: "NexusRuntime", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusSupervisor", dependencies: ["NexusCore"]),
        .target(name: "NexusIPC", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor", "NexusMail"]),
        .target(name: "NexusLaravel", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusWorkspaces", dependencies: ["NexusCore", "NexusSupervisor"]),
        .target(name: "NexusEngine", dependencies: ["NexusCore", "NexusRuntime", "NexusSupervisor", "NexusIPC", "NexusDNS", "NexusTLS", "NexusConfig", "NexusLaravel", "NexusWorkspaces", "NexusMail", "NexusDumps"]),
        // The MCP server of nexus mcp, the tools that agents call, and the setup of each agent.
        // The app uses the setup and the settings of the agents.
        .target(name: "NexusMCP", dependencies: ["NexusCore", "NexusIPC", "NexusLaravel", "NexusMail", "NexusRuntime", "NexusSupervisor", "NexusWorkspaces"]),
        .target(name: "NexusCommands", dependencies: [
            "NexusCore",
            "NexusIPC",
            "NexusMail",
            "NexusMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusCrashReportsTests", dependencies: [
            "NexusCrashReports",
            .product(name: "Sentry", package: "sentry-cocoa"),
        ]),
        .testTarget(name: "NexusRuntimeTests", dependencies: ["NexusRuntime"]),
        .testTarget(name: "NexusSupervisorTests", dependencies: ["NexusSupervisor"]),
        .testTarget(name: "NexusEngineTests", dependencies: ["NexusEngine", "NexusDNS", "NexusTLS", "NexusMail", "NexusTestSupport"]),
        .testTarget(name: "NexusDNSTests", dependencies: ["NexusDNS", "NexusTestSupport"]),
        .testTarget(name: "NexusMailTests", dependencies: ["NexusMail"]),
        .testTarget(name: "NexusDumpsTests", dependencies: ["NexusDumps", "NexusCore", "NexusTestSupport"]),
        .testTarget(name: "NexusConfigTests", dependencies: ["NexusConfig"]),
        .testTarget(name: "NexusLaravelTests", dependencies: ["NexusLaravel", "NexusCore"]),
        .testTarget(name: "NexusWorkspacesTests", dependencies: ["NexusWorkspaces", "NexusCore", "NexusSupervisor"]),
        .testTarget(name: "NexusIPCTests", dependencies: ["NexusIPC", "NexusSupervisor"], exclude: ["Releases"]),
        .testTarget(name: "NexusMCPTests", dependencies: ["NexusMCP", "NexusCore", "NexusIPC", "NexusMail"]),
        .testTarget(name: "NexusCommandsTests", dependencies: [
            "NexusCommands",
            "NexusCore",
            "NexusMail",
            "NexusMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "NexusTLSTests", dependencies: [
            "NexusTLS",
            "NexusTestSupport",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .target(name: "NexusTestSupport", dependencies: ["NexusTLS", "NexusIPC", "NexusDNS", "NexusDumps", "NexusCore"], path: "Tests/NexusTestSupport"),
    ]
)
