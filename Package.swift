// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "damson",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Engine library — the GPU terminal + VT stack. Also consumed downstream by
        // the Orchard cockpit (github.com/hulryung/damson-ide), so treat its public
        // API as a versioned contract: coordinate breaking changes with a tag bump.
        .library(
            name: "DamsonTerminal",
            targets: ["DamsonTerminal"]
        ),
        // damson ↔ damson-cli IPC wire format (shared by server/client; also reused
        // downstream by Orchard's control layer).
        .library(
            name: "DamsonControl",
            targets: ["DamsonControl"]
        ),
        // Standalone app (`swift run damson` during development; Xcode project later for distribution)
        .executable(
            name: "damson",
            targets: ["damson"]
        ),
        // CLI client — sends commands to the damson server
        .executable(
            name: "damson-cli",
            targets: ["damson-cli"]
        ),
        // Coordinator — drives damson from OUTSIDE through the public wire. A separate
        // binary on purpose: damson.app still does not schedule anything, and deleting this
        // target leaves damson unchanged. It lives in this repo rather than its own because
        // it tracks the wire format, and a separate repo would have to pin a version of it —
        // which is exactly why damson-ide, pinned at 0.4.1, cannot see any of the 0.5.x
        // commands today.
        .executable(
            name: "damson-crew",
            targets: ["damson-crew"]
        ),
        // Session keeper — holds PTY master fds across an app restart so the
        // children (shells, TUIs) survive an update relaunch. See docs/SESSION-KEEPER.md.
        .executable(
            name: "damson-keeper",
            targets: ["damson-keeper"]
        ),
    ],
    dependencies: [
        // Sparkle auto-update — only works in a Developer ID-signed .app.
        // The EdDSA keypair is generated once via scripts/sparkle-keygen.sh and
        // baked into SUPublicEDKey in Info.plist. See docs/RELEASE.md for details.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "DamsonTerminal",
            path: "Sources/DamsonTerminal"
            // When Shaders.metal is added later, declare it in resources with .process()
        ),
        .target(
            name: "DamsonControl",
            path: "Sources/DamsonControl"
        ),
        // Agent-orchestration logic, factored out of the app so it can be TESTED: the
        // `damson` target is an executable with top-level code, which `@testable import`
        // handles badly, and pointing a test target at it would drag AppKit + Sparkle into
        // the test process. Everything here is window-free — the AppKit glue that drives it
        // (CrewController) stays in the app.
        //
        // Deliberately a target and NOT a library product: this is damson's own logic, not
        // a contract with downstream consumers. Promoting it later is easy; un-promoting a
        // published API is not.
        .target(
            name: "DamsonAgents",
            dependencies: ["DamsonTerminal"],
            path: "Sources/DamsonAgents"
        ),
        // Tab-group model, factored out of the app for the same reason as DamsonAgents: the
        // `damson` target is an executable with top-level code and cannot be `@testable
        // import`ed. The contiguity invariant and the restore repair path are the parts that
        // must be tested — a mistake in the latter costs the user every window's layout.
        .target(
            name: "DamsonTabGroups",
            path: "Sources/DamsonTabGroups"
        ),
        .executableTarget(
            name: "damson",
            dependencies: [
                "DamsonTerminal",
                "DamsonControl",
                "DamsonAgents",
                "DamsonTabGroups",
                "DamsonCrew",
                "CFDPass",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/damson",
            resources: [.copy("Resources/Damson.icns")]
        ),
        // The coordinator's logic, split from its process setup so it can be tested: the
        // failures that matter are partial ones — three tasks of five opened — and those are
        // neither quick nor repeatable to reproduce against a running app.
        .target(
            name: "DamsonCrew",
            dependencies: ["DamsonControl"],
            path: "Sources/DamsonCrew"
        ),
        .executableTarget(
            name: "damson-crew",
            dependencies: ["DamsonCrew", "DamsonControl"],
            path: "Sources/damson-crew"
        ),
        .executableTarget(
            name: "damson-cli",
            dependencies: ["DamsonControl"],
            path: "Sources/damson-cli"
        ),
        // SCM_RIGHTS fd passing — C because the CMSG_* macros don't import into Swift.
        .target(
            name: "CFDPass",
            path: "Sources/CFDPass"
        ),
        // The keeper's behaviour, split from its process setup so it can be tested: this
        // process holds every surviving session's PTY master across an app restart, so a
        // trap in it is every shell losing its terminal at once.
        // Foundation/Darwin ONLY — must never link AppKit (it would register with
        // LaunchServices and outlive the app as a ghost "app").
        .target(
            name: "DamsonKeeperCore",
            dependencies: ["CFDPass", "DamsonControl"],
            path: "Sources/DamsonKeeperCore"
        ),
        .executableTarget(
            name: "damson-keeper",
            dependencies: ["DamsonKeeperCore", "DamsonControl"],
            path: "Sources/damson-keeper"
        ),
        .testTarget(
            name: "DamsonCrewTests",
            dependencies: ["DamsonCrew", "DamsonControl"],
            path: "Tests/DamsonCrewTests"
        ),
        .testTarget(
            name: "DamsonTabGroupsTests",
            dependencies: ["DamsonTabGroups"],
            path: "Tests/DamsonTabGroupsTests"
        ),
        .testTarget(
            name: "DamsonTerminalTests",
            dependencies: ["DamsonTerminal"],
            path: "Tests/DamsonTerminalTests"
        ),
        .testTarget(
            name: "DamsonControlTests",
            dependencies: ["DamsonControl"],
            path: "Tests/DamsonControlTests"
        ),
        .testTarget(
            name: "DamsonAgentsTests",
            dependencies: ["DamsonAgents", "DamsonTerminal"],
            path: "Tests/DamsonAgentsTests"
        ),
        .testTarget(
            name: "DamsonKeeperCoreTests",
            dependencies: ["DamsonKeeperCore", "DamsonControl"],
            path: "Tests/DamsonKeeperCoreTests"
        ),
    ]
)
