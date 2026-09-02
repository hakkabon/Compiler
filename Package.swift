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
        .package(url: "https://github.com/hakkabon/Grammar.git", revision: "69f85d7a493e1862412c34493e3656e94331df06"),
        .package(url: "https://github.com/hakkabon/Parser.git", revision: "3663097550f3ed1b8dcad8a26f4c2c55cc61b4e1"),
        .package(url: "https://github.com/hakkabon/Lexer.git", revision: "efac321be75676bdb88a447f7ea0dd9d1b3bb851"),
        .package(url: "https://github.com/hakkabon/Lexer-FSA.git", revision: "5289a38e507bbf63863699a1eb9ac7a4d19aafba"),
        .package(url: "https://github.com/hakkabon/Earley-Parser.git", revision: "7e1845c9531274ecab8201db5613eb10e149a5e2"),
        .package(url: "https://github.com/hakkabon/CYK-Parser.git", revision: "5c375aea8c68edd5b344f89c38cc33668a49d1cd"),
        .package(url: "https://github.com/hakkabon/RNGLR-Parser.git", revision: "d16e7910f6e807d66b54acf5848f894bebf9bc5b"),
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
