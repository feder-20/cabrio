// swift-tools-version:6.0
import PackageDescription

// Arquitectura hexagonal (ver cabrio.md §6): Domain ← Ports ← Application; Adapters implementan Ports.
// Solo CabrioAdapters puede importar PDFKit, ImageIO, Vision o AVFoundation.
let package = Package(
    name: "Cabrio",
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cabrio", targets: ["CabrioApp"])],
    targets: [
        .target(name: "CabrioDomain"),
        .target(name: "CabrioPorts", dependencies: ["CabrioDomain"]),
        .target(name: "CabrioApplication", dependencies: ["CabrioDomain", "CabrioPorts"]),
        .target(name: "CabrioAdapters", dependencies: ["CabrioDomain", "CabrioPorts"]),
        .executableTarget(
            name: "CabrioApp",
            dependencies: ["CabrioDomain", "CabrioPorts", "CabrioApplication", "CabrioAdapters"]
        ),
        .testTarget(name: "ApplicationTests", dependencies: ["CabrioDomain", "CabrioPorts", "CabrioApplication"]),
        .testTarget(name: "AdapterTests", dependencies: ["CabrioDomain", "CabrioPorts", "CabrioApplication", "CabrioAdapters"]),
        .testTarget(name: "AppTests", dependencies: ["CabrioApp", "CabrioDomain", "CabrioApplication"]),
    ]
)
