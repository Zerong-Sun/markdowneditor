// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MarkdownStudio", targets: ["MarkdownStudio"])
    ],
    targets: [
        .executableTarget(
            name: "MarkdownStudio",
            path: "Sources",
            resources: [
                .copy("Resources/marked.min.js"),
                .copy("Resources/katex.min.js"),
                .copy("Resources/katex.min.css")
            ]
        )
    ]
)
