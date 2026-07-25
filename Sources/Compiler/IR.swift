import Foundation

public struct IRLabel: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

public enum IROperation: Equatable, Sendable {
    case constant(Value)
    case load(slot: Int)
    case store(slot: Int)
    case binary(String)
    case unary(String)
    case label(IRLabel)
    case jump(IRLabel)
    case jumpIfFalse(IRLabel)
    case print
    case read(slot: Int)
    case discard
    case call(name: String, argumentCount: Int)
    case returnValue(hasValue: Bool)
    case halt
}

public struct IRFunction: Equatable, Sendable {
    public let name: String
    public let entry: IRLabel
    public let parameterSlots: [Int]
    public init(name: String, entry: IRLabel, parameterSlots: [Int]) {
        self.name = name
        self.entry = entry
        self.parameterSlots = parameterSlots
    }
}

public struct IRProgram: Equatable, Sendable {
    public let operations: [IROperation]
    public let localCount: Int
    public let functions: [IRFunction]
    public init(operations: [IROperation], localCount: Int, functions: [IRFunction] = []) {
        self.operations = operations
        self.localCount = localCount
        self.functions = functions
    }
}

public final class IRLowerer {
    private var operations: [IROperation] = []
    private var slots: [String: Int] = [:]
    private var nextLabel = 0
    private var functionLabels: [String: IRLabel] = [:]

    public init() {}

    public func lower(_ result: SemanticResult) throws -> IRProgram {
        operations = []
        slots = Dictionary(uniqueKeysWithValues: result.symbols.map { ($0.name, $0.slot) })
        nextLabel = 0
        functionLabels = Dictionary(uniqueKeysWithValues: result.functions.keys.sorted().map { ($0, label()) })
        if case .program(let declarations, let body, _) = result.ast {
            for declaration in declarations {
                if case .functionDecl = declaration { continue }
                try emit(declaration)
            }
            try emit(body)
        } else {
            try emit(result.ast)
        }
        operations.append(.halt)
        var functions: [IRFunction] = []
        if case .program(let declarations, _, _) = result.ast {
            for declaration in declarations {
                guard case .functionDecl(let name, let parameters, _, let body, _) = declaration,
                      let entry = functionLabels[name] else { continue }
                let parameterSlots = try parameters.map { try slot($0.name) }
                functions.append(IRFunction(name: name, entry: entry, parameterSlots: parameterSlots))
                operations.append(.label(entry))
                try emit(body)
                operations.append(.constant(.null))
                operations.append(.returnValue(hasValue: true))
            }
        }
        return IRProgram(operations: operations, localCount: result.symbols.count, functions: functions)
    }

    private func label() -> IRLabel { defer { nextLabel += 1 }; return IRLabel(nextLabel) }

    private func emit(_ node: ASTNode) throws {
        switch node {
        case .intLiteral(let value, _): operations.append(.constant(.int(value)))
        case .floatLiteral(let value, _): operations.append(.constant(.float(value)))
        case .stringLiteral(let value, _): operations.append(.constant(.string(value)))
        case .booleanLiteral(let value, _): operations.append(.constant(.boolean(value)))
        case .nullLiteral: operations.append(.constant(.null))
        case .variable(let name, _): operations.append(.load(slot: try slot(name)))
        case .binary(let op, let left, let right, _):
            try emit(left); try emit(right); operations.append(.binary(op))
        case .unary(let op, let operand, _):
            try emit(operand); operations.append(.unary(op))
        case .varDecl(let name, let initializer, let type):
            if let initializer { try emit(initializer) }
            else { operations.append(.constant(defaultValue(for: type))) }
            operations.append(.store(slot: try slot(name)))
        case .assignment(let name, let value, _):
            try emit(value); operations.append(.store(slot: try slot(name)))
        case .block(let nodes, _):
            for node in nodes { try emit(node) }
        case .program(let declarations, let body, _):
            for declaration in declarations { try emit(declaration) }
            try emit(body)
        case .ifStmt(let condition, let thenBranch, let elseBranch, _):
            let otherwise = label(), end = label()
            try emit(condition)
            operations.append(.jumpIfFalse(otherwise))
            try emit(thenBranch)
            operations.append(.jump(end))
            operations.append(.label(otherwise))
            if let elseBranch { try emit(elseBranch) }
            operations.append(.label(end))
        case .whileStmt(let condition, let body, _):
            let start = label(), end = label()
            operations.append(.label(start))
            try emit(condition)
            operations.append(.jumpIfFalse(end))
            try emit(body)
            operations.append(.jump(start))
            operations.append(.label(end))
        case .print(let expression, _):
            try emit(expression); operations.append(.print)
        case .read(let name, _):
            operations.append(.read(slot: try slot(name)))
        case .expressionStatement(let expression, _):
            try emit(expression); operations.append(.discard)
        case .functionDecl:
            break
        case .call(let name, let arguments, _):
            for argument in arguments { try emit(argument) }
            operations.append(.call(name: name, argumentCount: arguments.count))
        case .returnStmt(let value, _):
            if let value { try emit(value) }
            else { operations.append(.constant(.null)) }
            operations.append(.returnValue(hasValue: true))
        }
    }

    private func slot(_ name: String) throws -> Int {
        guard let slot = slots[name] else {
            throw Diagnostic(stage: .lowering, message: "No storage assigned to '\(name)'")
        }
        return slot
    }
    private func defaultValue(for type: TypeInfo) -> Value {
        switch type {
        case .int: return .int(0)
        case .float: return .float(0)
        case .string: return .string("")
        case .boolean: return .boolean(false)
        case .null, .any: return .null
        }
    }
}
