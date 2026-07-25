//
//  Model.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public struct SourceLocation: Equatable, Sendable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}

public struct SourceRange: Equatable, Sendable {
    public let file: String?
    public let start: SourceLocation
    public let end: SourceLocation

    public init(file: String? = nil, start: SourceLocation, end: SourceLocation) {
        self.file = file
        self.start = start
        self.end = end
    }
}

public struct Diagnostic: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Stage: String, Sendable { case lexing, parsing, semantic, lowering, validation, runtime }
    public let stage: Stage
    public let message: String
    public let range: SourceRange?

    public init(stage: Stage, message: String, range: SourceRange? = nil) {
        self.stage = stage
        self.message = message
        self.range = range
    }

    public var description: String {
        guard let range else { return "\(stage.rawValue.capitalized) error: \(message)" }
        let file = range.file.map { "\($0):" } ?? ""
        return "\(file)\(range.start.line):\(range.start.column): \(stage.rawValue) error: \(message)"
    }
}

public indirect enum TypeInfo: Hashable, CustomStringConvertible, Sendable {
    case int, float, string, boolean, null, any
    case array(TypeInfo)
    case record(String)

    public var description: String {
        switch self {
        case .int: return "int"
        case .float: return "float"
        case .string: return "string"
        case .boolean: return "boolean"
        case .null: return "null"
        case .any: return "any"
        case .array(let element): return "\(element)[]"
        case .record(let name): return name
        }
    }

    public static func parse(_ text: String) -> TypeInfo? {
        if text.hasSuffix("[]"), let element = parse(String(text.dropLast(2))) {
            return .array(element)
        }
        switch text {
        case "int": return .int
        case "float": return .float
        case "string": return .string
        case "boolean", "bool": return .boolean
        case "null", "void": return .null
        case "any": return .any
        default: return text.isEmpty ? nil : .record(text)
        }
    }
}

public indirect enum Value: Equatable, CustomStringConvertible, Sendable {
    case int(Int64)
    case float(Double)
    case string(String)
    case boolean(Bool)
    case null
    case array([Value])
    case record(name: String, fields: [String: Value])

    public var description: String {
        switch self {
        case .int(let value): return "\(value)"
        case .float(let value): return "\(value)"
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[\(values.map(\.description).joined(separator: ", "))]"
        case .record(let name, let fields):
            let body = fields.keys.sorted().map { "\($0): \(fields[$0]!)" }.joined(separator: ", ")
            return "\(name) { \(body) }"
        }
    }

    public var type: TypeInfo {
        switch self {
        case .int: return .int
        case .float: return .float
        case .string: return .string
        case .boolean: return .boolean
        case .null: return .null
        case .array(let values): return .array(values.first?.type ?? .any)
        case .record(let name, _): return .record(name)
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null, .boolean(false), .int(0), .float(0), .string(""), .array([]): return false
        default: return true
        }
    }
}

public struct TypeField: Equatable, Sendable {
    public let name: String
    public let type: TypeInfo
    public init(name: String, type: TypeInfo) { self.name = name; self.type = type }
}

public struct RecordFieldInitializer: Equatable, Sendable {
    public let name: String
    public let value: ASTNode
    public init(name: String, value: ASTNode) { self.name = name; self.value = value }
}

public struct FunctionParameter: Equatable, Sendable {
    public let name: String
    public let type: TypeInfo
    public init(name: String, type: TypeInfo) {
        self.name = name
        self.type = type
    }
}

public indirect enum ASTNode: Equatable, Sendable {
    case intLiteral(Int64, type: TypeInfo)
    case floatLiteral(Double, type: TypeInfo)
    case stringLiteral(String, type: TypeInfo)
    case booleanLiteral(Bool, type: TypeInfo)
    case nullLiteral(type: TypeInfo)
    case variable(String, type: TypeInfo)
    case binary(op: String, left: ASTNode, right: ASTNode, type: TypeInfo)
    case unary(op: String, operand: ASTNode, type: TypeInfo)
    case assignment(variable: String, value: ASTNode, type: TypeInfo)
    case ifStmt(condition: ASTNode, thenBranch: ASTNode, elseBranch: ASTNode?, type: TypeInfo)
    case whileStmt(condition: ASTNode, body: ASTNode, type: TypeInfo)
    case block([ASTNode], type: TypeInfo)
    case varDecl(name: String, initializer: ASTNode?, type: TypeInfo)
    case program(declarations: [ASTNode], body: ASTNode, type: TypeInfo)
    case print(ASTNode, type: TypeInfo)
    case read(name: String, type: TypeInfo)
    case expressionStatement(ASTNode, type: TypeInfo)
    case functionDecl(name: String, parameters: [FunctionParameter], returnType: TypeInfo, body: ASTNode, type: TypeInfo)
    case call(name: String, arguments: [ASTNode], type: TypeInfo)
    case returnStmt(ASTNode?, type: TypeInfo)
    case typeDecl(name: String, fields: [TypeField], type: TypeInfo)
    case arrayLiteral([ASTNode], type: TypeInfo)
    case index(collection: ASTNode, index: ASTNode, type: TypeInfo)
    case indexAssignment(variable: String, index: ASTNode, value: ASTNode, type: TypeInfo)
    case recordLiteral(name: String, fields: [RecordFieldInitializer], type: TypeInfo)
    case member(base: ASTNode, name: String, type: TypeInfo)
    case memberAssignment(variable: String, field: String, value: ASTNode, type: TypeInfo)

    public var type: TypeInfo {
        switch self {
        case .intLiteral(_, let type), .floatLiteral(_, let type),
             .stringLiteral(_, let type), .booleanLiteral(_, let type),
             .nullLiteral(let type), .variable(_, let type),
             .binary(_, _, _, let type), .unary(_, _, let type),
             .assignment(_, _, let type), .ifStmt(_, _, _, let type),
             .whileStmt(_, _, let type), .block(_, let type),
             .varDecl(_, _, let type), .program(_, _, let type),
             .print(_, let type), .read(_, let type),
             .expressionStatement(_, let type),
             .functionDecl(_, _, _, _, let type),
             .call(_, _, let type), .returnStmt(_, let type),
             .typeDecl(_, _, let type), .arrayLiteral(_, let type),
             .index(_, _, let type), .indexAssignment(_, _, _, let type),
             .recordLiteral(_, _, let type), .member(_, _, let type),
             .memberAssignment(_, _, _, let type):
            return type
        }
    }
}

public struct SymbolID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public struct Symbol: Equatable, Sendable {
    public let id: SymbolID
    public let name: String
    public let type: TypeInfo
    public let slot: Int
}

public struct TypeDefinition: Equatable, Sendable {
    public let name: String
    public let fields: [TypeField]
    public init(name: String, fields: [TypeField]) { self.name = name; self.fields = fields }
}

public struct ResolvedRecordField: Equatable, Sendable {
    public let name: String
    public let value: ResolvedASTNode
    public init(name: String, value: ResolvedASTNode) { self.name = name; self.value = value }
}

/// The typed tree deliberately differs from the source tree: every variable
/// occurrence carries its declaration's stable identity and storage slot.
public indirect enum ResolvedASTNode: Equatable, Sendable {
    case literal(Value, type: TypeInfo)
    case variable(Symbol, type: TypeInfo)
    case binary(op: String, left: ResolvedASTNode, right: ResolvedASTNode, type: TypeInfo)
    case unary(op: String, operand: ResolvedASTNode, type: TypeInfo)
    case assignment(symbol: Symbol, value: ResolvedASTNode, type: TypeInfo)
    case ifStmt(condition: ResolvedASTNode, thenBranch: ResolvedASTNode, elseBranch: ResolvedASTNode?, type: TypeInfo)
    case whileStmt(condition: ResolvedASTNode, body: ResolvedASTNode, type: TypeInfo)
    case block([ResolvedASTNode], type: TypeInfo)
    case varDecl(symbol: Symbol, initializer: ResolvedASTNode?, type: TypeInfo)
    case program(declarations: [ResolvedASTNode], body: ResolvedASTNode, type: TypeInfo)
    case print(ResolvedASTNode, type: TypeInfo)
    case read(Symbol, type: TypeInfo)
    case expressionStatement(ResolvedASTNode, type: TypeInfo)
    case functionDecl(name: String, parameters: [Symbol], returnType: TypeInfo, body: ResolvedASTNode, type: TypeInfo)
    case call(name: String, arguments: [ResolvedASTNode], type: TypeInfo)
    case returnStmt(ResolvedASTNode?, type: TypeInfo)
    case typeDecl(TypeDefinition, type: TypeInfo)
    case arrayLiteral([ResolvedASTNode], type: TypeInfo)
    case index(collection: ResolvedASTNode, index: ResolvedASTNode, type: TypeInfo)
    case indexAssignment(symbol: Symbol, index: ResolvedASTNode, value: ResolvedASTNode, type: TypeInfo)
    case recordLiteral(name: String, fields: [ResolvedRecordField], type: TypeInfo)
    case member(base: ResolvedASTNode, name: String, type: TypeInfo)
    case memberAssignment(symbol: Symbol, field: String, value: ResolvedASTNode, type: TypeInfo)

    public var type: TypeInfo {
        switch self {
        case .literal(_, let t), .variable(_, let t), .binary(_, _, _, let t), .unary(_, _, let t),
             .assignment(_, _, let t), .ifStmt(_, _, _, let t), .whileStmt(_, _, let t),
             .block(_, let t), .varDecl(_, _, let t), .program(_, _, let t), .print(_, let t),
             .read(_, let t), .expressionStatement(_, let t), .functionDecl(_, _, _, _, let t),
             .call(_, _, let t), .returnStmt(_, let t), .typeDecl(_, let t),
             .arrayLiteral(_, let t), .index(_, _, let t), .indexAssignment(_, _, _, let t),
             .recordLiteral(_, _, let t), .member(_, _, let t), .memberAssignment(_, _, _, let t):
            return t
        }
    }
}
