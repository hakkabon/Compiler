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
    case partiallyEvaluated
    case parseRejected
    case noSyntaxTree
    case failed
}

/// The semantic significance of one or more parser derivations.
public enum CompilerSemanticAmbiguity: String, Hashable, Codable, Sendable {
    case syntacticallyUnambiguous
    case semanticallyEquivalent
    case semanticallyDivergent
    case unresolved
}

public struct CompilerSemanticDiagnostic: Hashable, Codable, Sendable {
    public let stage: String
    public let message: String

    public init(stage: String, message: String) {
        self.stage = stage
        self.message = message
    }
}

/// Compiler-owned evidence for one parser-owned derivation.
public struct CompilerSemanticDerivation: Hashable, Codable, Sendable {
    public let index: Int
    public let syntaxFingerprint: String
    public let value: CompilerSemanticValue?
    public let diagnostic: CompilerSemanticDiagnostic?

    public init(
        index: Int,
        syntaxFingerprint: String,
        value: CompilerSemanticValue? = nil,
        diagnostic: CompilerSemanticDiagnostic? = nil
    ) {
        self.index = index
        self.syntaxFingerprint = syntaxFingerprint
        self.value = value
        self.diagnostic = diagnostic
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
    public let ambiguity: CompilerSemanticAmbiguity?
    public let derivations: [CompilerSemanticDerivation]?

    public init(
        engine: String,
        status: CompilerSemanticObservationStatus,
        derivationCount: Int,
        values: [CompilerSemanticValue] = [],
        diagnostics: [CompilerSemanticDiagnostic] = [],
        ambiguity: CompilerSemanticAmbiguity? = nil,
        derivations: [CompilerSemanticDerivation]? = nil
    ) {
        self.engine = engine
        self.status = status
        self.derivationCount = derivationCount
        self.values = values
        self.diagnostics = diagnostics
        self.ambiguity = ambiguity
        self.derivations = derivations
    }
}

public enum CompilerSemanticAgreement: String, Hashable, Codable, Sendable {
    case complete
    case divergent
    case inconclusive
}

/// Schema-stable semantic evidence suitable for embedding in parser experiments.
public struct CompilerSemanticConvergenceReport: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let agreement: CompilerSemanticAgreement
    public let ambiguity: CompilerSemanticAmbiguity?
    public let observations: [CompilerSemanticObservation]

    public init(observations: [CompilerSemanticObservation]) {
        schemaVersion = Self.currentSchemaVersion
        self.observations = observations
        ambiguity = Self.classifyAmbiguity(observations)
        let evaluated = observations.filter { $0.status == .evaluated }
        if evaluated.count < 2 || observations.contains(where: { $0.status == .partiallyEvaluated }) {
            agreement = .inconclusive
        } else {
            let signatures = evaluated.map { Set($0.values) }
            agreement = Set(signatures).count == 1 ? .complete : .divergent
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, agreement, ambiguity, observations }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        let recordedAgreement = try values.decode(CompilerSemanticAgreement.self, forKey: .agreement)
        let recordedAmbiguity = try values.decodeIfPresent(CompilerSemanticAmbiguity.self, forKey: .ambiguity)
        let observations = try values.decode([CompilerSemanticObservation].self, forKey: .observations)
        let engines = observations.map(\.engine)
        let observationsAreValid = observations.allSatisfy { observation in
            switch observation.status {
            case .evaluated:
                observation.derivationCount > 0 && !observation.values.isEmpty
                    && observation.diagnostics.isEmpty
            case .partiallyEvaluated:
                version >= 2 && observation.derivationCount > 1
                    && !observation.values.isEmpty && !observation.diagnostics.isEmpty
            case .parseRejected, .noSyntaxTree:
                observation.derivationCount == 0 && observation.values.isEmpty
                    && observation.diagnostics.isEmpty
            case .failed:
                observation.derivationCount > 0 && observation.values.isEmpty
                    && !observation.diagnostics.isEmpty
            }
        }
        let rebuilt = Self(observations: observations)
        let ambiguityIsValid = version == 1
            ? recordedAmbiguity == nil && observations.allSatisfy { $0.ambiguity == nil && $0.derivations == nil }
            : recordedAmbiguity == rebuilt.ambiguity && observations.allSatisfy(Self.validDerivationEvidence)
        guard (1...Self.currentSchemaVersion).contains(version),
              Set(engines).count == engines.count,
              observationsAreValid,
              ambiguityIsValid,
              recordedAgreement == rebuilt.agreement else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: values,
                debugDescription: "Invalid Compiler semantic convergence report"
            )
        }
        schemaVersion = version
        agreement = recordedAgreement
        ambiguity = recordedAmbiguity
        self.observations = observations
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(agreement, forKey: .agreement)
        try values.encodeIfPresent(ambiguity, forKey: .ambiguity)
        try values.encode(observations, forKey: .observations)
    }

    private static func classifyAmbiguity(
        _ observations: [CompilerSemanticObservation]
    ) -> CompilerSemanticAmbiguity {
        let classifications = observations.compactMap(\.ambiguity)
        if classifications.contains(.semanticallyDivergent) { return .semanticallyDivergent }
        if classifications.contains(.unresolved) { return .unresolved }
        if classifications.contains(.semanticallyEquivalent) { return .semanticallyEquivalent }
        return classifications.isEmpty ? .unresolved : .syntacticallyUnambiguous
    }

    private static func validDerivationEvidence(_ observation: CompilerSemanticObservation) -> Bool {
        guard let ambiguity = observation.ambiguity,
              let derivations = observation.derivations,
              derivations.map(\.index) == Array(derivations.indices),
              derivations.count == observation.derivationCount,
              derivations.allSatisfy({
                  $0.syntaxFingerprint.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
                      && (($0.value == nil) != ($0.diagnostic == nil))
              }) else { return false }
        let successful = derivations.compactMap(\.value)
        let failures = derivations.compactMap(\.diagnostic)
        let uniqueValues = Array(Set(successful)).sorted { $0.canonicalKey < $1.canonicalKey }
        guard uniqueValues == observation.values, failures == observation.diagnostics else { return false }
        if observation.status == .parseRejected || observation.status == .noSyntaxTree {
            return derivations.isEmpty && ambiguity == .unresolved
        }
        let expectedStatus: CompilerSemanticObservationStatus = failures.isEmpty
            ? .evaluated : (successful.isEmpty ? .failed : .partiallyEvaluated)
        let expectedAmbiguity: CompilerSemanticAmbiguity
        if derivations.isEmpty || !failures.isEmpty { expectedAmbiguity = .unresolved }
        else if derivations.count == 1 { expectedAmbiguity = .syntacticallyUnambiguous }
        else if uniqueValues.count == 1 { expectedAmbiguity = .semanticallyEquivalent }
        else { expectedAmbiguity = .semanticallyDivergent }
        return observation.status == expectedStatus && ambiguity == expectedAmbiguity
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
            return .init(
                engine: input.engine, status: .parseRejected, derivationCount: 0,
                ambiguity: .unresolved, derivations: []
            )
        }
        guard !input.trees.isEmpty else {
            return .init(
                engine: input.engine, status: .noSyntaxTree, derivationCount: 0,
                ambiguity: .unresolved, derivations: []
            )
        }
        let adapter = GeneralizedParseTreeAdapter(source: source)
        let compiler = Compiler()
        let unorderedDerivations = input.trees.enumerated().map { index, tree in
            do {
                let syntax = try adapter.adapt(tree)
                let ast = try ASTBuilder(mapping: mapping).build(from: syntax)
                let value = try compiler.executeExpression(ast) ?? .null
                return CompilerSemanticDerivation(
                    index: index, syntaxFingerprint: syntax.semanticFingerprint,
                    value: CompilerSemanticValue(value)
                )
            } catch let diagnostic as Diagnostic {
                return CompilerSemanticDerivation(
                    index: index, syntaxFingerprint: syntaxFingerprint(tree, source: source),
                    diagnostic: .init(stage: diagnostic.stage.rawValue, message: diagnostic.message)
                )
            } catch {
                return CompilerSemanticDerivation(
                    index: index, syntaxFingerprint: syntaxFingerprint(tree, source: source),
                    diagnostic: .init(stage: "semantic", message: String(describing: error))
                )
            }
        }
        let derivations = unorderedDerivations
            .sorted {
                if $0.syntaxFingerprint != $1.syntaxFingerprint {
                    return $0.syntaxFingerprint < $1.syntaxFingerprint
                }
                return $0.index < $1.index
            }
            .enumerated()
            .map { index, derivation in
                CompilerSemanticDerivation(
                    index: index,
                    syntaxFingerprint: derivation.syntaxFingerprint,
                    value: derivation.value,
                    diagnostic: derivation.diagnostic
                )
            }
        let successful = derivations.compactMap(\.value)
        let diagnostics = derivations.compactMap(\.diagnostic)
        let values = Array(Set(successful)).sorted { $0.canonicalKey < $1.canonicalKey }
        let status: CompilerSemanticObservationStatus = diagnostics.isEmpty
            ? .evaluated : (successful.isEmpty ? .failed : .partiallyEvaluated)
        let ambiguity: CompilerSemanticAmbiguity
        if !diagnostics.isEmpty { ambiguity = .unresolved }
        else if derivations.count == 1 { ambiguity = .syntacticallyUnambiguous }
        else if values.count == 1 { ambiguity = .semanticallyEquivalent }
        else { ambiguity = .semanticallyDivergent }
        return .init(
            engine: input.engine, status: status, derivationCount: input.trees.count,
            values: values, diagnostics: diagnostics,
            ambiguity: ambiguity, derivations: derivations
        )
    }
}

private func syntaxFingerprint(_ tree: ParseTree, source: String) -> String {
    let adapter = GeneralizedParseTreeAdapter(source: source)
    guard let syntax = try? adapter.adapt(tree) else { return stableFingerprint("unadaptable") }
    return syntax.semanticFingerprint
}

private extension SyntaxNode {
    var semanticFingerprint: String {
        func material(_ node: SyntaxNode) -> String {
            let token = node.token.map { "|\($0.kind.count):\($0.kind)|\($0.lexeme.count):\($0.lexeme)" } ?? ""
            return "\(node.rule.count):\(node.rule)\(token)[\(node.children.map(material).joined())]"
        }
        return stableFingerprint(material(self))
    }
}

private func stableFingerprint(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(format: "%016llx", hash)
}

private extension CompilerSemanticValue {
    var canonicalKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
