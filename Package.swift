// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PDFToEPUB",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PDFToEPUB", targets: ["PDFToEPUB"]),
        .executable(name: "pdf2epub", targets: ["pdf2epub"]),
        .library(name: "PDFToEPUBCore", targets: ["PDFToEPUBCore"]),
    ],
    targets: [
        .target(name: "PDFToEPUBCore"),
        .executableTarget(name: "PDFToEPUB", dependencies: ["PDFToEPUBCore"]),
        .executableTarget(name: "pdf2epub", dependencies: ["PDFToEPUBCore"]),
        .testTarget(name: "PDFToEPUBCoreTests", dependencies: ["PDFToEPUBCore"]),
    ]
)
