// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Compiler",
    platforms: [.macOS(.v13), .iOS(.v14)],
    products: [
        .library(name: "Compiler", targets: ["Compiler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/hakkabon/Grammar.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/Parser.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/Lexer.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/Lexer-FSA.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/Earley-Parser.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/CYK-Parser.git", branch: "main"),
        .package(url: "https://github.com/hakkabon/RNGLR-Parser.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Compiler",
            dependencies: [
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Parser", package: "Parser"),
                .product(name: "Lexer", package: "Lexer"),
            ],
        ),
        .testTarget(
            name: "CompilerTests",
            dependencies: [
                "Compiler",
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Parser", package: "Parser"),
                .product(name: "Earley-Parser", package: "Earley-Parser"),
            ]
        ),
        .executableTarget(
            name: "comp",
            dependencies: [
                "Compiler",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Parser", package: "Parser"),
                .product(name: "Lexer", package: "Lexer"),
                .product(name: "LexerFSA", package: "Lexer-FSA"),
                .product(name: "Earley-Parser", package: "Earley-Parser"),
                .product(name: "CYK-Parser", package: "CYK-Parser"),
                .product(name: "RNGLR-Parser", package: "RNGLR-Parser"),
            ]
        ),
    ]
)
