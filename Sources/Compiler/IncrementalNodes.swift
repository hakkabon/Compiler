import Foundation

public struct CompilerStableNodeID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct CompilerNodeDependency: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Reference identity shared by stable semantic and IR nodes.
public final class CompilerStableNode<Payload>: @unchecked Sendable {
    public let id: CompilerStableNodeID
    public let fingerprint: String
    public let payload: Payload
    public let dependencies: Set<CompilerNodeDependency>

    fileprivate init(id: CompilerStableNodeID, fingerprint: String, payload: Payload,
                     dependencies: Set<CompilerNodeDependency>) {
        self.id = id; self.fingerprint = fingerprint
        self.payload = payload; self.dependencies = dependencies
    }
}

public struct CompilerNodeCandidate<Payload> {
    public let id: CompilerStableNodeID
    public let fingerprint: String
    public let payload: Payload
    public let dependencies: Set<CompilerNodeDependency>

    public init(id: CompilerStableNodeID, fingerprint: String, payload: Payload,
                dependencies: Set<CompilerNodeDependency> = []) {
        self.id = id; self.fingerprint = fingerprint
        self.payload = payload; self.dependencies = dependencies
    }
}

public struct CompilerReuseEvidence: Sendable {
    public let reused: Set<CompilerStableNodeID>
    public let rebuilt: Set<CompilerStableNodeID>
    public let removed: Set<CompilerStableNodeID>
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
        var next: [CompilerStableNodeID: CompilerStableNode<Payload>] = [:]
        var reused: Set<CompilerStableNodeID> = [], rebuilt: Set<CompilerStableNodeID> = []
        for candidate in candidates {
            if let old = nodes[candidate.id], old.fingerprint == candidate.fingerprint,
               old.dependencies == candidate.dependencies,
               old.dependencies.isDisjoint(with: changedDependencies) {
                next[candidate.id] = old
                reused.insert(candidate.id)
            } else {
                next[candidate.id] = .init(id: candidate.id, fingerprint: candidate.fingerprint,
                                           payload: candidate.payload, dependencies: candidate.dependencies)
                rebuilt.insert(candidate.id)
            }
        }
        let removed = Set(nodes.keys).subtracting(next.keys)
        nodes = next
        return .init(reused: reused, rebuilt: rebuilt, removed: removed)
    }
}

/// Compiler-owned pair of arenas. Semantic nodes and lowered IR fragments
/// deliberately have independent fingerprints and invalidation boundaries.
public final class CompilerIncrementalWorkspace {
    public let semantics = CompilerStableNodeArena<ResolvedASTNode>()
    public let ir = CompilerStableNodeArena<[IROperation]>()
    public init() {}
}
