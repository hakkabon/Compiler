//
//  Comp.swift
//  comp
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import ArgumentParser
import Compiler
import CYK_Parser
import Earley_Parser
import Foundation
import Grammar
import Lexer
import LexerFSA
import Parser
import RNGLR_Parser

extension CompilerTool {
    struct Comp: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate source with a supplied grammar, then compile and execute it."
        )

        @Argument(help: "Grammar file (.bnf, .ebnf, .wsn, or .gen).")
        var grammarFile: String

        @Argument(help: "Source file to parse and compile.")
        var sourceFile: String

        @Option(name: .shortAndLong, help: "Grammar start rule (required except for .gen grammars).")
        var start: String?

        @Option(help: "Grammar notation. Defaults to the grammar file extension.")
        var notation: GrammarNotation?

        @Option(help: "Generalized parsing algorithm.")
        var parser: ParserMethod = .earley

        @Option(help: "Tokenization frontend. DFA mode currently requires --parser earley.")
        var lexer: LexerMethod = .tokenizer

        @Option(help: "How to handle multiple derivations: reject, first, or all.")
        var ambiguity: AmbiguityArgument = .reject

        @Option(help: "Execution target.")
        var target: CompilationTarget = .stack

        @Option(help: "JSON AST-action mapping; when present, compile the external parser's tree directly.")
        var actions: String?

        @Option(
            parsing: .upToNextOption,
            help: "Stages to print: grammar tokens trees ast typed-ast ir bytecode result."
        )
        var emit: [EmitStage] = [.result]

        @Flag(help: "Stop after external parsing and ambiguity checks.")
        var parseOnly = false

        @Flag(help: "Trace virtual-machine execution.")
        var trace = false

        @Option(help: "Write serialized bytecode to this path.")
        var output: String?

        mutating func validate() throws {
            guard FileManager.default.fileExists(atPath: grammarFile) else {
                throw ValidationError("Grammar file does not exist: \(grammarFile)")
            }
            guard FileManager.default.fileExists(atPath: sourceFile) else {
                throw ValidationError("Source file does not exist: \(sourceFile)")
            }
            if resolvedNotation != .gen, start?.isEmpty != false {
                throw ValidationError("--start is required for \(resolvedNotation.rawValue) grammars")
            }
            if lexer == .dfa, parser != .earley {
                throw ValidationError("--lexer dfa currently requires --parser earley")
            }
            if let actions, !FileManager.default.fileExists(atPath: actions) {
                throw ValidationError("AST action file does not exist: \(actions)")
            }
        }

        mutating func run() throws {
            let grammarText = try String(contentsOfFile: grammarFile, encoding: .utf8)
            let source = try String(contentsOfFile: sourceFile, encoding: .utf8)
            let grammar = try loadGrammar(grammarText)

            if emit.contains(.grammar) {
                print(grammar)
            }

            let parseTrees = try parse(source: source, grammar: grammar)
            let forest = try GeneralizedParseTreeAdapter(source: source, file: sourceFile)
                .adapt(parseTrees, ambiguity: ambiguity.policy)

            if emit.contains(.tokens), lexer == .dfa {
                let stream = try makeLexerStream(source: source, grammar: grammar)
                for (index, item) in try stream.terminals().enumerated() {
                    print("[\(index)] \(source[item.range])")
                }
            }
            if emit.contains(.trees) {
                for (index, tree) in forest.trees.enumerated() {
                    if forest.trees.count > 1 { print("Derivation \(index + 1):") }
                    print(tree.formattedTree())
                }
            }
            if parseOnly { return }

            let compiler = Compiler()
            let ast: ASTNode
            if let actions {
                guard let tree = forest.trees.first else { throw ValidationError("The parser produced no syntax tree") }
                let mapping = try ASTMapping(json: Data(contentsOf: URL(fileURLWithPath: actions)))
                ast = try ASTBuilder(mapping: mapping).build(from: tree)
            } else {
                ast = try compiler.parse(source, file: sourceFile)
            }
            let artifacts = try compiler.analyze(ast)
            if emit.contains(.ast) { print(ast) }
            if emit.contains(.typedAST) { print(artifacts.typedAST) }
            if emit.contains(.ir) {
                artifacts.ir.operations.enumerated().forEach { print("[\($0.offset)] \($0.element)") }
            }

            switch target {
            case .stack:
                let compilation = try StackCodeGenerator.generate(artifacts.ir)
                if emit.contains(.bytecode) {
                    compilation.instructions.enumerated().forEach { print("[\($0.offset)] \($0.element)") }
                }
                if let output {
                    try BytecodeSerializer.write(.stack(compilation), to: URL(fileURLWithPath: output))
                }
                let machine = StackMachine(bytecode: compilation.instructions, localCount: compilation.localCount)
                let result = trace ? try machine.executeWithTrace() : try machine.execute()
                if emit.contains(.result) { print("Result: \(result ?? .null)") }
            case .register:
                let compilation = try RegisterCodeGenerator.generate(artifacts.ir)
                if emit.contains(.bytecode) {
                    compilation.instructions.enumerated().forEach { print("[\($0.offset)] \($0.element)") }
                }
                if let output {
                    try BytecodeSerializer.write(.register(compilation), to: URL(fileURLWithPath: output))
                }
                let machine = RegisterMachine(bytecode: compilation.instructions, localCount: compilation.localCount)
                let result = trace ? try machine.executeWithTrace() : try machine.execute()
                if emit.contains(.result) { print("Result: \(result ?? .null)") }
            }
        }

        private var resolvedNotation: GrammarNotation {
            notation ?? GrammarNotation(rawValue: URL(fileURLWithPath: grammarFile).pathExtension.lowercased()) ?? .gen
        }

        private func loadGrammar(_ text: String) throws -> Grammar {
            switch resolvedNotation {
            case .bnf: return try Grammar(bnf: text, start: start!)
            case .ebnf: return try Grammar(ebnf: text, start: start!)
            case .wsn: return try Grammar(wsn: text, start: start!)
            case .gen: return try Grammar(gen: text)
            }
        }

        private func parse(source: String, grammar: Grammar) throws -> [ParseTree] {
            if lexer == .dfa {
                let stream = try makeLexerStream(source: source, grammar: grammar)
                let parser = EarleyParser(grammar: grammar)
                let result = try parser.parse(stream: stream)
                guard result.isSuccessful, let graph = result.sppfGraph else {
                    throw ValidationError("Earley parser rejected the source")
                }
                let ranges = try stream.terminals().map(\.range)
                return graph.buildAllParseTrees(
                    startSymbol: grammar.start.name,
                    ranges: ranges,
                    string: source
                )
            }
            switch parser {
            case .earley: return try EarleyParser(grammar: grammar).allSyntaxTrees(for: source)
            case .cyk: return try CYKParser(grammar: grammar).allSyntaxTrees(for: source)
            case .rnglr: return try RNGLRParser(grammar: grammar).allSyntaxTrees(for: source)
            }
        }

        private func makeLexerStream(source: String, grammar: Grammar) throws -> LexerTokenStream {
            var builder = LexerBuilder()
            var tokenID = 0
            func add(_ pattern: String, name: String, priority: Int) {
                builder.addRule(
                    pattern: pattern,
                    token: TokenClass(id: tokenID, name: name, priority: priority)
                )
                tokenID += 1
            }
            for terminal in grammar.terminals {
                switch terminal {
                case .string(let literal) where !literal.isEmpty:
                    guard !literal.contains("\"") else {
                        throw ValidationError("DFA lexer cannot quote terminal \(literal.debugDescription)")
                    }
                    add(lexerPattern(for: literal), name: literal, priority: 0)
                case .stringList(let alternatives):
                    for literal in alternatives where !literal.isEmpty {
                        guard !literal.contains("\"") else {
                            throw ValidationError("DFA lexer cannot quote terminal \(literal.debugDescription)")
                        }
                        add(lexerPattern(for: literal), name: literal, priority: 0)
                    }
                case .characterRange(let range):
                    add("[\(range.lowerBound)-\(range.upperBound)]", name: "\(range)", priority: 2)
                case .regularExpression(let expression):
                    add(expression.pattern, name: expression.pattern, priority: 2)
                case .meta, .string:
                    break
                }
            }
            builder.addSkip(" ")
            builder.addSkip("\\t")
            builder.addSkip("\\n")
            builder.addSkip("\\r")
            return try LexerTokenStream(source: source, lexer: builder.build())
        }

        private func lexerPattern(for literal: String) -> String {
            let reserved = Set("\\~&|?*+()[]{}.^$<>-\"".map { $0 })
            var pattern = ""
            for character in literal {
                if reserved.contains(character) { pattern.append("\\") }
                pattern.append(character)
            }
            return pattern
        }
    }
}
