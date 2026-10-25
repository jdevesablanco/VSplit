// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VSplit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VSplitApp", targets: ["VSplitApp"]),
        .executable(name: "vsplit", targets: ["VSplitCLI"]),
    ],
    targets: [
        // MIDI (parser, writer, modelo) + Engine (reparto, undo, exportación). Solo Foundation/CryptoKit.
        .target(name: "VSplitCore"),
        // App SwiftUI/AppKit: UI (piano roll, voces) + Audio (preview con AVAudioEngine).
        .executableTarget(name: "VSplitApp", dependencies: ["VSplitCore"]),
        // CLI: genera Samples/ y permite repartir un .mid sin UI.
        .executableTarget(name: "VSplitCLI", dependencies: ["VSplitCore"]),
        .testTarget(name: "VSplitCoreTests", dependencies: ["VSplitCore"], exclude: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
