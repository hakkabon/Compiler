import Compiler
import Earley_Parser
import Foundation
import Grammar
import Lexer
import Parser

public struct CompilerCorpusObservation: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let root: String?
    public let supported: Bool
    public let diagnostics: Int
    public let reason: String?

    public init(
        id: String,
        status: String,
        root: String? = nil,
        supported: Bool,
        diagnostics: Int,
        reason: String? = nil
    ) {
        self.id = id
        self.status = status
        self.root = root
        self.supported = supported
        self.diagnostics = diagnostics
        self.reason = reason
    }
}

public enum CompilerCorpusConformance {
    public static func evaluate(_ data: Data) throws -> [CompilerCorpusObservation] {
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard (1...5).contains(corpus.schemaVersion) else {
            throw ConformanceError("unsupported corpus schema version \(corpus.schemaVersion)")
        }

        var grammars: [String: Grammar] = [:]
        for model in corpus.grammars {
            guard grammars[model.id] == nil else {
                throw ConformanceError("duplicate grammar '\(model.id)'")
            }
            grammars[model.id] = makeGrammar(model)
        }

        var caseIDs = Set<String>()
        return try corpus.cases.map { testCase in
            guard caseIDs.insert(testCase.id).inserted else {
                throw ConformanceError("duplicate corpus case '\(testCase.id)'")
            }
            guard let grammar = grammars[testCase.grammar] else {
                throw ConformanceError("unknown grammar '\(testCase.grammar)' for '\(testCase.id)'")
            }
            return evaluate(testCase, with: grammar)
        }
    }

    private static func evaluate(_ testCase: CorpusCase, with grammar: Grammar) -> CompilerCorpusObservation {
        let stream = NormalizedTokenStream(kinds: testCase.expectedTokenKinds)
        let status: String
        let root: String?
        let diagnostics: Int

        do {
            let result = try EarleyParser(grammar: grammar).parse(stream: stream)
            if result.isSuccessful, let graph = result.sppfGraph {
                let tree = graph.buildParseTree(
                    startSymbol: grammar.start.name,
                    ranges: stream.ranges,
                    string: stream.source
                )
                _ = try GeneralizedParseTreeAdapter(source: stream.source).adapt(tree)
                status = "accepted"
                root = tree.root?.name ?? grammar.start.name
                diagnostics = 0
            } else {
                status = "rejected"
                root = nil
                diagnostics = 1
            }
        } catch {
            status = "rejected"
            root = nil
            diagnostics = 1
        }

        if testCase.tags.contains("recovery") {
            return CompilerCorpusObservation(
                id: testCase.id,
                status: status,
                root: root,
                supported: false,
                diagnostics: diagnostics,
                reason: "Compiler's generalized-parser integration does not expose syntax recovery."
            )
        }

        return CompilerCorpusObservation(
            id: testCase.id,
            status: status,
            root: root,
            supported: true,
            diagnostics: diagnostics
        )
    }

    private static func makeGrammar(_ model: CorpusGrammar) -> Grammar {
        let terminals = Set(model.terminals)
        return Grammar(
            productions: model.productions.map { production in
                Production(
                    goal: NonTerminal(name: production.lhs),
                    rule: production.rhs.map { symbol in
                        terminals.contains(symbol)
                            ? .terminal(Terminal(string: symbol))
                            : .nonTerminal(NonTerminal(name: symbol))
                    }
                )
            },
            start: NonTerminal(name: model.start),
            lexicalTokens: [:]
        )
    }
}

private struct Corpus: Decodable {
    let schemaVersion: Int
    let grammars: [CorpusGrammar]
    let cases: [CorpusCase]
}

private struct CorpusGrammar: Decodable {
    let id: String
    let start: String
    let terminals: [String]
    let productions: [CorpusProduction]
}

private struct CorpusProduction: Decodable {
    let lhs: String
    let rhs: [String]
}

private struct CorpusCase: Decodable {
    let id: String
    let grammar: String
    let expectedTokenKinds: [String]
    let tags: [String]
}

private struct NormalizedTokenStream: TokenStream {
    let source: String
    let values: [(Terminal, Range<String.Index>)]

    var count: Int { values.count }
    var ranges: [Range<String.Index>] { values.map(\.1) }

    init(kinds: [String]) {
        source = kinds.joined(separator: " ")
        var cursor = source.startIndex
        var result: [(Terminal, Range<String.Index>)] = []
        result.reserveCapacity(kinds.count)
        for kind in kinds {
            let end = source.index(cursor, offsetBy: kind.count)
            result.append((Terminal(string: kind), cursor..<end))
            cursor = end == source.endIndex ? end : source.index(after: end)
        }
        values = result
    }

    func terminal(at position: Int) throws -> (terminal: Terminal, range: Range<String.Index>) {
        values[position]
    }
}

private struct ConformanceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
