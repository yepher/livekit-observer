// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ObserverCore",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [.library(name: "ObserverCore", targets: ["ObserverCore"])],
    targets: [
        .target(name: "ObserverCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "ObserverCoreTests", dependencies: ["ObserverCore"])
    ]
)
