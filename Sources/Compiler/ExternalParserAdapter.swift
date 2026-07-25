import Foundation
import Grammar
import Parser

public enum AmbiguityPolicy: String, CaseIterable, Sendable {
    case reject
    case first
    case all
}

public struct AdaptedParseForest: Sendable {
    public let trees: [SyntaxNode]
    public let wasAmbiguous: Bool

    public init(trees: [SyntaxNode], wasAmbiguous: Bool) {
        self.trees = trees
        self.wasAmbiguous = wasAmbiguous
    }
}

/// Converts the shared Parser package's `ParseTree` into the compiler-owned
/// `SyntaxNode` representation while preserving source ranges.
public struct GeneralizedParseTreeAdapter: SyntaxTreeAdapter {
    public typealias ExternalTree = ParseTree

    private let source: String
    private let file: String?

    public init(source: String, file: String? = nil) {
        self.source = source
        self.file = file
    }

    public func adapt(_ tree: ParseTree) throws -> SyntaxNode {
        switch tree {
        case .empty:
            return SyntaxNode(rule: "empty")
        case .leaf(let range):
            let sourceRange = makeRange(range)
            return SyntaxNode(
                rule: "terminal",
                token: SyntaxToken(
                    kind: "terminal",
                    lexeme: String(source[range]),
                    range: sourceRange
                ),
                range: sourceRange
            )
        case .node(let nonTerminal, children: let children):
            let adaptedChildren = try children.map(adapt)
            return SyntaxNode(
                rule: nonTerminal.name,
                children: adaptedChildren,
                range: merge(adaptedChildren.compactMap(\.range))
            )
        }
    }

    public func adapt(
        _ trees: [ParseTree],
        ambiguity policy: AmbiguityPolicy
    ) throws -> AdaptedParseForest {
        guard !trees.isEmpty else {
            throw Diagnostic(stage: .parsing, message: "Parser produced no syntax trees")
        }
        let ambiguous = trees.count > 1
        if ambiguous && policy == .reject {
            throw Diagnostic(
                stage: .parsing,
                message: "Grammar is ambiguous for this input (\(trees.count) derivations)"
            )
        }
        let selected = policy == .all ? trees : [trees[0]]
        return AdaptedParseForest(trees: try selected.map(adapt), wasAmbiguous: ambiguous)
    }

    private func makeRange(_ range: Range<String.Index>) -> SourceRange {
        SourceRange(
            file: file,
            start: location(at: range.lowerBound),
            end: location(at: range.upperBound)
        )
    }

    private func location(at index: String.Index) -> SourceLocation {
        let prefix = source[..<index]
        var line = 1
        var column = 1
        for character in prefix {
            if character == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return SourceLocation(
            offset: source.distance(from: source.startIndex, to: index),
            line: line,
            column: column
        )
    }

    private func merge(_ ranges: [SourceRange]) -> SourceRange? {
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return SourceRange(file: file, start: first.start, end: last.end)
    }
}

public extension SyntaxNode {
    func formattedTree(indent: String = "") -> String {
        let label = token.map { "\(rule) \"\($0.lexeme)\"" } ?? rule
        guard !children.isEmpty else { return indent + label }
        return ([indent + label] + children.map { $0.formattedTree(indent: indent + "  ") })
            .joined(separator: "\n")
    }
}
