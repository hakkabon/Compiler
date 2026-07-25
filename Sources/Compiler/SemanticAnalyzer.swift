import Foundation

public struct SemanticResult: Sendable {
    public let ast: ASTNode
    public let symbols: [Symbol]
    public let functions: [String: FunctionSignature]
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
    private var currentReturnType: TypeInfo?

    public init() {}

    public func analyze(_ node: ASTNode) throws -> ASTNode {
        try analyzeProgram(node).ast
    }

    public func analyzeProgram(_ node: ASTNode) throws -> SemanticResult {
        scopes = [[:]]
        symbols = []
        functions = [:]
        currentReturnType = nil
        if case .program(let declarations, _, _) = node {
            for declaration in declarations {
                if case .functionDecl(let name, let parameters, let returnType, _, _) = declaration {
                    guard functions[name] == nil else {
                        throw Diagnostic(stage: .semantic, message: "Function '\(name)' is already declared")
                    }
                    functions[name] = FunctionSignature(name: name, parameters: parameters, returnType: returnType)
                }
            }
        }
        let ast = try infer(node)
        return SemanticResult(ast: ast, symbols: symbols, functions: functions)
    }

    public func declareVariable(_ name: String, type: TypeInfo) throws {
        _ = try declare(name, type: type)
    }

    private func declare(_ name: String, type: TypeInfo) throws -> Symbol {
        guard !scopes.contains(where: { $0[name] != nil }) else {
            throw Diagnostic(stage: .semantic, message: "Symbol '\(name)' is already declared")
        }
        let symbol = Symbol(id: SymbolID(symbols.count), name: name, type: type, slot: symbols.count)
        scopes[scopes.count - 1][name] = symbol
        symbols.append(symbol)
        return symbol
    }

    private func resolve(_ name: String) throws -> Symbol {
        for scope in scopes.reversed() {
            if let symbol = scope[name] { return symbol }
        }
        throw Diagnostic(stage: .semantic, message: "Undefined variable '\(name)'")
    }

    private func infer(_ node: ASTNode) throws -> ASTNode {
        switch node {
        case .intLiteral(let value, _): return .intLiteral(value, type: .int)
        case .floatLiteral(let value, _): return .floatLiteral(value, type: .float)
        case .stringLiteral(let value, _): return .stringLiteral(value, type: .string)
        case .booleanLiteral(let value, _): return .booleanLiteral(value, type: .boolean)
        case .nullLiteral: return .nullLiteral(type: .null)
        case .variable(let name, _): return .variable(name, type: try resolve(name).type)
        case .binary(let op, let left, let right, _):
            let lhs = try infer(left)
            let rhs = try infer(right)
            return .binary(op: op, left: lhs, right: rhs, type: try binaryType(op, lhs.type, rhs.type))
        case .unary(let op, let operand, _):
            let value = try infer(operand)
            guard op == "-", value.type == .int || value.type == .float else {
                throw Diagnostic(stage: .semantic, message: "Unary '\(op)' requires a numeric operand")
            }
            return .unary(op: op, operand: value, type: value.type)
        case .varDecl(let name, let initializer, let declaredType):
            let typedInitializer = try initializer.map(infer)
            let resolvedType = declaredType == .any ? (typedInitializer?.type ?? .any) : declaredType
            guard resolvedType != .any else {
                throw Diagnostic(stage: .semantic, message: "Declaration '\(name)' needs a type or initializer")
            }
            if let typedInitializer {
                try requireAssignable(typedInitializer.type, to: resolvedType, name: name)
            }
            _ = try declare(name, type: resolvedType)
            return .varDecl(name: name, initializer: typedInitializer, type: resolvedType)
        case .assignment(let name, let value, _):
            let symbol = try resolve(name)
            let typedValue = try infer(value)
            try requireAssignable(typedValue.type, to: symbol.type, name: name)
            return .assignment(variable: name, value: typedValue, type: .null)
        case .ifStmt(let condition, let thenBranch, let elseBranch, _):
            let condition = try infer(condition)
            try requireBoolean(condition)
            return .ifStmt(
                condition: condition,
                thenBranch: try inferScoped(thenBranch),
                elseBranch: try elseBranch.map(inferScoped),
                type: .null
            )
        case .whileStmt(let condition, let body, _):
            let condition = try infer(condition)
            try requireBoolean(condition)
            return .whileStmt(condition: condition, body: try inferScoped(body), type: .null)
        case .block(let statements, _):
            scopes.append([:])
            defer { scopes.removeLast() }
            return .block(try statements.map(infer), type: .null)
        case .program(let declarations, let body, _):
            let declarations = try declarations.map(infer)
            return .program(declarations: declarations, body: try infer(body), type: .null)
        case .print(let expression, _):
            return .print(try infer(expression), type: .null)
        case .read(let name, _):
            let symbol = try resolve(name)
            guard symbol.type == .int else {
                throw Diagnostic(stage: .semantic, message: "read currently supports integer variables only")
            }
            return .read(name: name, type: .null)
        case .expressionStatement(let expression, _):
            return .expressionStatement(try infer(expression), type: .null)
        case .functionDecl(let name, let parameters, let returnType, let body, _):
            scopes.append([:])
            let previousReturnType = currentReturnType
            currentReturnType = returnType
            defer {
                currentReturnType = previousReturnType
                scopes.removeLast()
            }
            for parameter in parameters {
                _ = try declare(parameter.name, type: parameter.type)
            }
            return .functionDecl(
                name: name,
                parameters: parameters,
                returnType: returnType,
                body: try infer(body),
                type: .null
            )
        case .call(let name, let arguments, _):
            guard let signature = functions[name] else {
                throw Diagnostic(stage: .semantic, message: "Undefined function '\(name)'")
            }
            guard signature.parameters.count == arguments.count else {
                throw Diagnostic(
                    stage: .semantic,
                    message: "Function '\(name)' expects \(signature.parameters.count) argument(s), got \(arguments.count)"
                )
            }
            let typedArguments = try arguments.map(infer)
            for (argument, parameter) in zip(typedArguments, signature.parameters) {
                try requireAssignable(argument.type, to: parameter.type, name: parameter.name)
            }
            return .call(name: name, arguments: typedArguments, type: signature.returnType)
        case .returnStmt(let value, _):
            guard let expected = currentReturnType else {
                throw Diagnostic(stage: .semantic, message: "return is only valid inside a function")
            }
            let typedValue = try value.map(infer)
            if expected == .null {
                guard typedValue == nil else {
                    throw Diagnostic(stage: .semantic, message: "Void function cannot return a value")
                }
            } else {
                guard let typedValue else {
                    throw Diagnostic(stage: .semantic, message: "Function must return \(expected)")
                }
                try requireAssignable(typedValue.type, to: expected, name: "return value")
            }
            return .returnStmt(typedValue, type: .null)
        }
    }

    private func inferScoped(_ node: ASTNode) throws -> ASTNode {
        scopes.append([:])
        defer { scopes.removeLast() }
        return try infer(node)
    }

    private func requireBoolean(_ node: ASTNode) throws {
        guard node.type == .boolean else {
            throw Diagnostic(stage: .semantic, message: "Control-flow condition must be boolean, got \(node.type)")
        }
    }

    private func requireAssignable(_ source: TypeInfo, to target: TypeInfo, name: String) throws {
        guard source == target || source == .int && target == .float else {
            throw Diagnostic(stage: .semantic, message: "Cannot assign \(source) to \(target) variable '\(name)'")
        }
    }

    private func binaryType(_ op: String, _ lhs: TypeInfo, _ rhs: TypeInfo) throws -> TypeInfo {
        switch op {
        case "+":
            if lhs == .string && rhs == .string { return .string }
            fallthrough
        case "-", "*", "/":
            guard [.int, .float].contains(lhs), [.int, .float].contains(rhs) else {
                throw Diagnostic(stage: .semantic, message: "Operator '\(op)' cannot be applied to \(lhs) and \(rhs)")
            }
            return lhs == .float || rhs == .float ? .float : .int
        case "%":
            guard lhs == .int, rhs == .int else {
                throw Diagnostic(stage: .semantic, message: "Modulo requires integer operands")
            }
            return .int
        case "==", "!=":
            guard lhs == rhs || [.int, .float].contains(lhs) && [.int, .float].contains(rhs) else {
                throw Diagnostic(stage: .semantic, message: "Cannot compare \(lhs) and \(rhs)")
            }
            return .boolean
        case "<", "<=", ">", ">=":
            let numeric = [.int, .float].contains(lhs) && [.int, .float].contains(rhs)
            guard numeric || lhs == .string && rhs == .string else {
                throw Diagnostic(stage: .semantic, message: "Values of type \(lhs) and \(rhs) are not ordered")
            }
            return .boolean
        default:
            throw Diagnostic(stage: .semantic, message: "Unknown binary operator '\(op)'")
        }
    }
}
