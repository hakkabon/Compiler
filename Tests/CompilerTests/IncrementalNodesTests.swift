import XCTest
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
}
