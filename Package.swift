// swift-tools-version:5.9
//
// FreenetAppKit for iOS: the UniFFI Swift bindings for freenet-core's
// `crates/mobile`, over the FreenetMobileFFI XCFramework that
// `scripts/build-ios.sh` builds into build/ios/.

import PackageDescription

let package = Package(
    name: "FreenetAppKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "FreenetAppKit", targets: ["FreenetAppKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "FreenetMobileFFI",
            path: "build/ios/FreenetMobileFFI.xcframework"
        ),
        .target(
            name: "FreenetAppKit",
            dependencies: ["FreenetMobileFFI"],
            path: "Sources/FreenetAppKit",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
