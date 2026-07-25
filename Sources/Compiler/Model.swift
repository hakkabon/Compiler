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

public enum TypeInfo: String, Equatable, CustomStringConvertible, Sendable {
    case int, float, string, boolean, null, any
    public var description: String { rawValue }
}

public enum Value: Equatable, CustomStringConvertible, Sendable {
    case int(Int64)
    case float(Double)
    case string(String)
    case boolean(Bool)
    case null

    public var description: String {
        switch self {
        case .int(let value): return "\(value)"
        case .float(let value): return "\(value)"
        case .string(let value): return value
        case .boolean(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    public var type: TypeInfo {
        switch self {
        case .int: return .int
        case .float: return .float
        case .string: return .string
        case .boolean: return .boolean
        case .null: return .null
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null, .boolean(false), .int(0), .float(0), .string(""): return false
        default: return true
        }
    }
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
             .call(_, _, let type), .returnStmt(_, let type):
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
