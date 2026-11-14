// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioAnalyzer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnalysisCore", targets: ["AnalysisCore"]),
        .executable(name: "AnalyzerApp", targets: ["AnalyzerApp"]),
        .executable(name: "RenderSnapshot", targets: ["RenderSnapshot"]),
    ],
    targets: [
        // Pure DSP: no UI, no audio I/O, so everything here is unit-testable.
        .target(name: "AnalysisCore"),
        .target(name: "AnalyzerUI", dependencies: ["AnalysisCore"]),
        .executableTarget(name: "AnalyzerApp", dependencies: ["AnalysisCore", "AnalyzerUI"]),
        // Renders the window with a synthetic signal to a PNG (used by CI).
        .executableTarget(name: "RenderSnapshot", dependencies: ["AnalysisCore", "AnalyzerUI"]),
        .testTarget(name: "AnalysisCoreTests", dependencies: ["AnalysisCore"]),
    ]
)
