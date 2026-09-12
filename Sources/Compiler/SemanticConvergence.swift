import Foundation
import Parser

/// A portable value emitted by Compiler's semantic convergence boundary.
public indirect enum CompilerSemanticValue: Hashable, Codable, Sendable {
    case integer(Int64)
    case floatingPoint(Double)
    case string(String)
    case boolean(Bool)
    case null
    case array([CompilerSemanticValue])
    case record(name: String, fields: [String: CompilerSemanticValue])

    public init(_ value: Value) {
        switch value {
        case .int(let value): self = .integer(value)
        case .float(let value): self = .floatingPoint(value)
        case .string(let value): self = .string(value)
        case .boolean(let value): self = .boolean(value)
        case .null: self = .null
        case .array(let values): self = .array(values.map(Self.init))
        case .record(let name, let fields):
            self = .record(name: name, fields: fields.mapValues(Self.init))
        }
    }

    public var type: String {
        switch self {
        case .integer: "int"
        case .floatingPoint: "float"
        case .string: "string"
        case .boolean: "boolean"
        case .null: "null"
        case .array: "array"
        case .record(let name, _): name
        }
    }

    public var displayValue: String {
        switch self {
        case .integer(let value): "\(value)"
        case .floatingPoint(let value): "\(value)"
        case .string(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        case .array(let values): "[\(values.map(\.displayValue).joined(separator: ", "))]"
        case .record(let name, let fields):
            "\(name) { \(fields.keys.sorted().map { "\($0): \(fields[$0]!.displayValue)" }.joined(separator: ", ")) }"
        }
    }
}

extension CompilerSemanticValue {
    private enum CodingKeys: String, CodingKey {
        case kind, integer, floatingPoint, string, boolean, items, name, fields
    }
    private enum Kind: String, Codable {
        case integer, floatingPoint, string, boolean, null, array, record
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .integer: self = .integer(try values.decode(Int64.self, forKey: .integer))
        case .floatingPoint: self = .floatingPoint(try values.decode(Double.self, forKey: .floatingPoint))
        case .string: self = .string(try values.decode(String.self, forKey: .string))
        case .boolean: self = .boolean(try values.decode(Bool.self, forKey: .boolean))
        case .null: self = .null
        case .array: self = .array(try values.decode([Self].self, forKey: .items))
        case .record:
            self = .record(
                name: try values.decode(String.self, forKey: .name),
                fields: try values.decode([String: Self].self, forKey: .fields)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let value):
            try values.encode(Kind.integer, forKey: .kind)
            try values.encode(value, forKey: .integer)
        case .floatingPoint(let value):
            try values.encode(Kind.floatingPoint, forKey: .kind)
            try values.encode(value, forKey: .floatingPoint)
        case .string(let value):
            try values.encode(Kind.string, forKey: .kind)
            try values.encode(value, forKey: .string)
        case .boolean(let value):
            try values.encode(Kind.boolean, forKey: .kind)
            try values.encode(value, forKey: .boolean)
        case .null:
            try values.encode(Kind.null, forKey: .kind)
        case .array(let items):
            try values.encode(Kind.array, forKey: .kind)
            try values.encode(items, forKey: .items)
        case .record(let name, let fields):
            try values.encode(Kind.record, forKey: .kind)
            try values.encode(name, forKey: .name)
            try values.encode(fields, forKey: .fields)
        }
    }
}

public enum CompilerSemanticObservationStatus: String, Hashable, Codable, Sendable {
    case evaluated
    case parseRejected
    case noSyntaxTree
    case failed
}

public struct CompilerSemanticDiagnostic: Hashable, Codable, Sendable {
    public let stage: String
    public let message: String

    public init(stage: String, message: String) {
        self.stage = stage
        self.message = message
    }
}

/// One parser engine's compiler-owned semantic observation. Multiple values
/// are retained when syntactically ambiguous derivations are semantically distinct.
public struct CompilerSemanticObservation: Hashable, Codable, Sendable {
    public let engine: String
    public let status: CompilerSemanticObservationStatus
    public let derivationCount: Int
    public let values: [CompilerSemanticValue]
    public let diagnostics: [CompilerSemanticDiagnostic]

    public init(
        engine: String,
        status: CompilerSemanticObservationStatus,
        derivationCount: Int,
        values: [CompilerSemanticValue] = [],
        diagnostics: [CompilerSemanticDiagnostic] = []
    ) {
        self.engine = engine
        self.status = status
        self.derivationCount = derivationCount
        self.values = values
        self.diagnostics = diagnostics
    }
}

public enum CompilerSemanticAgreement: String, Hashable, Codable, Sendable {
    case complete
    case divergent
    case inconclusive
}

/// Schema-stable semantic evidence suitable for embedding in parser experiments.
public struct CompilerSemanticConvergenceReport: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let agreement: CompilerSemanticAgreement
    public let observations: [CompilerSemanticObservation]

    public init(observations: [CompilerSemanticObservation]) {
        schemaVersion = Self.currentSchemaVersion
        self.observations = observations
        let evaluated = observations.filter { $0.status == .evaluated }
        if evaluated.count < 2 {
            agreement = .inconclusive
        } else {
            let signatures = evaluated.map { Set($0.values) }
            agreement = Set(signatures).count == 1 ? .complete : .divergent
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, agreement, observations }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        let recordedAgreement = try values.decode(CompilerSemanticAgreement.self, forKey: .agreement)
        let observations = try values.decode([CompilerSemanticObservation].self, forKey: .observations)
        let engines = observations.map(\.engine)
        let observationsAreValid = observations.allSatisfy { observation in
            switch observation.status {
            case .evaluated:
                observation.derivationCount > 0 && !observation.values.isEmpty
                    && observation.diagnostics.isEmpty
            case .parseRejected, .noSyntaxTree:
                observation.derivationCount == 0 && observation.values.isEmpty
                    && observation.diagnostics.isEmpty
            case .failed:
                observation.derivationCount > 0 && observation.values.isEmpty
                    && !observation.diagnostics.isEmpty
            }
        }
        let rebuilt = Self(observations: observations)
        guard version == Self.currentSchemaVersion,
              Set(engines).count == engines.count,
              observationsAreValid,
              recordedAgreement == rebuilt.agreement else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: values,
                debugDescription: "Invalid Compiler semantic convergence report"
            )
        }
        self = rebuilt
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(agreement, forKey: .agreement)
        try values.encode(observations, forKey: .observations)
    }
}

/// Parser input for semantic comparison. Parse trees remain parser-owned;
/// Compiler adapts, lowers, type-checks, and evaluates them.
public struct CompilerSemanticEngineInput {
    public let engine: String
    public let parseStatus: ParseStatus
    public let trees: [ParseTree]

    public init(engine: String, parseStatus: ParseStatus, trees: [ParseTree]) {
        self.engine = engine
        self.parseStatus = parseStatus
        self.trees = trees
    }
}

public enum CompilerSemanticConvergence {
    public static func evaluate(
        source: String,
        inputs: [CompilerSemanticEngineInput],
        mapping: ASTMapping
    ) -> CompilerSemanticConvergenceReport {
        CompilerSemanticConvergenceReport(observations: inputs.map {
            evaluate(source: source, input: $0, mapping: mapping)
        })
    }

    private static func evaluate(
        source: String,
        input: CompilerSemanticEngineInput,
        mapping: ASTMapping
    ) -> CompilerSemanticObservation {
        guard input.parseStatus != .rejected else {
            return .init(engine: input.engine, status: .parseRejected, derivationCount: 0)
        }
        guard !input.trees.isEmpty else {
            return .init(engine: input.engine, status: .noSyntaxTree, derivationCount: 0)
        }
        do {
            let adapter = GeneralizedParseTreeAdapter(source: source)
            let compiler = Compiler()
            var values = Set<CompilerSemanticValue>()
            for tree in input.trees {
                let syntax = try adapter.adapt(tree)
                let ast = try ASTBuilder(mapping: mapping).build(from: syntax)
                let value = try compiler.executeExpression(ast) ?? .null
                values.insert(CompilerSemanticValue(value))
            }
            return .init(
                engine: input.engine, status: .evaluated,
                derivationCount: input.trees.count,
                values: values.sorted { $0.canonicalKey < $1.canonicalKey }
            )
        } catch let diagnostic as Diagnostic {
            return .init(
                engine: input.engine, status: .failed,
                derivationCount: input.trees.count,
                diagnostics: [.init(stage: diagnostic.stage.rawValue, message: diagnostic.message)]
            )
        } catch {
            return .init(
                engine: input.engine, status: .failed,
                derivationCount: input.trees.count,
                diagnostics: [.init(stage: "semantic", message: String(describing: error))]
            )
        }
    }
}

private extension CompilerSemanticValue {
    var canonicalKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
