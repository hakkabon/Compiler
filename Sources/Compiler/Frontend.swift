//
//  Frontend.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

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

public struct ASTParameterAction: Codable, Equatable, Sendable {
    public let nameChild: Int
    public let type: String
    public init(nameChild: Int, type: String) { self.nameChild = nameChild; self.type = type }
}

public struct ASTFieldAction: Codable, Equatable, Sendable {
    public let nameChild: Int
    public let valueChild: Int?
    public let type: String?
    public init(nameChild: Int, valueChild: Int? = nil, type: String? = nil) {
        self.nameChild = nameChild; self.valueChild = valueChild; self.type = type
    }
}

public enum ASTAction: Codable, Equatable, Sendable {
    case passThrough
    case integer
    case floatingPoint
    case string
    case boolean
    case null
    case identifier
    case unary(operatorChild: Int, operandChild: Int)
    case binary(leftChild: Int, operatorChild: Int, rightChild: Int)
    case program(declarationChildren: [Int], bodyChild: Int)
    case block(children: [Int])
    case variableDeclaration(nameChild: Int, initializerChild: Int?, type: String?)
    case assignment(nameChild: Int, valueChild: Int)
    case print(valueChild: Int)
    case read(nameChild: Int)
    case expressionStatement(valueChild: Int)
    case ifStatement(conditionChild: Int, thenChild: Int, elseChild: Int?)
    case whileStatement(conditionChild: Int, bodyChild: Int)
    case functionDeclaration(nameChild: Int, parameters: [ASTParameterAction], returnType: String, bodyChild: Int)
    case call(nameChild: Int, argumentChildren: [Int])
    case returnStatement(valueChild: Int?)
    case typeDeclaration(nameChild: Int, fields: [ASTFieldAction])
    case arrayLiteral(children: [Int])
    case index(collectionChild: Int, indexChild: Int)
    case indexAssignment(nameChild: Int, indexChild: Int, valueChild: Int)
    case recordLiteral(nameChild: Int, fields: [ASTFieldAction])
    case member(baseChild: Int, nameChild: Int)
    case memberAssignment(variableChild: Int, fieldChild: Int, valueChild: Int)
}

public struct ASTMapping: Codable, Sendable {
    public static let formatVersion = 1
    public let version: Int
    public let actions: [String: ASTAction]
    public init(version: Int = formatVersion, actions: [String: ASTAction]) {
        self.version = version; self.actions = actions
    }

    public init(json data: Data) throws {
        self = try JSONDecoder().decode(ASTMapping.self, from: data)
        guard version == Self.formatVersion else {
            throw Diagnostic(stage: .parsing, message: "Unsupported AST action format version \(version)")
        }
    }

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
        case .program(let declarations, let body):
            return .program(declarations: try declarations.map { try build(from: child($0, node)) },
                            body: try build(from: child(body, node)), type: .null)
        case .block(let children):
            return .block(try children.map { try build(from: child($0, node)) }, type: .null)
        case .variableDeclaration(let name, let initializer, let type):
            return .varDecl(name: try token(name, node), initializer: try initializer.map { try build(from: child($0, node)) },
                            type: try parsedType(type) ?? .any)
        case .assignment(let name, let value):
            return .assignment(variable: try token(name, node), value: try build(from: child(value, node)), type: .null)
        case .print(let value): return .print(try build(from: child(value, node)), type: .null)
        case .read(let name): return .read(name: try token(name, node), type: .null)
        case .expressionStatement(let value): return .expressionStatement(try build(from: child(value, node)), type: .null)
        case .ifStatement(let condition, let thenChild, let elseChild):
            return .ifStmt(condition: try build(from: child(condition, node)),
                           thenBranch: try build(from: child(thenChild, node)),
                           elseBranch: try elseChild.map { try build(from: child($0, node)) }, type: .null)
        case .whileStatement(let condition, let body):
            return .whileStmt(condition: try build(from: child(condition, node)),
                              body: try build(from: child(body, node)), type: .null)
        case .functionDeclaration(let name, let parameters, let returnType, let body):
            return .functionDecl(name: try token(name, node),
                parameters: try parameters.map { FunctionParameter(name: try token($0.nameChild, node), type: try parsedType($0.type)!) },
                returnType: try parsedType(returnType)!, body: try build(from: child(body, node)), type: .null)
        case .call(let name, let arguments):
            return .call(name: try token(name, node), arguments: try arguments.map { try build(from: child($0, node)) }, type: .any)
        case .returnStatement(let value):
            return .returnStmt(try value.map { try build(from: child($0, node)) }, type: .null)
        case .typeDeclaration(let name, let fields):
            return .typeDecl(name: try token(name, node), fields: try fields.map {
                guard let type = try parsedType($0.type) else { throw shape(node, "a field type") }
                return TypeField(name: try token($0.nameChild, node), type: type)
            }, type: .null)
        case .arrayLiteral(let children):
            return .arrayLiteral(try children.map { try build(from: child($0, node)) }, type: .any)
        case .index(let collection, let index):
            return .index(collection: try build(from: child(collection, node)), index: try build(from: child(index, node)), type: .any)
        case .indexAssignment(let name, let index, let value):
            return .indexAssignment(variable: try token(name, node), index: try build(from: child(index, node)),
                                    value: try build(from: child(value, node)), type: .null)
        case .recordLiteral(let name, let fields):
            return .recordLiteral(name: try token(name, node), fields: try fields.map {
                guard let value = $0.valueChild else { throw shape(node, "a record field value") }
                return RecordFieldInitializer(name: try token($0.nameChild, node), value: try build(from: child(value, node)))
            }, type: .record(try token(name, node)))
        case .member(let base, let name):
            return .member(base: try build(from: child(base, node)), name: try token(name, node), type: .any)
        case .memberAssignment(let variable, let field, let value):
            return .memberAssignment(variable: try token(variable, node), field: try token(field, node),
                                     value: try build(from: child(value, node)), type: .null)
        }
    }

    private func child(_ index: Int, _ node: SyntaxNode) throws -> SyntaxNode {
        guard node.children.indices.contains(index) else { throw shape(node, "child \(index)") }
        return node.children[index]
    }
    private func token(_ index: Int, _ node: SyntaxNode) throws -> String {
        guard let text = try child(index, node).token?.lexeme else { throw shape(node, "token child \(index)") }
        return text
    }
    private func parsedType(_ text: String?) throws -> TypeInfo? {
        guard let text else { return nil }
        guard let type = TypeInfo.parse(text) else {
            throw Diagnostic(stage: .parsing, message: "Invalid type '\(text)' in AST action")
        }
        return type
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
            if match("var") { statements.append(try variableDeclaration()) }
            else if match("func") { declarations.append(try functionDeclaration()) }
            else if match("type") { declarations.append(try typeDeclaration()) }
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
            declaredType = try parseType()
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
                let type = try parseType()
                guard type != .any else { throw error("'any' is not a valid parameter type") }
                parameters.append(FunctionParameter(name: parameterName, type: type))
            } while match(",")
        }
        try consume(")", "Expected ')' after parameters")
        var returnType: TypeInfo = .null
        if match(":") {
            let type = try parseType()
            guard type != .any else { throw error("'any' is not a valid return type") }
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

    private func typeDeclaration() throws -> ASTNode {
        let name = try consumeIdentifier("Expected type name")
        try consume("{", "Expected '{' after type name")
        var fields: [TypeField] = []
        while !check("}") {
            let field = try consumeIdentifier("Expected field name")
            try consume(":", "Expected ':' after field name")
            fields.append(TypeField(name: field, type: try parseType()))
            try consume(";", "Expected ';' after field")
        }
        try consume("}", "Expected '}' after type declaration")
        return .typeDecl(name: name, fields: fields, type: .null)
    }

    private func parseType() throws -> TypeInfo {
        let name = try consumeIdentifier("Expected type name")
        guard var type = TypeInfo.parse(name) else { throw error("Invalid type '\(name)'") }
        while match("[") {
            try consume("]", "Expected ']' in array type")
            type = .array(type)
        }
        return type
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
        if current.kind == .identifier, peek.text == "[" {
            let name = advance().text
            _ = advance()
            let index = try expression()
            try consume("]", "Expected ']' after index")
            try consume("=", "Expected '=' after indexed target")
            let value = try expression()
            try consume(";", "Expected ';' after assignment")
            return .indexAssignment(variable: name, index: index, value: value, type: .null)
        }
        if current.kind == .identifier, peek.text == "." {
            let name = advance().text; _ = advance()
            let field = try consumeIdentifier("Expected field name")
            try consume("=", "Expected '=' after field")
            let value = try expression()
            try consume(";", "Expected ';' after assignment")
            return .memberAssignment(variable: name, field: field, value: value, type: .null)
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
        return try postfix()
    }

    private func postfix() throws -> ASTNode {
        var node = try primary()
        while true {
            if match("[") {
                let index = try expression()
                try consume("]", "Expected ']' after index")
                node = .index(collection: node, index: index, type: .any)
            } else if match(".") {
                node = .member(base: node, name: try consumeIdentifier("Expected field name"), type: .any)
            } else { break }
        }
        return node
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
                if match("{") {
                    var fields: [RecordFieldInitializer] = []
                    if !check("}") {
                        repeat {
                            let name = try consumeIdentifier("Expected field name")
                            try consume(":", "Expected ':' after field name")
                            fields.append(RecordFieldInitializer(name: name, value: try expression()))
                        } while match(",")
                    }
                    try consume("}", "Expected '}' after record literal")
                    return .recordLiteral(name: token.text, fields: fields, type: .record(token.text))
                }
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
        case .symbol where token.text == "[":
            var elements: [ASTNode] = []
            if !check("]") {
                repeat { elements.append(try expression()) } while match(",")
            }
            try consume("]", "Expected ']' after array literal")
            return .arrayLiteral(elements, type: .any)
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
            } else if "{}[]().;,:+-*/%=<>".contains(c) {
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
