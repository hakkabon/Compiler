import Foundation
import Grammar
import IncrementalParsing

public struct CompilerStableNodeID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct CompilerNodeDependency: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func symbol(_ name: String) -> Self { .init("symbol:\(name)") }
    public static func function(_ name: String) -> Self { .init("function:\(name)") }
    public static func type(_ name: String) -> Self { .init("type:\(name)") }
    public static func semanticNode(_ id: CompilerStableNodeID) -> Self {
        .init("semantic:\(id.rawValue)")
    }
    public static func irNode(_ id: CompilerStableNodeID) -> Self {
        .init("ir:\(id.rawValue)")
    }
    public static func grammarProduction(_ id: GrammarProductionID) -> Self {
        .init("grammar-production:\(id.rawValue)")
    }
}

/// Reference identity shared by stable semantic and IR nodes.
public final class CompilerStableNode<Payload>: @unchecked Sendable {
    public let id: CompilerStableNodeID
    public let fingerprint: String
    public let payload: Payload
    public let dependencies: Set<CompilerNodeDependency>
    /// Dependency keys exported by this node and their public fingerprints.
    /// A body-only edit can therefore rebuild its node without invalidating
    /// consumers when its signature remains unchanged.
    public let providedDependencies: [CompilerNodeDependency: String]

    fileprivate init(id: CompilerStableNodeID, fingerprint: String, payload: Payload,
                     dependencies: Set<CompilerNodeDependency>,
                     providedDependencies: [CompilerNodeDependency: String]) {
        self.id = id; self.fingerprint = fingerprint
        self.payload = payload; self.dependencies = dependencies
        self.providedDependencies = providedDependencies
    }
}

public struct CompilerNodeCandidate<Payload> {
    public let id: CompilerStableNodeID
    public let fingerprint: String
    public let payload: Payload
    public let dependencies: Set<CompilerNodeDependency>
    public let providedDependencies: [CompilerNodeDependency: String]

    public init(id: CompilerStableNodeID, fingerprint: String, payload: Payload,
                dependencies: Set<CompilerNodeDependency> = [],
                providedDependencies: [CompilerNodeDependency: String] = [:]) {
        self.id = id; self.fingerprint = fingerprint
        self.payload = payload; self.dependencies = dependencies
        self.providedDependencies = providedDependencies
    }
}

public struct CompilerReuseEvidence: Sendable {
    public let reused: Set<CompilerStableNodeID>
    public let rebuilt: Set<CompilerStableNodeID>
    public let removed: Set<CompilerStableNodeID>
    public let invalidatedDependencies: Set<CompilerNodeDependency>

    public init(
        reused: Set<CompilerStableNodeID>,
        rebuilt: Set<CompilerStableNodeID>,
        removed: Set<CompilerStableNodeID>,
        invalidatedDependencies: Set<CompilerNodeDependency> = []
    ) {
        self.reused = reused
        self.rebuilt = rebuilt
        self.removed = removed
        self.invalidatedDependencies = invalidatedDependencies
    }
}

/// Reconciles one compiler pass by stable syntax identity and pass-specific
/// fingerprint. Equal nodes preserve object identity; changed dependencies or
/// fingerprints create a fresh semantic/IR node.
public final class CompilerStableNodeArena<Payload> {
    private var nodes: [CompilerStableNodeID: CompilerStableNode<Payload>] = [:]
    public init() {}
    public subscript(id: CompilerStableNodeID) -> CompilerStableNode<Payload>? { nodes[id] }

    @discardableResult
    public func reconcile(_ candidates: [CompilerNodeCandidate<Payload>],
                          changedDependencies: Set<CompilerNodeDependency> = []) -> CompilerReuseEvidence {
        precondition(Set(candidates.map(\.id)).count == candidates.count,
                     "compiler candidates must have unique stable identities")
        let oldProviders = providerFingerprints(nodes.values.map {
            ($0.id, $0.providedDependencies)
        })
        let newProviders = providerFingerprints(candidates.map {
            ($0.id, $0.providedDependencies)
        })
        let providerKeys = Set(oldProviders.keys).union(newProviders.keys)
        let invalidated = providerKeys.reduce(into: changedDependencies) { result, dependency in
            if oldProviders[dependency] != newProviders[dependency] {
                result.insert(dependency)
            }
        }
        var next: [CompilerStableNodeID: CompilerStableNode<Payload>] = [:]
        var reused: Set<CompilerStableNodeID> = [], rebuilt: Set<CompilerStableNodeID> = []
        for candidate in candidates {
            if let old = nodes[candidate.id], old.fingerprint == candidate.fingerprint,
               old.dependencies == candidate.dependencies,
               old.providedDependencies == candidate.providedDependencies,
               old.dependencies.isDisjoint(with: invalidated) {
                next[candidate.id] = old
                reused.insert(candidate.id)
            } else {
                next[candidate.id] = .init(id: candidate.id, fingerprint: candidate.fingerprint,
                                           payload: candidate.payload, dependencies: candidate.dependencies,
                                           providedDependencies: candidate.providedDependencies)
                rebuilt.insert(candidate.id)
            }
        }
        let removed = Set(nodes.keys).subtracting(next.keys)
        nodes = next
        return .init(reused: reused, rebuilt: rebuilt, removed: removed,
                     invalidatedDependencies: invalidated)
    }

    public var identities: Set<CompilerStableNodeID> { Set(nodes.keys) }
    public func removeAll() { nodes.removeAll(keepingCapacity: true) }

    private func providerFingerprints(
        _ entries: [(CompilerStableNodeID, [CompilerNodeDependency: String])]
    ) -> [CompilerNodeDependency: String] {
        var result: [CompilerNodeDependency: String] = [:]
        var owners: [CompilerNodeDependency: CompilerStableNodeID] = [:]
        for (id, dependencies) in entries {
            for (dependency, fingerprint) in dependencies {
                precondition(owners[dependency] == nil || owners[dependency] == id,
                             "dependency \(dependency.rawValue) has multiple providers")
                owners[dependency] = id
                result[dependency] = fingerprint
            }
        }
        return result
    }
}

/// Compiler-owned pair of arenas. Semantic nodes and lowered IR fragments
/// deliberately have independent fingerprints and invalidation boundaries.
public final class CompilerIncrementalWorkspace {
    public let semantics = CompilerStableNodeArena<ResolvedASTNode>()
    public let ir = CompilerStableNodeArena<[IROperation]>()
    public init() {}
    public func reset() {
        semantics.removeAll()
        ir.removeAll()
    }
}

/// One parser- or language-kit-owned top-level syntax unit. The stable ID must
/// survive source relocation; Compiler owns every semantic and IR dependency
/// derived from the AST payload.
public struct CompilerIncrementalUnit: Equatable, Sendable {
    public let id: CompilerStableNodeID
    public let ast: ASTNode
    public let productionDependencies: Set<GrammarProductionID>

    public init(
        id: CompilerStableNodeID,
        ast: ASTNode,
        productionDependencies: Set<GrammarProductionID> = []
    ) {
        self.id = id
        self.ast = ast
        self.productionDependencies = productionDependencies
    }
}

public enum CompilerIncrementalError: Error, Equatable, Sendable {
    case duplicateUnit(CompilerStableNodeID)
    case malformedSemanticProgram
}

public struct CompilerIncrementalResult: Sendable {
    public let artifacts: CompilationArtifacts
    public let semanticReuse: CompilerReuseEvidence
    public let irReuse: CompilerReuseEvidence
    public let evidence: IncrementalExecutionEvidence
}

/// Stateful compiler boundary for editor and language-kit clients. Semantic
/// nodes converge by typed output and public symbol signatures. Relocatable IR
/// fragments converge independently, so a semantic rebuild does not imply an
/// IR rebuild when lowering output is unchanged.
public final class CompilerIncrementalSession {
    public let workspace: CompilerIncrementalWorkspace
    private var hasBaseline = false
    private var artifactIdentity: IncrementalArtifactIdentity?

    public init(workspace: CompilerIncrementalWorkspace = .init()) {
        self.workspace = workspace
    }

    public func reset() {
        workspace.reset()
        hasBaseline = false
        artifactIdentity = nil
    }

    public func update(
        _ units: [CompilerIncrementalUnit],
        artifactIdentity nextArtifactIdentity: IncrementalArtifactIdentity? = nil,
        grammarChange: GrammarChangeSet? = nil
    ) throws -> CompilerIncrementalResult {
        var grammarDependencies = Set<CompilerNodeDependency>()
        var grammarMeasurement: ReuseMeasurement?
        if hasBaseline, artifactIdentity != nextArtifactIdentity {
            if let grammarChange,
               artifactIdentity?.fingerprint == grammarChange.sourceFingerprint,
               nextArtifactIdentity?.fingerprint == grammarChange.targetFingerprint {
                grammarDependencies = Set(grammarChange.invalidatedProductionIDs.map(
                    CompilerNodeDependency.grammarProduction))
                grammarMeasurement = .init(
                    dimension: .grammarProductions,
                    reused: grammarChange.retainedProductionIDs.count,
                    rebuilt: grammarChange.addedProductionIDs.count,
                    removed: grammarChange.removedProductionIDs.count,
                    strategy: "structural-grammar-delta")
            } else {
                workspace.reset()
                hasBaseline = false
            }
        }
        let strategy: IncrementalExecutionStrategy = hasBaseline ? .incremental : .full
        var seen: Set<CompilerStableNodeID> = []
        for unit in units where !seen.insert(unit.id).inserted {
            throw CompilerIncrementalError.duplicateUnit(unit.id)
        }

        let declarationUnits = units.filter { $0.ast.isCompilerDeclaration }
        let statementUnits = units.filter { !$0.ast.isCompilerDeclaration }
        let sourceAST = ASTNode.program(
            declarations: declarationUnits.map(\.ast),
            body: .block(statementUnits.map(\.ast), type: .null),
            type: .null)
        let semantic = try SemanticAnalyzer().analyzeProgram(sourceAST)
        guard case .program(let resolvedDeclarations, let resolvedBody, _) = semantic.ast,
              case .block(let resolvedStatements, _) = resolvedBody,
              resolvedDeclarations.count == declarationUnits.count,
              resolvedStatements.count == statementUnits.count else {
            throw CompilerIncrementalError.malformedSemanticProgram
        }

        var resolvedByID: [CompilerStableNodeID: ResolvedASTNode] = [:]
        for (unit, resolved) in zip(declarationUnits, resolvedDeclarations) {
            resolvedByID[unit.id] = resolved
        }
        for (unit, resolved) in zip(statementUnits, resolvedStatements) {
            resolvedByID[unit.id] = resolved
        }

        let semanticCandidates = try units.map { unit -> CompilerNodeCandidate<ResolvedASTNode> in
            guard let resolved = resolvedByID[unit.id] else {
                throw CompilerIncrementalError.malformedSemanticProgram
            }
            let fingerprint = stableCompilerFingerprint(semanticMaterial(resolved))
            var provided = unit.ast.compilerProvidedDependencies(resolved: resolved)
            provided[.semanticNode(unit.id)] = fingerprint
            return .init(
                id: unit.id,
                fingerprint: fingerprint,
                payload: resolved,
                dependencies: unit.ast.compilerDependencies.union(
                    unit.productionDependencies.map(
                        CompilerNodeDependency.grammarProduction)),
                providedDependencies: provided)
        }
        let semanticReuse = workspace.semantics.reconcile(
            semanticCandidates,
            changedDependencies: grammarDependencies)

        let fragmentLowerer = IRLowerer()
        let irCandidates = try units.map { unit -> CompilerNodeCandidate<[IROperation]> in
            guard let semanticNode = workspace.semantics[unit.id] else {
                throw CompilerIncrementalError.malformedSemanticProgram
            }
            if semanticReuse.reused.contains(unit.id), let old = workspace.ir[unit.id] {
                return .init(
                    id: old.id,
                    fingerprint: old.fingerprint,
                    payload: old.payload,
                    dependencies: old.dependencies,
                    providedDependencies: old.providedDependencies)
            }
            let operations = try fragmentLowerer.lowerFragment(semanticNode.payload)
            let fingerprint = stableCompilerFingerprint(irMaterial(operations))
            return .init(
                id: unit.id,
                fingerprint: fingerprint,
                payload: operations,
                dependencies: [.semanticNode(unit.id)],
                providedDependencies: [.irNode(unit.id): fingerprint])
        }
        let irReuse = workspace.ir.reconcile(irCandidates)
        let ir = try IRLowerer().lower(semantic)
        let result = CompilerIncrementalResult(
            artifacts: .init(
                sourceAST: sourceAST,
                typedAST: semantic.ast,
                symbols: semantic.symbols,
                ir: ir),
            semanticReuse: semanticReuse,
            irReuse: irReuse,
            evidence: .init(
                strategy: strategy,
                measurements: [
                    .init(
                        dimension: .semanticNodes,
                        reused: semanticReuse.reused.count,
                        rebuilt: semanticReuse.rebuilt.count,
                        removed: semanticReuse.removed.count,
                        strategy: "stable-semantic-unit"),
                    .init(
                        dimension: .irNodes,
                        reused: irReuse.reused.count,
                        rebuilt: irReuse.rebuilt.count,
                        removed: irReuse.removed.count,
                        strategy: "relocatable-ir-fragment"),
                ] + (grammarMeasurement.map { [$0] } ?? [])))
        hasBaseline = true
        artifactIdentity = nextArtifactIdentity
        return result
    }
}

private func stableCompilerFingerprint(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(format: "%016llx", hash)
}

private func frame(_ value: String) -> String { "\(value.utf8.count):\(value)" }

private func typeMaterial(_ type: TypeInfo) -> String {
    switch type {
    case .int: "int"
    case .float: "float"
    case .string: "string"
    case .boolean: "boolean"
    case .null: "null"
    case .any: "any"
    case .array(let element): "array(\(typeMaterial(element)))"
    case .record(let name): "record(\(frame(name)))"
    }
}

private func valueMaterial(_ value: Value) -> String {
    switch value {
    case .int(let value): "int:\(value)"
    case .float(let value): "float:\(value.bitPattern)"
    case .string(let value): "string:\(frame(value))"
    case .boolean(let value): "boolean:\(value)"
    case .null: "null"
    case .array(let values): "array[\(values.map(valueMaterial).map(frame).joined())]"
    case .record(let name, let fields):
        "record:\(frame(name)){\(recordValueFieldsMaterial(fields))}"
    }
}

private func recordValueFieldsMaterial(_ fields: [String: Value]) -> String {
    fields.keys.sorted().map { key in
        frame(key) + frame(valueMaterial(fields[key]!))
    }.joined()
}

private func typeFieldsMaterial(_ fields: [TypeField]) -> String {
    fields.map { frame($0.name) + frame(typeMaterial($0.type)) }.joined()
}

private func resolvedRecordFieldsMaterial(_ fields: [ResolvedRecordField]) -> String {
    fields.map { frame($0.name) + frame(semanticMaterial($0.value)) }.joined()
}

private func symbolMaterial(_ symbol: Symbol) -> String {
    "\(symbol.id.rawValue):\(frame(symbol.name)):\(typeMaterial(symbol.type)):\(symbol.slot)"
}

private func semanticMaterial(_ node: ResolvedASTNode) -> String {
    let type = typeMaterial(node.type)
    return switch node {
    case .literal(let value, _): "literal:\(valueMaterial(value)):\(type)"
    case .variable(let symbol, _): "variable:\(symbolMaterial(symbol)):\(type)"
    case .binary(let op, let left, let right, _):
        "binary:\(frame(op)):\(frame(semanticMaterial(left))):\(frame(semanticMaterial(right))):\(type)"
    case .unary(let op, let operand, _):
        "unary:\(frame(op)):\(frame(semanticMaterial(operand))):\(type)"
    case .assignment(let symbol, let value, _):
        "assign:\(symbolMaterial(symbol)):\(frame(semanticMaterial(value))):\(type)"
    case .ifStmt(let condition, let thenBranch, let elseBranch, _):
        "if:\(frame(semanticMaterial(condition))):\(frame(semanticMaterial(thenBranch))):\(frame(elseBranch.map(semanticMaterial) ?? "nil")):\(type)"
    case .whileStmt(let condition, let body, _):
        "while:\(frame(semanticMaterial(condition))):\(frame(semanticMaterial(body))):\(type)"
    case .block(let nodes, _):
        "block[\(nodes.map(semanticMaterial).map(frame).joined())]:\(type)"
    case .varDecl(let symbol, let initializer, _):
        "var:\(symbolMaterial(symbol)):\(frame(initializer.map(semanticMaterial) ?? "nil")):\(type)"
    case .program(let declarations, let body, _):
        "program[\(declarations.map(semanticMaterial).map(frame).joined())]:\(frame(semanticMaterial(body))):\(type)"
    case .print(let value, _): "print:\(frame(semanticMaterial(value))):\(type)"
    case .read(let symbol, _): "read:\(symbolMaterial(symbol)):\(type)"
    case .expressionStatement(let value, _):
        "expression:\(frame(semanticMaterial(value))):\(type)"
    case .functionDecl(let name, let parameters, let returnType, let body, _):
        "function:\(frame(name))[\(parameters.map(symbolMaterial).map(frame).joined())]:\(typeMaterial(returnType)):\(frame(semanticMaterial(body))):\(type)"
    case .call(let name, let arguments, _):
        "call:\(frame(name))[\(arguments.map(semanticMaterial).map(frame).joined())]:\(type)"
    case .returnStmt(let value, _):
        "return:\(frame(value.map(semanticMaterial) ?? "nil")):\(type)"
    case .typeDecl(let definition, _):
        "type:\(frame(definition.name))[\(typeFieldsMaterial(definition.fields))]:\(type)"
    case .arrayLiteral(let values, _):
        "array[\(values.map(semanticMaterial).map(frame).joined())]:\(type)"
    case .index(let collection, let index, _):
        "index:\(frame(semanticMaterial(collection))):\(frame(semanticMaterial(index))):\(type)"
    case .indexAssignment(let symbol, let index, let value, _):
        "indexAssign:\(symbolMaterial(symbol)):\(frame(semanticMaterial(index))):\(frame(semanticMaterial(value))):\(type)"
    case .recordLiteral(let name, let fields, _):
        "recordLiteral:\(frame(name))[\(resolvedRecordFieldsMaterial(fields))]:\(type)"
    case .member(let base, let name, _):
        "member:\(frame(semanticMaterial(base))):\(frame(name)):\(type)"
    case .memberAssignment(let symbol, let field, let value, _):
        "memberAssign:\(symbolMaterial(symbol)):\(frame(field)):\(frame(semanticMaterial(value))):\(type)"
    }
}

private func irMaterial(_ operations: [IROperation]) -> String {
    operations.map { operation in
        switch operation {
        case .constant(let value): "constant:\(valueMaterial(value))"
        case .load(let slot): "load:\(slot)"
        case .store(let slot): "store:\(slot)"
        case .binary(let op): "binary:\(frame(op))"
        case .unary(let op): "unary:\(frame(op))"
        case .label(let label): "label:\(label.rawValue)"
        case .jump(let label): "jump:\(label.rawValue)"
        case .jumpIfFalse(let label): "jumpIfFalse:\(label.rawValue)"
        case .print: "print"
        case .read(let slot): "read:\(slot)"
        case .discard: "discard"
        case .call(let name, let count): "call:\(frame(name)):\(count)"
        case .returnValue(let hasValue): "return:\(hasValue)"
        case .buildArray(let count): "buildArray:\(count)"
        case .loadIndex: "loadIndex"
        case .storeIndex(let slot): "storeIndex:\(slot)"
        case .buildRecord(let name, let fields):
            "buildRecord:\(frame(name))[\(fields.map(frame).joined())]"
        case .loadField(let field): "loadField:\(frame(field))"
        case .storeField(let slot, let field): "storeField:\(slot):\(frame(field))"
        case .halt: "halt"
        }
    }.map(frame).joined()
}

private extension ASTNode {
    var isCompilerDeclaration: Bool {
        switch self {
        case .functionDecl, .typeDecl: true
        default: false
        }
    }

    func compilerProvidedDependencies(
        resolved: ResolvedASTNode
    ) -> [CompilerNodeDependency: String] {
        switch (self, resolved) {
        case (.functionDecl(let name, let parameters, let returnType, _, _), _):
            let signature = parameters.map { typeMaterial($0.type) }.joined(separator: ",")
            return [.function(name): stableCompilerFingerprint("(\(signature))->\(returnType)")]
        case (.typeDecl(let name, let fields, _), _):
            let signature = fields.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            return [.type(name): stableCompilerFingerprint(signature)]
        case (.varDecl(let name, _, _), .varDecl(let symbol, _, _)):
            return [.symbol(name): stableCompilerFingerprint(symbol.type.description)]
        default:
            return [:]
        }
    }

    var compilerDependencies: Set<CompilerNodeDependency> {
        var result: Set<CompilerNodeDependency> = []
        collectCompilerDependencies(into: &result)
        return result
    }

    func collectCompilerDependencies(into result: inout Set<CompilerNodeDependency>) {
        func collectType(_ type: TypeInfo) {
            switch type {
            case .record(let name): result.insert(.type(name))
            case .array(let element): collectType(element)
            default: break
            }
        }
        switch self {
        case .intLiteral, .floatLiteral, .stringLiteral, .booleanLiteral, .nullLiteral:
            break
        case .variable(let name, _):
            result.insert(.symbol(name))
        case .binary(_, let left, let right, _):
            left.collectCompilerDependencies(into: &result)
            right.collectCompilerDependencies(into: &result)
        case .unary(_, let operand, _), .print(let operand, _),
             .expressionStatement(let operand, _):
            operand.collectCompilerDependencies(into: &result)
        case .assignment(let name, let value, _):
            result.insert(.symbol(name)); value.collectCompilerDependencies(into: &result)
        case .ifStmt(let condition, let thenBranch, let elseBranch, _):
            condition.collectCompilerDependencies(into: &result)
            thenBranch.collectCompilerDependencies(into: &result)
            elseBranch?.collectCompilerDependencies(into: &result)
        case .whileStmt(let condition, let body, _):
            condition.collectCompilerDependencies(into: &result)
            body.collectCompilerDependencies(into: &result)
        case .block(let nodes, _):
            nodes.forEach { $0.collectCompilerDependencies(into: &result) }
        case .varDecl(_, let initializer, let type):
            collectType(type); initializer?.collectCompilerDependencies(into: &result)
        case .program(let declarations, let body, _):
            declarations.forEach { $0.collectCompilerDependencies(into: &result) }
            body.collectCompilerDependencies(into: &result)
        case .read(let name, _):
            result.insert(.symbol(name))
        case .functionDecl(_, let parameters, let returnType, let body, _):
            parameters.forEach { collectType($0.type) }
            collectType(returnType)
            body.collectCompilerDependencies(into: &result)
        case .call(let name, let arguments, _):
            result.insert(.function(name))
            arguments.forEach { $0.collectCompilerDependencies(into: &result) }
        case .returnStmt(let value, _):
            value?.collectCompilerDependencies(into: &result)
        case .typeDecl(_, let fields, _):
            fields.forEach { collectType($0.type) }
        case .arrayLiteral(let elements, _):
            elements.forEach { $0.collectCompilerDependencies(into: &result) }
        case .index(let collection, let index, _):
            collection.collectCompilerDependencies(into: &result)
            index.collectCompilerDependencies(into: &result)
        case .indexAssignment(let name, let index, let value, _):
            result.insert(.symbol(name))
            index.collectCompilerDependencies(into: &result)
            value.collectCompilerDependencies(into: &result)
        case .recordLiteral(let name, let fields, _):
            result.insert(.type(name))
            fields.forEach { $0.value.collectCompilerDependencies(into: &result) }
        case .member(let base, _, _):
            base.collectCompilerDependencies(into: &result)
        case .memberAssignment(let name, _, let value, _):
            result.insert(.symbol(name))
            value.collectCompilerDependencies(into: &result)
        }
    }
}
