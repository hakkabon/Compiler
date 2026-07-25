import Foundation

public struct SyntaxToken: Equatable, Sendable {
    public let kind: String
    public let lexeme: String
    public let range: SourceRange

    public init(kind: String, lexeme: String, range: SourceRange) {
        self.kind = kind
        self.lexeme = lexeme
        self.range = range
    }
}

/// Compiler-owned boundary for syntax produced by any parser package.
public struct SyntaxNode: Equatable, Sendable {
    public let rule: String
    public let token: SyntaxToken?
    public let children: [SyntaxNode]
    public let range: SourceRange?

    public init(rule: String, token: SyntaxToken? = nil, children: [SyntaxNode] = [], range: SourceRange? = nil) {
        self.rule = rule
        self.token = token
        self.children = children
        self.range = range ?? token?.range
    }
}

/// Adapt a dependency-specific tree without exposing it to the compiler core.
public protocol SyntaxTreeAdapter {
    associatedtype ExternalTree
    func adapt(_ tree: ExternalTree) throws -> SyntaxNode
}

public enum ASTAction: Equatable, Sendable {
    case passThrough
    case integer
    case floatingPoint
    case string
    case boolean
    case null
    case identifier
    case unary(operatorChild: Int, operandChild: Int)
    case binary(leftChild: Int, operatorChild: Int, rightChild: Int)
}

public struct ASTMapping: Sendable {
    public let actions: [String: ASTAction]
    public init(actions: [String: ASTAction]) { self.actions = actions }

    public static let expressions = ASTMapping(actions: [
        "expression": .passThrough,
        "group": .passThrough,
        "integer": .integer,
        "float": .floatingPoint,
        "string": .string,
        "boolean": .boolean,
        "null": .null,
        "identifier": .identifier,
        "unary": .unary(operatorChild: 0, operandChild: 1),
        "binary": .binary(leftChild: 0, operatorChild: 1, rightChild: 2),
    ])
}

/// Declarative syntax-tree to AST conversion for parser integrations.
public final class ASTBuilder {
    private let mapping: ASTMapping
    public init(mapping: ASTMapping = .expressions) { self.mapping = mapping }

    public func build(from node: SyntaxNode) throws -> ASTNode {
        guard let action = mapping.actions[node.rule] else {
            throw Diagnostic(stage: .parsing, message: "No AST action for grammar rule '\(node.rule)'", range: node.range)
        }
        switch action {
        case .passThrough:
            guard node.children.count == 1 else { throw shape(node, "one child") }
            return try build(from: node.children[0])
        case .integer:
            guard let text = node.token?.lexeme, let value = Int64(text) else { throw shape(node, "an integer token") }
            return .intLiteral(value, type: .int)
        case .floatingPoint:
            guard let text = node.token?.lexeme, let value = Double(text) else { throw shape(node, "a floating-point token") }
            return .floatLiteral(value, type: .float)
        case .string:
            guard let text = node.token?.lexeme else { throw shape(node, "a string token") }
            return .stringLiteral(String(text.dropFirst().dropLast()), type: .string)
        case .boolean:
            guard let text = node.token?.lexeme, text == "true" || text == "false" else { throw shape(node, "a boolean token") }
            return .booleanLiteral(text == "true", type: .boolean)
        case .null:
            return .nullLiteral(type: .null)
        case .identifier:
            guard let text = node.token?.lexeme else { throw shape(node, "an identifier token") }
            return .variable(text, type: .any)
        case .unary(let operatorChild, let operandChild):
            guard node.children.indices.contains(operatorChild), node.children.indices.contains(operandChild),
                  let op = node.children[operatorChild].token?.lexeme else { throw shape(node, "unary operator and operand children") }
            return .unary(op: op, operand: try build(from: node.children[operandChild]), type: .any)
        case .binary(let leftChild, let operatorChild, let rightChild):
            guard node.children.indices.contains(leftChild), node.children.indices.contains(operatorChild),
                  node.children.indices.contains(rightChild),
                  let op = node.children[operatorChild].token?.lexeme else { throw shape(node, "binary operand/operator children") }
            return .binary(
                op: op,
                left: try build(from: node.children[leftChild]),
                right: try build(from: node.children[rightChild]),
                type: .any
            )
        }
    }

    private func shape(_ node: SyntaxNode, _ expected: String) -> Diagnostic {
        Diagnostic(stage: .parsing, message: "Rule '\(node.rule)' expected \(expected)", range: node.range)
    }
}

public struct GrammarTypeResolver: Sendable {
    private let signatures: [String: TypeInfo]
    public init(typeSignatures: [String: TypeInfo]) { signatures = typeSignatures }
    public func resolveType(for ruleName: String) -> TypeInfo? { signatures[ruleName] }
}

public final class SourceParser {
    private enum Kind: Equatable {
        case identifier, integer, float, string, symbol, eof
    }
    private struct Token {
        let kind: Kind
        let text: String
        let range: SourceRange
    }

    private var tokens: [Token] = []
    private var index = 0
    private var file: String?

    public init() {}

    public func parse(_ source: String, file: String? = nil) throws -> ASTNode {
        self.file = file
        tokens = try lex(source)
        index = 0
        var declarations: [ASTNode] = []
        var statements: [ASTNode] = []
        while !atEnd {
            if match("var") { declarations.append(try variableDeclaration()) }
            else if match("func") { declarations.append(try functionDeclaration()) }
            else { statements.append(try statement()) }
        }
        return .program(declarations: declarations, body: .block(statements, type: .null), type: .null)
    }

    public func parseExpression(_ source: String, file: String? = nil) throws -> ASTNode {
        self.file = file
        tokens = try lex(source)
        index = 0
        let result = try expression()
        guard atEnd else { throw error("Unexpected token '\(current.text)'") }
        return result
    }

    private func variableDeclaration() throws -> ASTNode {
        let name = try consumeIdentifier("Expected variable name")
        var declaredType: TypeInfo = .any
        if match(":") {
            let typeName = try consumeIdentifier("Expected type name")
            guard let type = TypeInfo(rawValue: typeName) else { throw error("Unknown type '\(typeName)'") }
            declaredType = type
        }
        let initializer = match("=") ? try expression() : nil
        try consume(";", "Expected ';' after declaration")
        return .varDecl(name: name, initializer: initializer, type: declaredType)
    }

    private func functionDeclaration() throws -> ASTNode {
        let name = try consumeIdentifier("Expected function name")
        try consume("(", "Expected '(' after function name")
        var parameters: [FunctionParameter] = []
        if !check(")") {
            repeat {
                let parameterName = try consumeIdentifier("Expected parameter name")
                try consume(":", "Expected ':' after parameter name")
                let typeName = try consumeIdentifier("Expected parameter type")
                guard let type = TypeInfo(rawValue: typeName), type != .any else {
                    throw error("Unknown parameter type '\(typeName)'")
                }
                parameters.append(FunctionParameter(name: parameterName, type: type))
            } while match(",")
        }
        try consume(")", "Expected ')' after parameters")
        var returnType: TypeInfo = .null
        if match(":") {
            let typeName = try consumeIdentifier("Expected return type")
            guard let type = TypeInfo(rawValue: typeName), type != .any else {
                throw error("Unknown return type '\(typeName)'")
            }
            returnType = type
        }
        return .functionDecl(
            name: name,
            parameters: parameters,
            returnType: returnType,
            body: try block(),
            type: .null
        )
    }

    private func statement() throws -> ASTNode {
        if match("print") {
            let value = try expression()
            try consume(";", "Expected ';' after print")
            return .print(value, type: .null)
        }
        if match("read") {
            let name = try consumeIdentifier("Expected variable name after read")
            try consume(";", "Expected ';' after read")
            return .read(name: name, type: .null)
        }
        if match("return") {
            let value = check(";") ? nil : try expression()
            try consume(";", "Expected ';' after return")
            return .returnStmt(value, type: .null)
        }
        if match("if") {
            try consume("(", "Expected '(' after if")
            let condition = try expression()
            try consume(")", "Expected ')' after condition")
            let thenBranch = try block()
            let elseBranch = match("else") ? try block() : nil
            return .ifStmt(condition: condition, thenBranch: thenBranch, elseBranch: elseBranch, type: .null)
        }
        if match("while") {
            try consume("(", "Expected '(' after while")
            let condition = try expression()
            try consume(")", "Expected ')' after condition")
            return .whileStmt(condition: condition, body: try block(), type: .null)
        }
        if check("{") { return try block() }
        if current.kind == .identifier, peek.text == "=" {
            let name = advance().text
            _ = advance()
            let value = try expression()
            try consume(";", "Expected ';' after assignment")
            return .assignment(variable: name, value: value, type: .null)
        }
        let value = try expression()
        try consume(";", "Expected ';' after expression")
        return .expressionStatement(value, type: .null)
    }

    private func block() throws -> ASTNode {
        try consume("{", "Expected '{'")
        var nodes: [ASTNode] = []
        while !check("}") && !atEnd {
            if match("var") { nodes.append(try variableDeclaration()) }
            else { nodes.append(try statement()) }
        }
        try consume("}", "Expected '}'")
        return .block(nodes, type: .null)
    }

    private func expression() throws -> ASTNode { try equality() }
    private func equality() throws -> ASTNode { try binary(next: comparison, operators: ["==", "!="]) }
    private func comparison() throws -> ASTNode { try binary(next: term, operators: ["<", "<=", ">", ">="]) }
    private func term() throws -> ASTNode { try binary(next: factor, operators: ["+", "-"]) }
    private func factor() throws -> ASTNode { try binary(next: unary, operators: ["*", "/", "%"]) }

    private func binary(next: () throws -> ASTNode, operators: Set<String>) throws -> ASTNode {
        var node = try next()
        while operators.contains(current.text) {
            let op = advance().text
            node = .binary(op: op, left: node, right: try next(), type: .any)
        }
        return node
    }

    private func unary() throws -> ASTNode {
        if match("-") { return .unary(op: "-", operand: try unary(), type: .any) }
        return try primary()
    }

    private func primary() throws -> ASTNode {
        let token = advance()
        switch token.kind {
        case .integer: return .intLiteral(Int64(token.text)!, type: .int)
        case .float: return .floatLiteral(Double(token.text)!, type: .float)
        case .string: return .stringLiteral(token.text, type: .string)
        case .identifier:
            switch token.text {
            case "true": return .booleanLiteral(true, type: .boolean)
            case "false": return .booleanLiteral(false, type: .boolean)
            case "null": return .nullLiteral(type: .null)
            default:
                if match("(") {
                    var arguments: [ASTNode] = []
                    if !check(")") {
                        repeat { arguments.append(try expression()) } while match(",")
                    }
                    try consume(")", "Expected ')' after arguments")
                    return .call(name: token.text, arguments: arguments, type: .any)
                }
                return .variable(token.text, type: .any)
            }
        case .symbol where token.text == "(":
            let node = try expression()
            try consume(")", "Expected ')' after expression")
            return node
        default: throw Diagnostic(stage: .parsing, message: "Expected expression, got '\(token.text)'", range: token.range)
        }
    }

    private var current: Token { tokens[index] }
    private var peek: Token { tokens[min(index + 1, tokens.count - 1)] }
    private var atEnd: Bool { current.kind == .eof }
    private func check(_ text: String) -> Bool { current.text == text }
    @discardableResult private func advance() -> Token { defer { if !atEnd { index += 1 } }; return current }
    private func match(_ text: String) -> Bool { guard check(text) else { return false }; _ = advance(); return true }
    private func consume(_ text: String, _ message: String) throws { guard match(text) else { throw error(message) } }
    private func consumeIdentifier(_ message: String) throws -> String {
        guard current.kind == .identifier else { throw error(message) }
        return advance().text
    }
    private func error(_ message: String) -> Diagnostic {
        Diagnostic(stage: .parsing, message: message, range: current.range)
    }

    private func lex(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var result: [Token] = []
        var offset = 0, line = 1, column = 1

        func location() -> SourceLocation { SourceLocation(offset: offset, line: line, column: column) }
        func range(_ start: SourceLocation) -> SourceRange { SourceRange(file: file, start: start, end: location()) }
        func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentifierPart(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while offset < characters.count {
            let c = characters[offset]
            if c == " " || c == "\t" || c == "\r" { offset += 1; column += 1; continue }
            if c == "\n" { offset += 1; line += 1; column = 1; continue }
            if c == "/", offset + 1 < characters.count, characters[offset + 1] == "/" {
                while offset < characters.count && characters[offset] != "\n" { offset += 1; column += 1 }
                continue
            }
            let start = location()
            if isIdentifierStart(c) {
                var text = ""
                while offset < characters.count && isIdentifierPart(characters[offset]) {
                    text.append(characters[offset]); offset += 1; column += 1
                }
                result.append(Token(kind: .identifier, text: text, range: range(start)))
                continue
            }
            if c.isNumber {
                var text = ""
                while offset < characters.count && characters[offset].isNumber {
                    text.append(characters[offset]); offset += 1; column += 1
                }
                var kind: Kind = .integer
                if offset < characters.count, characters[offset] == ".",
                   offset + 1 < characters.count, characters[offset + 1].isNumber {
                    kind = .float; text.append("."); offset += 1; column += 1
                    while offset < characters.count && characters[offset].isNumber {
                        text.append(characters[offset]); offset += 1; column += 1
                    }
                }
                result.append(Token(kind: kind, text: text, range: range(start)))
                continue
            }
            if c == "\"" {
                offset += 1; column += 1
                var text = ""
                while offset < characters.count && characters[offset] != "\"" {
                    guard characters[offset] != "\n" else {
                        throw Diagnostic(stage: .lexing, message: "Unterminated string literal", range: range(start))
                    }
                    text.append(characters[offset]); offset += 1; column += 1
                }
                guard offset < characters.count else {
                    throw Diagnostic(stage: .lexing, message: "Unterminated string literal", range: range(start))
                }
                offset += 1; column += 1
                result.append(Token(kind: .string, text: text, range: range(start)))
                continue
            }
            let two = offset + 1 < characters.count ? String([c, characters[offset + 1]]) : ""
            if ["==", "!=", "<=", ">="].contains(two) {
                offset += 2; column += 2
                result.append(Token(kind: .symbol, text: two, range: range(start)))
            } else if "{}();,:+-*/%=<>".contains(c) {
                offset += 1; column += 1
                result.append(Token(kind: .symbol, text: String(c), range: range(start)))
            } else {
                offset += 1; column += 1
                throw Diagnostic(stage: .lexing, message: "Unexpected character '\(c)'", range: range(start))
            }
        }
        let end = SourceLocation(offset: offset, line: line, column: column)
        result.append(Token(kind: .eof, text: "", range: SourceRange(file: file, start: end, end: end)))
        return result
    }
}
