import Foundation
import Grammar
import IncrementalParsing

/// Stable identity of one source module (or file group) in a compiler project.
public struct CompilerProjectModuleID: RawRepresentable, Hashable, Codable,
    Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "a compiler module identity cannot be empty")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One revisioned project module. Unit identities must be stable and unique
/// across the complete project, not merely within this module.
public struct CompilerProjectModule: Equatable, Sendable {
    public let id: CompilerProjectModuleID
    public let imports: Set<CompilerProjectModuleID>
    public let units: [CompilerIncrementalUnit]

    public init(
        id: CompilerProjectModuleID,
        imports: Set<CompilerProjectModuleID> = [],
        units: [CompilerIncrementalUnit]
    ) {
        self.id = id
        self.imports = imports
        self.units = units
    }
}

/// An atomic project view. Revisions are caller-owned and strictly monotonic.
public struct CompilerProjectSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let modules: [CompilerProjectModule]

    public init(revision: UInt64, modules: [CompilerProjectModule]) {
        self.revision = revision
        self.modules = modules
    }
}

public enum CompilerProjectError: Error, Equatable, Sendable {
    case staleRevision(previous: UInt64, proposed: UInt64)
    case duplicateModule(CompilerProjectModuleID)
    case missingImport(module: CompilerProjectModuleID, imported: CompilerProjectModuleID)
    case duplicateUnit(CompilerStableNodeID)
}

/// Identity-preserving final compiler output. Equal whole-program IR retains
/// this object even when project metadata or intermediate nodes changed.
public final class CompilerLinkedOutput: @unchecked Sendable {
    public let fingerprint: String
    public let ir: IRProgram

    init(fingerprint: String, ir: IRProgram) {
        self.fingerprint = fingerprint
        self.ir = ir
    }
}

public struct CompilerProjectResult: Sendable {
    public let revision: UInt64
    public let compilation: CompilerIncrementalResult
    public let linkedOutput: CompilerLinkedOutput
    public let reusedModules: Set<CompilerProjectModuleID>
    public let rebuiltModules: Set<CompilerProjectModuleID>
    public let removedModules: Set<CompilerProjectModuleID>
    public let interfaceChangedModules: Set<CompilerProjectModuleID>
    public let invalidatedModules: Set<CompilerProjectModuleID>
    public let evidence: IncrementalExecutionEvidence
}

/// Project-level orchestration over Compiler's canonical semantic and IR
/// incremental session.
///
/// Modules share one semantic program, so ordinary symbol/function/type edges
/// continue to be derived by Compiler. Import edges add a conservative module
/// dependency: an exported-interface change rebuilds transitive importers, while a
/// body-only change does not propagate beyond its defining module.
public final class CompilerProjectSession {
    private struct ModuleState {
        let imports: Set<CompilerProjectModuleID>
        let unitIDs: Set<CompilerStableNodeID>
        let interfaceFingerprint: String
    }

    public let compiler: CompilerIncrementalSession
    public private(set) var revision: UInt64?
    public private(set) var linkedOutput: CompilerLinkedOutput?
    private var modules: [CompilerProjectModuleID: ModuleState] = [:]

    public init(compiler: CompilerIncrementalSession = .init()) {
        self.compiler = compiler
    }

    public func reset() {
        compiler.reset()
        revision = nil
        linkedOutput = nil
        modules.removeAll()
    }

    public func update(
        _ snapshot: CompilerProjectSnapshot,
        artifactIdentity: IncrementalArtifactIdentity? = nil,
        grammarChange: GrammarChangeSet? = nil
    ) throws -> CompilerProjectResult {
        if let revision, snapshot.revision <= revision {
            throw CompilerProjectError.staleRevision(
                previous: revision, proposed: snapshot.revision)
        }

        var current: [CompilerProjectModuleID: CompilerProjectModule] = [:]
        for module in snapshot.modules {
            guard current.updateValue(module, forKey: module.id) == nil else {
                throw CompilerProjectError.duplicateModule(module.id)
            }
        }
        for module in snapshot.modules {
            for imported in module.imports where current[imported] == nil {
                throw CompilerProjectError.missingImport(
                    module: module.id, imported: imported)
            }
        }

        var unitOwners: [CompilerStableNodeID: CompilerProjectModuleID] = [:]
        for module in snapshot.modules {
            for unit in module.units {
                guard unitOwners.updateValue(module.id, forKey: unit.id) == nil else {
                    throw CompilerProjectError.duplicateUnit(unit.id)
                }
            }
        }

        let currentInterfaces = Dictionary(uniqueKeysWithValues: snapshot.modules.map {
            ($0.id, moduleInterfaceFingerprint($0))
        })
        let removedModules = Set(modules.keys).subtracting(current.keys)
        var interfaceChanged = removedModules
        if revision != nil {
            for module in snapshot.modules
                where modules[module.id]?.interfaceFingerprint
                    != currentInterfaces[module.id] {
                interfaceChanged.insert(module.id)
            }
        }

        // A changed import list can change resolution even when a module's
        // declarations and source units are identical.
        let changedImports = snapshot.modules.compactMap { module -> CompilerProjectModuleID? in
            guard let previous = modules[module.id],
                  previous.imports != module.imports else { return nil }
            return module.id
        }
        var importers: [CompilerProjectModuleID: [CompilerProjectModuleID]] = [:]
        for module in snapshot.modules {
            for imported in module.imports {
                importers[imported, default: []].append(module.id)
            }
        }
        var invalidatedModules = interfaceChanged.union(changedImports)
        var invalidationWork = Array(invalidatedModules)
        while let changed = invalidationWork.popLast() {
            for importer in importers[changed, default: []]
                where invalidatedModules.insert(importer).inserted {
                invalidationWork.append(importer)
            }
        }
        let changedDependencies = Set(invalidatedModules.map {
            CompilerNodeDependency.module($0.rawValue)
        })
        let flattenedUnits = snapshot.modules.sorted { $0.id < $1.id }.flatMap { module in
            let importedDependencies = Set(module.imports.map {
                CompilerNodeDependency.module($0.rawValue)
            }).union([.module(module.id.rawValue)])
            return module.units.map { unit in
                CompilerIncrementalUnit(
                    id: unit.id,
                    ast: unit.ast,
                    productionDependencies: unit.productionDependencies,
                    externalDependencies: unit.externalDependencies
                        .union(importedDependencies))
            }
        }

        let compilation = try compiler.update(
            flattenedUnits,
            artifactIdentity: artifactIdentity,
            grammarChange: grammarChange,
            changedDependencies: changedDependencies)

        var reusedModules: Set<CompilerProjectModuleID> = []
        for module in snapshot.modules {
            let ids = Set(module.units.map(\.id))
            guard !invalidatedModules.contains(module.id),
                  let old = modules[module.id],
                  old.imports == module.imports,
                  old.unitIDs == ids,
                  ids.isSubset(of: compilation.semanticReuse.reused) else {
                continue
            }
            reusedModules.insert(module.id)
        }
        let currentModuleIDs = Set(current.keys)
        let rebuiltModules = currentModuleIDs.subtracting(reusedModules)

        let outputFingerprint = linkedIRFingerprint(compilation.artifacts.ir)
        let outputWasReused: Bool
        let nextOutput: CompilerLinkedOutput
        if let linkedOutput, linkedOutput.ir == compilation.artifacts.ir {
            nextOutput = linkedOutput
            outputWasReused = true
        } else {
            nextOutput = .init(
                fingerprint: outputFingerprint,
                ir: compilation.artifacts.ir)
            outputWasReused = false
        }

        let projectMeasurements = [
            ReuseMeasurement(
                dimension: .compilerModules,
                reused: reusedModules.count,
                rebuilt: rebuiltModules.count,
                removed: removedModules.count,
                strategy: "interface-indexed-project-graph"),
            ReuseMeasurement(
                dimension: .linkedOutputs,
                reused: outputWasReused ? 1 : 0,
                rebuilt: outputWasReused ? 0 : 1,
                strategy: "whole-program-ir-convergence"),
        ]
        let evidence = IncrementalExecutionEvidence(
            strategy: compilation.evidence.strategy,
            fallback: compilation.evidence.fallback,
            measurements: compilation.evidence.measurements + projectMeasurements)

        modules = Dictionary(uniqueKeysWithValues: snapshot.modules.map { module in
            (module.id, ModuleState(
                imports: module.imports,
                unitIDs: Set(module.units.map(\.id)),
                interfaceFingerprint: currentInterfaces[module.id]!))
        })
        revision = snapshot.revision
        linkedOutput = nextOutput

        return .init(
            revision: snapshot.revision,
            compilation: compilation,
            linkedOutput: nextOutput,
            reusedModules: reusedModules,
            rebuiltModules: rebuiltModules,
            removedModules: removedModules,
            interfaceChangedModules: interfaceChanged,
            invalidatedModules: invalidatedModules,
            evidence: evidence)
    }
}

private func moduleInterfaceFingerprint(_ module: CompilerProjectModule) -> String {
    let signatures = module.units.compactMap { unit -> String? in
        let signature: String
        switch unit.ast {
        case .functionDecl(let name, let parameters, let returnType, _, _):
            let parameterTypes = parameters.map {
                projectTypeMaterial($0.type)
            }.joined(separator: ",")
            signature = "function:\(projectFrame(name)):(\(parameterTypes))->\(projectTypeMaterial(returnType))"
        case .typeDecl(let name, let fields, _):
            let fieldTypes = fields.map {
                projectFrame($0.name) + projectFrame(projectTypeMaterial($0.type))
            }.joined()
            signature = "type:\(projectFrame(name)):\(fieldTypes)"
        case .varDecl(let name, let initializer, let type):
            let inferredMaterial = type == .any
                ? projectFrame(String(reflecting: initializer)) : ""
            signature = "variable:\(projectFrame(name)):\(projectTypeMaterial(type)):\(inferredMaterial)"
        default:
            return nil
        }
        return projectFrame(unit.id.rawValue) + projectFrame(signature)
    }.sorted().joined()
    return stableCompilerFingerprint("compiler-module-interface-v1:\(signatures)")
}

private func linkedIRFingerprint(_ ir: IRProgram) -> String {
    let functions = ir.functions.map {
        projectFrame($0.name)
            + ":\($0.entry.rawValue):"
            + $0.parameterSlots.map(String.init).map(projectFrame).joined()
    }.joined()
    return stableCompilerFingerprint(
        "compiler-linked-ir-v1:\(ir.localCount):"
            + projectFrame(irMaterial(ir.operations))
            + projectFrame(functions))
}

private func projectTypeMaterial(_ type: TypeInfo) -> String {
    switch type {
    case .int: "int"
    case .float: "float"
    case .string: "string"
    case .boolean: "boolean"
    case .null: "null"
    case .any: "any"
    case .array(let element): "array(\(projectTypeMaterial(element)))"
    case .record(let name): "record(\(projectFrame(name)))"
    }
}

private func projectFrame(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
}

