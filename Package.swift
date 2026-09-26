// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftCDDL",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2),
        .macCatalyst(.v18),
    ],
    products: [
        .library(
            name: "SwiftCDDL",
            targets: ["SwiftCDDL"]
        ),
        .library(
            name: "SwiftCDDLCardano",
            targets: ["SwiftCDDLCardano"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Kingpin-Apps/swift-cbor-codable.git", from: "0.3.4"),
        .package(url: "https://github.com/attaswift/BigInt.git", "5.7.0"..<"7.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftCDDL",
            dependencies: [
                .product(name: "CBORCodable", package: "swift-cbor-codable"),
                .product(name: "BigInt", package: "BigInt"),
            ]
        ),
        .target(
            name: "SwiftCDDLCardano",
            dependencies: ["SwiftCDDL"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "SwiftCDDLTests",
            dependencies: [
                "SwiftCDDL",
                "SwiftCDDLCardano",
                .product(name: "CBORCodable", package: "swift-cbor-codable"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
