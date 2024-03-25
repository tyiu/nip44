// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NIP44",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NIP44",
            targets: ["NIP44"]
        )
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(
            url: "https://github.com/GigaBitcoin/secp256k1.swift",
            from: "0.12.2"
        ),
        .package(
            url: "https://github.com/jedisct1/swift-sodium.git",
            revision: "63240810df971557fe9badc557257bdfbfeb90a3"
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NIP44",
            dependencies: [
                .product(name: "secp256k1", package: "secp256k1.swift"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ]
        ),
        .testTarget(
            name: "NIP44Tests",
            dependencies: ["NIP44"],
            resources: [.copy("Fixtures")]
        )
    ]
)
