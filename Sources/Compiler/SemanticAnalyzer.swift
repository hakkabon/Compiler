//
//  SementicAnalyzer.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public struct SemanticResult: Sendable {
    public let sourceAST: ASTNode
    public let ast: ResolvedASTNode
    public let symbols: [Symbol]
    public let functions: [String: FunctionSignature]
    public let types: [String: TypeDefinition]
}

public struct FunctionSignature: Equatable, Sendable {
    public let name: String
    public let parameters: [FunctionParameter]
    public let returnType: TypeInfo
}

public final class SemanticAnalyzer {
    private var scopes: [[String: Symbol]] = [[:]]
    private var symbols: [Symbol] = []
    private var functions: [String: FunctionSignature] = [:]
    private var types: [String: TypeDefinition] = [:]
    private var currentReturnType: TypeInfo?

    public init() {}

    public func analyze(_ node: ASTNode) throws -> ResolvedASTNode { try analyzeProgram(node).ast }

    public func analyzeProgram(_ node: ASTNode) throws -> SemanticResult {
        scopes = [[:]]; symbols = []; functions = [:]; types = [:]; currentReturnType = nil
        if case .program(let declarations, _, _) = node {
            for declaration in declarations {
                if case .typeDecl(let name, let fields, _) = declaration {
                    guard types[name] == nil else { throw error("Type '\(name)' is already declared") }
                    guard Set(fields.map(\.name)).count == fields.count else {
                        throw error("Type '\(name)' contains duplicate fields")
                    }
                    types[name] = TypeDefinition(name: name, fields: fields)
                }
            }
            for declaration in declarations {
                if case .functionDecl(let name, let parameters, let returnType, _, _) = declaration {
                    guard functions[name] == nil else { throw error("Function '\(name)' is already declared") }
                    functions[name] = FunctionSignature(name: name, parameters: parameters, returnType: returnType)
                }
            }
        }
        try validateDeclaredTypes()
        let ast = try infer(node)
        return SemanticResult(sourceAST: node, ast: ast, symbols: symbols, functions: functions, types: types)
    }

    public func declareVariable(_ name: String, type: TypeInfo) throws { _ = try declare(name, type: type) }

    private func declare(_ name: String, type: TypeInfo) throws -> Symbol {
        guard scopes[scopes.count - 1][name] == nil else { throw error("Symbol '\(name)' is already declared in this scope") }
        let symbol = Symbol(id: SymbolID(symbols.count), name: name, type: type, slot: symbols.count)
        scopes[scopes.count - 1][name] = symbol; symbols.append(symbol)
        return symbol
    }

    private func resolve(_ name: String) throws -> Symbol {
        for scope in scopes.reversed() { if let symbol = scope[name] { return symbol } }
        throw error("Undefined variable '\(name)'")
    }

    private func infer(_ node: ASTNode) throws -> ResolvedASTNode {
        switch node {
        case .intLiteral(let value, _): return .literal(.int(value), type: .int)
        case .floatLiteral(let value, _): return .literal(.float(value), type: .float)
        case .stringLiteral(let value, _): return .literal(.string(value), type: .string)
        case .booleanLiteral(let value, _): return .literal(.boolean(value), type: .boolean)
        case .nullLiteral: return .literal(.null, type: .null)
        case .variable(let name, _):
            let symbol = try resolve(name); return .variable(symbol, type: symbol.type)
        case .binary(let op, let left, let right, _):
            let lhs = try infer(left), rhs = try infer(right)
            return .binary(op: op, left: lhs, right: rhs, type: try binaryType(op, lhs.type, rhs.type))
        case .unary(let op, let operand, _):
            let value = try infer(operand)
            guard op == "-", value.type == .int || value.type == .float else { throw error("Unary '\(op)' requires a numeric operand") }
            return .unary(op: op, operand: value, type: value.type)
        case .varDecl(let name, let initializer, let declaredType):
            try requireKnown(declaredType)
            let value = try initializer.map(infer)
            let type = declaredType == .any ? (value?.type ?? .any) : declaredType
            guard type != .any else { throw error("Declaration '\(name)' needs a type or initializer") }
            if let value { try requireAssignable(value.type, to: type, name: name) }
            let symbol = try declare(name, type: type)
            return .varDecl(symbol: symbol, initializer: value, type: type)
        case .assignment(let name, let value, _):
            let symbol = try resolve(name), value = try infer(value)
            try requireAssignable(value.type, to: symbol.type, name: name)
            return .assignment(symbol: symbol, value: value, type: .null)
        case .ifStmt(let condition, let thenBranch, let elseBranch, _):
            let condition = try infer(condition); try requireBoolean(condition)
            return .ifStmt(condition: condition, thenBranch: try inferScoped(thenBranch),
                           elseBranch: try elseBranch.map(inferScoped), type: .null)
        case .whileStmt(let condition, let body, _):
            let condition = try infer(condition); try requireBoolean(condition)
            return .whileStmt(condition: condition, body: try inferScoped(body), type: .null)
        case .block(let statements, _):
            scopes.append([:]); defer { scopes.removeLast() }
            return .block(try statements.map(infer), type: .null)
        case .program(let declarations, let body, _):
            return .program(declarations: try declarations.map(infer), body: try infer(body), type: .null)
        case .print(let expression, _): return .print(try infer(expression), type: .null)
        case .read(let name, _):
            let symbol = try resolve(name)
            guard symbol.type == .int else { throw error("read currently supports integer variables only") }
            return .read(symbol, type: .null)
        case .expressionStatement(let expression, _): return .expressionStatement(try infer(expression), type: .null)
        case .functionDecl(let name, let parameters, let returnType, let body, _):
            scopes.append([:]); let previous = currentReturnType; currentReturnType = returnType
            defer { currentReturnType = previous; scopes.removeLast() }
            let symbols = try parameters.map { try declare($0.name, type: $0.type) }
            return .functionDecl(name: name, parameters: symbols, returnType: returnType, body: try infer(body), type: .null)
        case .call(let name, let arguments, _):
            guard let signature = functions[name] else { throw error("Undefined function '\(name)'") }
            guard signature.parameters.count == arguments.count else {
                throw error("Function '\(name)' expects \(signature.parameters.count) argument(s), got \(arguments.count)")
            }
            let values = try arguments.map(infer)
            for (value, parameter) in zip(values, signature.parameters) {
                try requireAssignable(value.type, to: parameter.type, name: parameter.name)
            }
            return .call(name: name, arguments: values, type: signature.returnType)
        case .returnStmt(let value, _):
            guard let expected = currentReturnType else { throw error("return is only valid inside a function") }
            let value = try value.map(infer)
            if expected == .null {
                guard value == nil else { throw error("Void function cannot return a value") }
            } else {
                guard let value else { throw error("Function must return \(expected)") }
                try requireAssignable(value.type, to: expected, name: "return value")
            }
            return .returnStmt(value, type: .null)
        case .typeDecl(let name, let fields, _):
            return .typeDecl(TypeDefinition(name: name, fields: fields), type: .null)
        case .arrayLiteral(let elements, _):
            let values = try elements.map(infer)
            guard let first = values.first else { return .arrayLiteral([], type: .array(.any)) }
            for value in values.dropFirst() { try requireAssignable(value.type, to: first.type, name: "array element") }
            return .arrayLiteral(values, type: .array(first.type))
        case .index(let collection, let index, _):
            let collection = try infer(collection), index = try infer(index)
            guard index.type == .int else { throw error("Array index must be int") }
            guard case .array(let element) = collection.type else { throw error("Cannot index value of type \(collection.type)") }
            return .index(collection: collection, index: index, type: element)
        case .indexAssignment(let name, let index, let value, _):
            let symbol = try resolve(name), index = try infer(index), value = try infer(value)
            guard index.type == .int, case .array(let element) = symbol.type else { throw error("Indexed assignment requires an array and int index") }
            try requireAssignable(value.type, to: element, name: name)
            return .indexAssignment(symbol: symbol, index: index, value: value, type: .null)
        case .recordLiteral(let name, let initializers, _):
            guard let definition = types[name] else { throw error("Undefined type '\(name)'") }
            guard Set(initializers.map(\.name)) == Set(definition.fields.map(\.name)),
                  initializers.count == definition.fields.count else { throw error("Record '\(name)' must initialize every field exactly once") }
            let values = try initializers.map { initializer -> ResolvedRecordField in
                let value = try infer(initializer.value)
                let field = definition.fields.first { $0.name == initializer.name }!
                try requireAssignable(value.type, to: field.type, name: initializer.name)
                return ResolvedRecordField(name: initializer.name, value: value)
            }
            return .recordLiteral(name: name, fields: values, type: .record(name))
        case .member(let base, let name, _):
            let base = try infer(base)
            guard case .record(let typeName) = base.type, let field = types[typeName]?.fields.first(where: { $0.name == name }) else {
                throw error("Type \(base.type) has no field '\(name)'")
            }
            return .member(base: base, name: name, type: field.type)
        case .memberAssignment(let name, let fieldName, let value, _):
            let symbol = try resolve(name)
            guard case .record(let typeName) = symbol.type,
                  let field = types[typeName]?.fields.first(where: { $0.name == fieldName }) else {
                throw error("Type \(symbol.type) has no field '\(fieldName)'")
            }
            let value = try infer(value); try requireAssignable(value.type, to: field.type, name: fieldName)
            return .memberAssignment(symbol: symbol, field: fieldName, value: value, type: .null)
        }
    }

    private func inferScoped(_ node: ASTNode) throws -> ResolvedASTNode {
        scopes.append([:]); defer { scopes.removeLast() }; return try infer(node)
    }
    private func requireBoolean(_ node: ResolvedASTNode) throws {
        guard node.type == .boolean else { throw error("Control-flow condition must be boolean, got \(node.type)") }
    }
    private func requireAssignable(_ source: TypeInfo, to target: TypeInfo, name: String) throws {
        guard target == .any || source == target || source == .int && target == .float ||
                source == .array(.any) && { if case .array = target { return true }; return false }() else {
            throw error("Cannot assign \(source) to \(target) variable '\(name)'")
        }
    }
    private func requireKnown(_ type: TypeInfo) throws {
        switch type {
        case .record(let name): if types[name] == nil { throw error("Undefined type '\(name)'") }
        case .array(let element): try requireKnown(element)
        default: break
        }
    }
    private func validateDeclaredTypes() throws {
        for definition in types.values { for field in definition.fields { try requireKnown(field.type) } }
    }
    private func binaryType(_ op: String, _ lhs: TypeInfo, _ rhs: TypeInfo) throws -> TypeInfo {
        switch op {
        case "+":
            if lhs == .string && rhs == .string { return .string }; fallthrough
        case "-", "*", "/":
            guard [.int, .float].contains(lhs), [.int, .float].contains(rhs) else { throw error("Operator '\(op)' cannot be applied to \(lhs) and \(rhs)") }
            return lhs == .float || rhs == .float ? .float : .int
        case "%":
            guard lhs == .int, rhs == .int else { throw error("Modulo requires integer operands") }; return .int
        case "==", "!=":
            guard lhs == rhs || [.int, .float].contains(lhs) && [.int, .float].contains(rhs) else { throw error("Cannot compare \(lhs) and \(rhs)") }
            return .boolean
        case "<", "<=", ">", ">=":
            guard [.int, .float].contains(lhs) && [.int, .float].contains(rhs) || lhs == .string && rhs == .string else {
                throw error("Values of type \(lhs) and \(rhs) are not ordered")
            }
            return .boolean
        default: throw error("Unknown binary operator '\(op)'")
        }
    }
    private func error(_ message: String) -> Diagnostic { Diagnostic(stage: .semantic, message: message) }
}
