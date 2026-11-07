import XCTest
import IncrementalParsing
import Grammar
@testable import Compiler

final class IncrementalNodesTests: XCTestCase {
    func testStableSemanticAndIRNodesKeepIndependentIdentity() {
        let workspace = CompilerIncrementalWorkspace()
        let id = CompilerStableNodeID("syntax:expression:1")
        let semantic = CompilerNodeCandidate(id: id, fingerprint: "typed:int",
                                             payload: ResolvedASTNode.literal(.int(1), type: .int))
        _ = workspace.semantics.reconcile([semantic])
        let firstSemantic = workspace.semantics[id]
        let firstIRCandidate = CompilerNodeCandidate(id: id, fingerprint: "ir:const:1",
                                                     payload: [IROperation.constant(.int(1))])
        _ = workspace.ir.reconcile([firstIRCandidate])
        let firstIR = workspace.ir[id]

        let semanticEvidence = workspace.semantics.reconcile([semantic])
        let changedIR = CompilerNodeCandidate(id: id, fingerprint: "ir:const:2",
                                              payload: [IROperation.constant(.int(2))])
        let irEvidence = workspace.ir.reconcile([changedIR])

        XCTAssertTrue(workspace.semantics[id] === firstSemantic)
        XCTAssertFalse(workspace.ir[id] === firstIR)
        XCTAssertEqual(semanticEvidence.reused, [id])
        XCTAssertEqual(irEvidence.rebuilt, [id])
    }

    func testPublicSignatureControlsDependencyInvalidation() {
        let arena = CompilerStableNodeArena<String>()
        let declarationID = CompilerStableNodeID("decl:f")
        let callerID = CompilerStableNodeID("call:f")
        let function = CompilerNodeDependency.function("f")

        _ = arena.reconcile([
            .init(
                id: declarationID,
                fingerprint: "body:v1",
                payload: "body one",
                providedDependencies: [function: "signature:()->int"]),
            .init(
                id: callerID,
                fingerprint: "call:int",
                payload: "call",
                dependencies: [function]),
        ])
        let caller = arena[callerID]

        let bodyOnly = arena.reconcile([
            .init(
                id: declarationID,
                fingerprint: "body:v2",
                payload: "body two",
                providedDependencies: [function: "signature:()->int"]),
            .init(
                id: callerID,
                fingerprint: "call:int",
                payload: "call",
                dependencies: [function]),
        ])
        XCTAssertEqual(bodyOnly.rebuilt, [declarationID])
        XCTAssertEqual(bodyOnly.reused, [callerID])
        XCTAssertTrue(arena[callerID] === caller)
        XCTAssertFalse(bodyOnly.invalidatedDependencies.contains(function))

        let signatureChange = arena.reconcile([
            .init(
                id: declarationID,
                fingerprint: "body:v3",
                payload: "body three",
                providedDependencies: [function: "signature:()->string"]),
            .init(
                id: callerID,
                fingerprint: "call:int",
                payload: "call",
                dependencies: [function]),
        ])
        XCTAssertEqual(signatureChange.rebuilt, [declarationID, callerID])
        XCTAssertTrue(signatureChange.invalidatedDependencies.contains(function))
        XCTAssertFalse(arena[callerID] === caller)
    }

    func testIncrementalSessionReusesDependentSemanticsWhenSignatureIsStable() throws {
        let session = CompilerIncrementalSession()
        let declarationID = CompilerStableNodeID("statement:x")
        let useID = CompilerStableNodeID("statement:print-x")
        let independentID = CompilerStableNodeID("statement:print-literal")
        func units(value: Int64) -> [CompilerIncrementalUnit] {
            [
                .init(
                    id: declarationID,
                    ast: .varDecl(
                        name: "x",
                        initializer: .intLiteral(value, type: .int),
                        type: .int)),
                .init(
                    id: useID,
                    ast: .print(.variable("x", type: .any), type: .null)),
                .init(
                    id: independentID,
                    ast: .print(.intLiteral(9, type: .int), type: .null)),
            ]
        }

        let initial = try session.update(units(value: 1))
        XCTAssertEqual(initial.evidence.strategy, .full)
        let firstDeclaration = session.workspace.semantics[declarationID]
        let firstUse = session.workspace.semantics[useID]
        let firstIndependent = session.workspace.semantics[independentID]
        let firstUseIR = session.workspace.ir[useID]

        let edited = try session.update(units(value: 2))

        XCTAssertEqual(edited.evidence.strategy, .incremental)
        XCTAssertEqual(
            edited.evidence.measurements.first { $0.dimension == .semanticNodes }?.reused,
            2)
        XCTAssertEqual(
            edited.evidence.measurements.first { $0.dimension == .irNodes }?.rebuilt,
            1)
        XCTAssertEqual(edited.semanticReuse.rebuilt, [declarationID])
        XCTAssertEqual(edited.semanticReuse.reused, [useID, independentID])
        XCTAssertEqual(edited.irReuse.rebuilt, [declarationID])
        XCTAssertEqual(edited.irReuse.reused, [useID, independentID])
        XCTAssertFalse(session.workspace.semantics[declarationID] === firstDeclaration)
        XCTAssertTrue(session.workspace.semantics[useID] === firstUse)
        XCTAssertTrue(session.workspace.semantics[independentID] === firstIndependent)
        XCTAssertTrue(session.workspace.ir[useID] === firstUseIR)
        XCTAssertTrue(edited.artifacts.ir.operations.contains(.constant(.int(2))))
    }

    func testFunctionBodyEditDoesNotInvalidateStableCallers() throws {
        let session = CompilerIncrementalSession()
        let functionID = CompilerStableNodeID("function:answer")
        let callerID = CompilerStableNodeID("statement:call-answer")
        func units(value: Int64) -> [CompilerIncrementalUnit] {
            [
                .init(
                    id: functionID,
                    ast: .functionDecl(
                        name: "answer",
                        parameters: [],
                        returnType: .int,
                        body: .block([
                            .returnStmt(.intLiteral(value, type: .int), type: .null),
                        ], type: .null),
                        type: .null)),
                .init(
                    id: callerID,
                    ast: .print(
                        .call(name: "answer", arguments: [], type: .any),
                        type: .null)),
            ]
        }

        _ = try session.update(units(value: 41))
        let callerSemantic = session.workspace.semantics[callerID]
        let callerIR = session.workspace.ir[callerID]
        let edited = try session.update(units(value: 42))

        XCTAssertEqual(edited.semanticReuse.rebuilt, [functionID])
        XCTAssertEqual(edited.semanticReuse.reused, [callerID])
        XCTAssertEqual(edited.irReuse.rebuilt, [functionID])
        XCTAssertEqual(edited.irReuse.reused, [callerID])
        XCTAssertTrue(session.workspace.semantics[callerID] === callerSemantic)
        XCTAssertTrue(session.workspace.ir[callerID] === callerIR)
        XCTAssertFalse(edited.semanticReuse.invalidatedDependencies.contains(.function("answer")))
    }

    func testIncrementalSessionRejectsDuplicateStableSyntaxIdentity() {
        let id = CompilerStableNodeID("duplicate")
        XCTAssertThrowsError(try CompilerIncrementalSession().update([
            .init(id: id, ast: .print(.intLiteral(1, type: .int), type: .null)),
            .init(id: id, ast: .print(.intLiteral(2, type: .int), type: .null)),
        ])) {
            XCTAssertEqual($0 as? CompilerIncrementalError, .duplicateUnit(id))
        }
    }

    func testRemovedUnitsLeaveBothArenasAndSharedEvidence() throws {
        let session = CompilerIncrementalSession()
        let retained = CompilerIncrementalUnit(
            id: .init("statement:retained"),
            ast: .print(.intLiteral(1, type: .int), type: .null))
        let removed = CompilerIncrementalUnit(
            id: .init("statement:removed"),
            ast: .print(.intLiteral(2, type: .int), type: .null))
        _ = try session.update([retained, removed])

        let result = try session.update([retained])

        XCTAssertEqual(result.semanticReuse.removed, [removed.id])
        XCTAssertEqual(result.irReuse.removed, [removed.id])
        XCTAssertNil(session.workspace.semantics[removed.id])
        XCTAssertNil(session.workspace.ir[removed.id])
        XCTAssertEqual(
            result.evidence.measurements.first { $0.dimension == .semanticNodes }?.removed,
            1)
        XCTAssertEqual(
            result.evidence.measurements.first { $0.dimension == .irNodes }?.removed,
            1)
    }

    func testArtifactIdentityChangeForcesFreshSemanticAndIRBaselines() throws {
        let session = CompilerIncrementalSession()
        let unit = CompilerIncrementalUnit(
            id: .init("statement:one"),
            ast: .print(.intLiteral(1, type: .int), type: .null))
        let firstArtifact = IncrementalArtifactIdentity(
            id: "compiler-language", revision: 1, fingerprint: "grammar-one")
        let secondArtifact = IncrementalArtifactIdentity(
            id: "compiler-language", revision: 2, fingerprint: "grammar-two")

        _ = try session.update([unit], artifactIdentity: firstArtifact)
        let oldSemantic = session.workspace.semantics[unit.id]
        let changed = try session.update([unit], artifactIdentity: secondArtifact)

        XCTAssertEqual(changed.evidence.strategy, .full)
        XCTAssertEqual(changed.semanticReuse.rebuilt, [unit.id])
        XCTAssertEqual(changed.irReuse.rebuilt, [unit.id])
        XCTAssertFalse(session.workspace.semantics[unit.id] === oldSemantic)
    }

    func testVerifiedGrammarChangeInvalidatesOnlyDependentSemantics() throws {
        let old = try Grammar(bnf: """
            S ::= B
            B ::= 'b'
            U ::= 'u'
            """, start: "S")
        let changed = try Grammar(bnf: """
            S ::= B
            B ::= 'b' | 'other'
            U ::= 'u'
            """, start: "S")
        let affectedID = CompilerStableNodeID("affected")
        let stableID = CompilerStableNodeID("stable")
        func units(_ grammar: Grammar) -> [CompilerIncrementalUnit] {
            [
                .init(
                    id: affectedID,
                    ast: .print(.intLiteral(1, type: .int), type: .null),
                    productionDependencies: [GrammarProductionID(grammar.productions[1])]),
                .init(
                    id: stableID,
                    ast: .print(.intLiteral(2, type: .int), type: .null),
                    productionDependencies: [GrammarProductionID(grammar.productions[2])]),
            ]
        }
        let firstArtifact = IncrementalArtifactIdentity(
            id: "compiler-language", revision: 1,
            fingerprint: old.incrementalSemanticFingerprint)
        let secondArtifact = IncrementalArtifactIdentity(
            id: "compiler-language", revision: 2,
            fingerprint: changed.incrementalSemanticFingerprint)
        let session = CompilerIncrementalSession()
        _ = try session.update(units(old), artifactIdentity: firstArtifact)
        let stableNode = session.workspace.semantics[stableID]

        let result = try session.update(
            units(old),
            artifactIdentity: secondArtifact,
            grammarChange: old.changeSet(to: changed))

        XCTAssertEqual(result.evidence.strategy, .incremental)
        XCTAssertTrue(result.semanticReuse.rebuilt.contains(affectedID))
        XCTAssertTrue(result.semanticReuse.reused.contains(stableID))
        XCTAssertTrue(session.workspace.semantics[stableID] === stableNode)
        XCTAssertNotNil(result.evidence.measurements.first {
            $0.dimension == .grammarProductions
        })
    }

    func testIncrementalEditCampaignMatchesFreshCompilation() throws {
        let declarationID = CompilerStableNodeID("statement:counter")
        let printID = CompilerStableNodeID("statement:print-counter")
        func units(_ value: Int64) -> [CompilerIncrementalUnit] {
            [
                .init(
                    id: declarationID,
                    ast: .varDecl(
                        name: "counter",
                        initializer: .intLiteral(value, type: .int),
                        type: .int)),
                .init(
                    id: printID,
                    ast: .print(.variable("counter", type: .any), type: .null)),
            ]
        }
        let incremental = CompilerIncrementalSession()

        for value in [Int64(1), 2, 100, -4] {
            let actual = try incremental.update(units(value))
            let fresh = try CompilerIncrementalSession().update(units(value))
            XCTAssertEqual(actual.artifacts.sourceAST, fresh.artifacts.sourceAST)
            XCTAssertEqual(actual.artifacts.typedAST, fresh.artifacts.typedAST)
            XCTAssertEqual(actual.artifacts.symbols, fresh.artifacts.symbols)
            XCTAssertEqual(actual.artifacts.ir, fresh.artifacts.ir)
        }
    }
}
