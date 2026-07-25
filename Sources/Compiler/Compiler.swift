//
//  Compiler.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public struct CompilationArtifacts: Sendable {
    public let sourceAST: ASTNode
    public let typedAST: ResolvedASTNode
    public let symbols: [Symbol]
    public let ir: IRProgram
}

public final class Compiler {
    public init() {}

    public func analyze(_ ast: ASTNode) throws -> CompilationArtifacts {
        let result = try SemanticAnalyzer().analyzeProgram(ast)
        let ir = try IRLowerer().lower(result)
        return CompilationArtifacts(sourceAST: ast, typedAST: result.ast, symbols: result.symbols, ir: ir)
    }

    public func parse(_ source: String, file: String? = nil) throws -> ASTNode {
        try SourceParser().parse(source, file: file)
    }

    public func compile(_ source: String, file: String? = nil) throws -> StackCompilation {
        try compile(parse(source, file: file))
    }

    public func compile(_ ast: ASTNode) throws -> StackCompilation {
        try StackCodeGenerator.generate(analyze(ast).ir)
    }

    public func compileExpression(_ ast: ASTNode) throws -> [Instruction] {
        try compile(ast).instructions
    }

    public func execute(
        _ source: String,
        file: String? = nil,
        input: @escaping InputProvider = { readLine() ?? "" },
        output: @escaping OutputHandler = { print($0) }
    ) throws -> Value? {
        let compilation = try compile(source, file: file)
        return try StackMachine(
            bytecode: compilation.instructions,
            localCount: compilation.localCount,
            input: input,
            output: output
        ).execute()
    }

    public func executeExpression(_ ast: ASTNode) throws -> Value? {
        let compilation = try compile(ast)
        return try StackMachine(bytecode: compilation.instructions, localCount: compilation.localCount).execute()
    }
}
