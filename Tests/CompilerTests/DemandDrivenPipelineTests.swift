import XCTest
import IncrementalParsing
@testable import Compiler

final class DemandDrivenPipelineTests: XCTestCase {
    func testUpdateDoesNotExecuteCompilerStages() throws {
        let session = CompilerDemandDrivenSession()
        try session.update(program(1), revision: 1)
        XCTAssertTrue(session.materializedStages.isEmpty)

        let semantic = try session.semantic()
        XCTAssertEqual(semantic.executedStages, [.semantic])
        XCTAssertEqual(session.materializedStages, [.semantic])
    }

    func testBytecodeDemandExecutesOnlyItsPrerequisiteChain() throws {
        let session = CompilerDemandDrivenSession()
        try session.update(program(1), revision: 1)
        let stack = try session.stackBytecode()
        XCTAssertEqual(
            stack.executedStages,
            [.semantic, .ir, .link, .stackBytecode])
        XCTAssertFalse(session.materializedStages.contains(.registerBytecode))

        let registers = try session.registerBytecode()
        XCTAssertEqual(registers.executedStages, [.registerBytecode])
        XCTAssertEqual(registers.reusedStages, [.link])
        XCTAssertEqual(
            registers.evidence.measurements.first {
                $0.dimension == .bytecodeOutputs
            }?.rebuilt, 1)
    }

    func testEquivalentRevisionRetainsMaterializedPipeline() throws {
        let session = CompilerDemandDrivenSession()
        let ast = program(1)
        try session.update(ast, revision: 1)
        let first = try session.linkedIR()
        try session.update(ast, revision: 2)
        let second = try session.linkedIR()
        XCTAssertTrue(first.value === second.value)
        XCTAssertTrue(second.executedStages.isEmpty)
        XCTAssertEqual(second.reusedStages, [.link])
    }

    func testChangedSyntaxInvalidatesDownstreamButSemanticDemandStaysLazy() throws {
        let session = CompilerDemandDrivenSession()
        try session.update(program(1), revision: 1)
        _ = try session.stackBytecode()
        try session.update(program(2), revision: 2)
        XCTAssertTrue(session.materializedStages.isEmpty)

        let semantic = try session.semantic()
        XCTAssertEqual(semantic.executedStages, [.semantic])
        XCTAssertEqual(session.materializedStages, [.semantic])
    }

    func testDemandedStackOutputMatchesEagerCompiler() throws {
        let ast = program(7)
        let session = CompilerDemandDrivenSession()
        try session.update(ast, revision: 1)
        XCTAssertEqual(
            try session.stackBytecode().value,
            try Compiler().compile(ast))
    }

    func testRejectsMissingAndStaleRevisions() throws {
        let session = CompilerDemandDrivenSession()
        XCTAssertThrowsError(try session.ir()) {
            XCTAssertEqual($0 as? CompilerDemandError, .noRevision)
        }
        try session.update(program(1), revision: 2)
        XCTAssertThrowsError(try session.update(program(1), revision: 2)) {
            XCTAssertEqual(
                $0 as? CompilerDemandError,
                .staleRevision(previous: 2, proposed: 2))
        }
    }

    private func program(_ value: Int64) -> ASTNode {
        .program(
            declarations: [],
            body: .block([
                .print(.intLiteral(value, type: .int), type: .null),
            ], type: .null),
            type: .null)
    }
}
