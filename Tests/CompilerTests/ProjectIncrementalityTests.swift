import XCTest
import IncrementalParsing
@testable import Compiler

final class ProjectIncrementalityTests: XCTestCase {
    private let library: CompilerProjectModuleID = "library"
    private let application: CompilerProjectModuleID = "application"
    private let utility: CompilerProjectModuleID = "utility"
    private let functionID = CompilerStableNodeID("library:function:answer")
    private let callID = CompilerStableNodeID("application:call:answer")

    func testBodyOnlyEditRebuildsDefiningModuleButRetainsImporter() throws {
        let session = CompilerProjectSession()
        _ = try session.update(snapshot(revision: 1, answer: .int(41)))
        let importedSemantic = session.compiler.workspace.semantics[callID]

        let edited = try session.update(snapshot(revision: 2, answer: .int(42)))

        XCTAssertEqual(edited.interfaceChangedModules, [])
        XCTAssertEqual(edited.rebuiltModules, [library])
        XCTAssertEqual(edited.reusedModules, [application])
        XCTAssertTrue(session.compiler.workspace.semantics[callID] === importedSemantic)
        XCTAssertEqual(
            edited.evidence.measurements.first {
                $0.dimension == .compilerModules
            }?.reused,
            1)
        XCTAssertEqual(
            edited.evidence.measurements.first {
                $0.dimension == .linkedOutputs
            }?.rebuilt,
            1)
    }

    func testInterfaceChangeInvalidatesDirectImporter() throws {
        let session = CompilerProjectSession()
        _ = try session.update(snapshot(revision: 1, answer: .int(41)))

        let edited = try session.update(
            snapshot(revision: 2, answer: .string("forty-two")))

        XCTAssertEqual(edited.interfaceChangedModules, [library])
        XCTAssertEqual(edited.rebuiltModules, [library, application])
        XCTAssertTrue(edited.compilation.semanticReuse.invalidatedDependencies
            .contains(.module(library.rawValue)))
    }

    func testInterfaceChangeInvalidatesTransitiveReverseImportClosure() throws {
        let bridge: CompilerProjectModuleID = "bridge"
        let session = CompilerProjectSession()
        func project(revision: UInt64, answer: Answer) -> CompilerProjectSnapshot {
            let base = snapshot(revision: revision, answer: answer)
            let libraryModule = base.modules.first { $0.id == library }!
            let applicationModule = base.modules.first { $0.id == application }!
            return .init(revision: revision, modules: [
                libraryModule,
                .init(id: bridge, imports: [library], units: []),
                .init(
                    id: application,
                    imports: [bridge],
                    units: applicationModule.units),
            ])
        }
        _ = try session.update(project(revision: 1, answer: .int(1)))

        let edited = try session.update(project(
            revision: 2, answer: .string("one")))

        XCTAssertEqual(edited.interfaceChangedModules, [library])
        XCTAssertEqual(edited.invalidatedModules, [library, bridge, application])
        XCTAssertEqual(edited.rebuiltModules, [library, bridge, application])
    }

    func testEquivalentLinkedIRRetainsOutputAcrossProjectMetadataChange() throws {
        let session = CompilerProjectSession()
        let initial = try session.update(snapshot(
            revision: 1, answer: .int(42), includeUtility: true,
            applicationImportsUtility: false))

        let edited = try session.update(snapshot(
            revision: 2, answer: .int(42), includeUtility: true,
            applicationImportsUtility: true))

        XCTAssertTrue(edited.linkedOutput === initial.linkedOutput)
        XCTAssertTrue(edited.rebuiltModules.contains(application))
        XCTAssertTrue(edited.reusedModules.contains(library))
        XCTAssertTrue(edited.reusedModules.contains(utility))
        XCTAssertEqual(
            edited.evidence.measurements.first {
                $0.dimension == .linkedOutputs
            }?.reused,
            1)
    }

    func testImportListChangeInvalidatesTransitiveImporters() throws {
        let session = CompilerProjectSession()
        let bridge: CompilerProjectModuleID = "bridge"
        func project(_ revision: UInt64, imports: Set<CompilerProjectModuleID>)
            -> CompilerProjectSnapshot {
            let base = snapshot(revision: revision, answer: .int(42))
            return .init(revision: revision, modules: base.modules.map { module in
                guard module.id == application else { return module }
                return .init(id: application, imports: [bridge], units: module.units)
            } + [.init(id: bridge, imports: imports, units: [])])
        }
        _ = try session.update(project(1, imports: [library]))
        let updated = try session.update(project(2, imports: []))
        XCTAssertEqual(updated.interfaceChangedModules, [])
        XCTAssertEqual(updated.invalidatedModules, [bridge, application])
        XCTAssertEqual(updated.reusedModules, [library])
        XCTAssertEqual(updated.linkedOutput.ir,
                       try CompilerProjectSession().update(project(2, imports: [])).linkedOutput.ir)
    }

    func testRemovingUnreferencedModuleRetainsLinkedOutputAndReportsRemoval() throws {
        let session = CompilerProjectSession()
        let initial = try session.update(snapshot(
            revision: 1, answer: .int(42), includeUtility: true))

        let edited = try session.update(snapshot(
            revision: 2, answer: .int(42), includeUtility: false))

        XCTAssertEqual(edited.removedModules, [utility])
        XCTAssertTrue(edited.linkedOutput === initial.linkedOutput)
        XCTAssertEqual(
            edited.evidence.measurements.first {
                $0.dimension == .compilerModules
            }?.removed,
            1)
    }

    func testProjectCampaignMatchesFreshWholeProgramCompilation() throws {
        let incremental = CompilerProjectSession()
        for (revision, value) in [41, 42, 100].enumerated() {
            let project = snapshot(
                revision: UInt64(revision + 1), answer: .int(Int64(value)))
            let actual = try incremental.update(project)
            let fresh = try CompilerProjectSession().update(project)

            XCTAssertEqual(
                actual.compilation.artifacts.sourceAST,
                fresh.compilation.artifacts.sourceAST)
            XCTAssertEqual(
                actual.compilation.artifacts.typedAST,
                fresh.compilation.artifacts.typedAST)
            XCTAssertEqual(
                actual.compilation.artifacts.symbols,
                fresh.compilation.artifacts.symbols)
            XCTAssertEqual(actual.linkedOutput.ir, fresh.linkedOutput.ir)
        }
    }

    func testProjectValidationIsAtomicAndRevisioned() throws {
        let session = CompilerProjectSession()
        _ = try session.update(snapshot(revision: 2, answer: .int(42)))

        XCTAssertThrowsError(try session.update(
            snapshot(revision: 2, answer: .int(43)))) {
            XCTAssertEqual(
                $0 as? CompilerProjectError,
                .staleRevision(previous: 2, proposed: 2))
        }
        let missing: CompilerProjectModuleID = "missing"
        XCTAssertThrowsError(try CompilerProjectSession().update(.init(
            revision: 1,
            modules: [.init(id: application, imports: [missing], units: [])]))) {
            XCTAssertEqual(
                $0 as? CompilerProjectError,
                .missingImport(module: application, imported: missing))
        }
        XCTAssertEqual(session.revision, 2)
    }

    private enum Answer {
        case int(Int64)
        case string(String)

        var returnType: TypeInfo {
            switch self { case .int: .int; case .string: .string }
        }

        var expression: ASTNode {
            switch self {
            case .int(let value): .intLiteral(value, type: .int)
            case .string(let value): .stringLiteral(value, type: .string)
            }
        }
    }

    private func snapshot(
        revision: UInt64,
        answer: Answer,
        includeUtility: Bool = false,
        applicationImportsUtility: Bool = false
    ) -> CompilerProjectSnapshot {
        let function = CompilerIncrementalUnit(
            id: functionID,
            ast: .functionDecl(
                name: "answer",
                parameters: [],
                returnType: answer.returnType,
                body: .block([
                    .returnStmt(answer.expression, type: .null),
                ], type: .null),
                type: .null))
        let call = CompilerIncrementalUnit(
            id: callID,
            ast: .print(
                .call(name: "answer", arguments: [], type: .any),
                type: .null))
        var imports: Set<CompilerProjectModuleID> = [library]
        if applicationImportsUtility { imports.insert(utility) }
        var modules = [
            CompilerProjectModule(id: library, units: [function]),
            CompilerProjectModule(
                id: application, imports: imports, units: [call]),
        ]
        if includeUtility {
            modules.append(.init(id: utility, units: []))
        }
        return .init(revision: revision, modules: modules)
    }
}
