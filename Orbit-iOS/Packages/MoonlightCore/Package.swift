// swift-tools-version:5.9
import PackageDescription

// MoonlightCore bundles the GPLv3 moonlight-common-c protocol library (with its ENet fork and
// the nanors Reed-Solomon codec) as a C target, plus a Swift layer: Apple crypto for the
// library's platform hooks, a VideoToolbox renderer, an Opus audio renderer and input bridges.
let package = Package(
    name: "MoonlightCore",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MoonlightCore", targets: ["MoonlightCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/alta/swift-opus.git", from: "0.0.2"),
    ],
    targets: [
        .target(
            name: "CMoonlight",
            path: "Sources/CMoonlight",
            exclude: ["LICENSE.txt", "VENDORED_REVISION.txt", "enet/LICENSE.txt", "nanors/LICENSE.txt"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("enet/include"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps"),
                .headerSearchPath("nanors/deps/obl"),
                .define("NDEBUG"),
                .define("HAS_SOCKLEN_T", to: "1"),
                .define("HAS_FCNTL", to: "1"),
                .define("HAS_IOCTL", to: "1"),
                .define("HAS_POLL", to: "1"),
                .define("HAS_GETADDRINFO", to: "1"),
                .define("HAS_GETNAMEINFO", to: "1"),
                .define("HAS_INET_PTON", to: "1"),
                .define("HAS_INET_NTOP", to: "1"),
                .define("HAS_MSGHDR_FLAGS", to: "1"),
            ]
        ),
        .target(
            name: "MoonlightCore",
            dependencies: [
                "CMoonlight",
                .product(name: "Copus", package: "swift-opus"),
            ],
            path: "Sources/MoonlightCore",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("GameController"),
            ]
        ),
        .testTarget(
            name: "MoonlightCoreTests",
            dependencies: ["MoonlightCore"],
            path: "Tests/MoonlightCoreTests"
        ),
    ]
)
