import Foundation
import IncrementalParsing

public enum CompilerPipelineStage: String, CaseIterable, Hashable, Codable,
    Sendable {
    case semantic
    case ir
    case link
    case stackBytecode
    case registerBytecode
}

public enum CompilerDemandError: Error, Equatable, Sendable {
    case noRevision
    case staleRevision(previous: UInt64, proposed: UInt64)
}

public struct CompilerDemandResult<Value: Sendable>: Sendable {
    public let value: Value
    public let requestedStage: CompilerPipelineStage
    public let executedStages: [CompilerPipelineStage]
    public let reusedStages: [CompilerPipelineStage]
    public let evidence: IncrementalExecutionEvidence
}

/// A lazy compiler document. Submitting syntax performs no semantic or backend
/// work. Each demand materializes only its prerequisite chain, and independent
/// bytecode backends share semantic, IR, and linked-IR results.
public final class CompilerDemandDrivenSession {
    private var revision: UInt64?
    private var sourceAST: ASTNode?
    private var semanticCache: SemanticResult?
    private var irCache: IRProgram?
    private var linkCache: CompilerLinkedOutput?
    private var stackCache: StackCompilation?
    private var registerCache: RegisterCompilation?

    public init() {}

    public var currentRevision: UInt64? { revision }

    public var materializedStages: Set<CompilerPipelineStage> {
        var stages: Set<CompilerPipelineStage> = []
        if semanticCache != nil { stages.insert(.semantic) }
        if irCache != nil { stages.insert(.ir) }
        if linkCache != nil { stages.insert(.link) }
        if stackCache != nil { stages.insert(.stackBytecode) }
        if registerCache != nil { stages.insert(.registerBytecode) }
        return stages
    }

    /// Installs a syntax revision without executing a compiler pass. Equivalent
    /// syntax advances the caller-owned revision while retaining every cached
    /// stage; changed syntax invalidates the complete dependent chain.
    public func update(_ ast: ASTNode, revision proposed: UInt64) throws {
        if let revision, proposed <= revision {
            throw CompilerDemandError.staleRevision(
                previous: revision, proposed: proposed)
        }
        if sourceAST != ast {
            sourceAST = ast
            semanticCache = nil
            irCache = nil
            linkCache = nil
            stackCache = nil
            registerCache = nil
        }
        revision = proposed
    }

    public func reset() {
        revision = nil
        sourceAST = nil
        semanticCache = nil
        irCache = nil
        linkCache = nil
        stackCache = nil
        registerCache = nil
    }

    public func semantic() throws -> CompilerDemandResult<SemanticResult> {
        var trace = Trace()
        let value = try requireSemantic(trace: &trace)
        return result(value, requested: .semantic, trace: trace)
    }

    public func ir() throws -> CompilerDemandResult<IRProgram> {
        var trace = Trace()
        let value = try requireIR(trace: &trace)
        return result(value, requested: .ir, trace: trace)
    }

    public func linkedIR() throws -> CompilerDemandResult<CompilerLinkedOutput> {
        var trace = Trace()
        let value = try requireLink(trace: &trace)
        return result(value, requested: .link, trace: trace)
    }

    public func stackBytecode() throws
        -> CompilerDemandResult<StackCompilation> {
        var trace = Trace()
        let value: StackCompilation
        if let stackCache {
            trace.reused.append(.stackBytecode)
            value = stackCache
        } else {
            value = try StackCodeGenerator.generate(
                requireLink(trace: &trace).ir)
            stackCache = value
            trace.executed.append(.stackBytecode)
        }
        return result(value, requested: .stackBytecode, trace: trace)
    }

    public func registerBytecode() throws
        -> CompilerDemandResult<RegisterCompilation> {
        var trace = Trace()
        let value: RegisterCompilation
        if let registerCache {
            trace.reused.append(.registerBytecode)
            value = registerCache
        } else {
            value = try RegisterCodeGenerator.generate(
                requireLink(trace: &trace).ir)
            registerCache = value
            trace.executed.append(.registerBytecode)
        }
        return result(value, requested: .registerBytecode, trace: trace)
    }

    private struct Trace {
        var executed: [CompilerPipelineStage] = []
        var reused: [CompilerPipelineStage] = []
    }

    private func requireSemantic(trace: inout Trace) throws -> SemanticResult {
        if let semanticCache {
            trace.reused.append(.semantic)
            return semanticCache
        }
        guard let sourceAST else { throw CompilerDemandError.noRevision }
        let value = try SemanticAnalyzer().analyzeProgram(sourceAST)
        semanticCache = value
        trace.executed.append(.semantic)
        return value
    }

    private func requireIR(trace: inout Trace) throws -> IRProgram {
        if let irCache {
            trace.reused.append(.ir)
            return irCache
        }
        let value = try IRLowerer().lower(requireSemantic(trace: &trace))
        irCache = value
        trace.executed.append(.ir)
        return value
    }

    private func requireLink(trace: inout Trace) throws -> CompilerLinkedOutput {
        if let linkCache {
            trace.reused.append(.link)
            return linkCache
        }
        let ir = try requireIR(trace: &trace)
        let fingerprint = stableCompilerFingerprint(
            "compiler-demand-link-v1:\(String(reflecting: ir))")
        let value = CompilerLinkedOutput(fingerprint: fingerprint, ir: ir)
        linkCache = value
        trace.executed.append(.link)
        return value
    }

    private func result<Value: Sendable>(
        _ value: Value,
        requested: CompilerPipelineStage,
        trace: Trace
    ) -> CompilerDemandResult<Value> {
        var measurements = [ReuseMeasurement(
            dimension: .compilerStages,
            reused: trace.reused.count,
            rebuilt: trace.executed.count,
            strategy: "demand-driven-prerequisite-chain")]
        if requested == .link {
            measurements.append(.init(
                dimension: .linkedOutputs,
                reused: trace.reused.contains(.link) ? 1 : 0,
                rebuilt: trace.executed.contains(.link) ? 1 : 0,
                strategy: "demand-linked-ir"))
        } else if requested == .stackBytecode || requested == .registerBytecode {
            measurements.append(.init(
                dimension: .bytecodeOutputs,
                reused: trace.reused.contains(requested) ? 1 : 0,
                rebuilt: trace.executed.contains(requested) ? 1 : 0,
                strategy: "demand-bytecode-backend"))
        }
        return .init(
            value: value, requestedStage: requested,
            executedStages: trace.executed, reusedStages: trace.reused,
            evidence: .init(
                strategy: trace.reused.isEmpty ? .full : .incremental,
                measurements: measurements))
    }
}
