// swift-tools-version: 6.0
import PackageDescription

// These source links compile the canonical production core unchanged on Linux.
// CryptoKit's API is provided by Apple's official swift-crypto package.
let package = Package(
    name: "LorvexCloudNative",
    products: [.executable(name: "lorvex-cloud-native", targets: ["LorvexCloudNative"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "LorvexDomain"),
        .target(name: "LorvexStore", dependencies: ["LorvexDomain", "CryptoKit", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "LorvexWorkflow", dependencies: ["LorvexDomain", "LorvexStore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "LorvexSync", dependencies: ["LorvexDomain", "LorvexStore", "LorvexWorkflow", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Resources/SyncPayloadContracts")]),
        .target(name: "LorvexCloudNativeCore", dependencies: ["LorvexDomain", "LorvexStore", "LorvexWorkflow", "LorvexSync", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Resources/schema.sql"), .copy("Resources/Migrations")]),
        .executableTarget(name: "LorvexCloudNative", dependencies: ["LorvexCloudNativeCore"]),
        .testTarget(name: "LorvexCloudNativeTests", dependencies: ["LorvexCloudNativeCore", "LorvexDomain", "LorvexStore", "LorvexWorkflow", "LorvexSync", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
