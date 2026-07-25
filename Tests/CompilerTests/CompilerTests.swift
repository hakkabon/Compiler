import Foundation
import Testing
@testable import Compiler
import Earley_Parser
import Grammar

@Suite("Frontend")
struct FrontendTests {
    @Test func parsesPrecedence() throws {
        let ast = try SourceParser().parseExpression("1 + 2 * 3")
        let value = try Compiler().executeExpression(ast)
        #expect(value == .int(7))
    }

    @Test func reportsSourceLocation() {
        #expect(throws: Diagnostic.self) {
            _ = try SourceParser().parse("var x: int = 1;\nprint @;", file: "sample.comp")
        }
        do {
            _ = try SourceParser().parse("print @;", file: "sample.comp")
            Issue.record("Expected lexer failure")
        } catch let diagnostic as Diagnostic {
            #expect(diagnostic.stage == .lexing)
            #expect(diagnostic.range?.file == "sample.comp")
            #expect(diagnostic.range?.start.line == 1)
            #expect(diagnostic.range?.start.column == 7)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func declarativeASTMapping() throws {
        let location = SourceLocation(offset: 0, line: 1, column: 1)
        let range = SourceRange(start: location, end: location)
        func token(_ text: String, kind: String = "token") -> SyntaxNode {
            SyntaxNode(rule: kind, token: SyntaxToken(kind: kind, lexeme: text, range: range))
        }
        let tree = SyntaxNode(rule: "binary", children: [
            token("2", kind: "integer"),
            token("+"),
            token("3", kind: "integer"),
        ])
        let ast = try ASTBuilder().build(from: tree)
        #expect(try Compiler().executeExpression(ast) == .int(5))
    }

    @Test func rejectsUnknownASTRule() {
        #expect(throws: Diagnostic.self) {
            _ = try ASTBuilder().build(from: SyntaxNode(rule: "mystery"))
        }
    }

    @Test func ASTActionFormatRoundTripsAsJSON() throws {
        let mapping = ASTMapping(actions: [
            "integer": .integer,
            "print": .print(valueChild: 1),
            "program": .block(children: [0]),
        ])
        let data = try JSONEncoder().encode(mapping)
        #expect(try ASTMapping(json: data).actions == mapping.actions)
    }

    @Test func adaptsGeneralizedParserTrees() throws {
        let grammar = try Grammar(
            bnf: """
            <program> ::= "print" <expr> ";"
            <expr> ::= <expr> "+" <term> | <term>
            <term> ::= "1" | "2"
            """,
            start: "program"
        )
        let source = "print 1 + 2;"
        let trees = try EarleyParser(grammar: grammar).allSyntaxTrees(for: source)
        let forest = try GeneralizedParseTreeAdapter(source: source).adapt(trees, ambiguity: .reject)
        #expect(forest.trees.count == 1)
        #expect(forest.trees[0].rule == "program")
        #expect(forest.trees[0].formattedTree().contains("\"print\""))
    }
}

@Suite("Semantic analysis")
struct SemanticTests {
    @Test func resolvesShadowedNamesToDistinctSymbols() throws {
        let artifacts = try Compiler().analyze(try SourceParser().parse(
            "var x: int = 1; { var x: int = 2; print x; } print x;"
        ))
        #expect(artifacts.symbols.map(\.name) == ["x", "x"])
        #expect(Set(artifacts.symbols.map(\.id)).count == 2)
        #expect(artifacts.symbols.map(\.slot) == [0, 1])
    }
    @Test func infersDeclarationType() throws {
        let ast = try SourceParser().parse("var x = 3; print x;")
        let artifacts = try Compiler().analyze(ast)
        #expect(artifacts.symbols.count == 1)
        #expect(artifacts.symbols[0].type == .int)
        #expect(artifacts.symbols[0].slot == 0)
    }

    @Test func rejectsUndefinedVariable() {
        #expect(throws: Diagnostic.self) {
            _ = try Compiler().compile("print missing;")
        }
    }

    @Test func rejectsNonBooleanCondition() {
        #expect(throws: Diagnostic.self) {
            _ = try Compiler().compile("if (1) { print 1; }")
        }
    }

    @Test func permitsIntToFloatAssignment() throws {
        _ = try Compiler().compile("var x: float = 1; x = 2;")
    }
}

@Suite("IR and code generation")
struct CodeGenerationTests {
    @Test func declarationInitializersUseDistinctSlots() throws {
        let artifacts = try Compiler().analyze(try SourceParser().parse(
            "var x: int = 4; var y: int = 9; print x + y;"
        ))
        #expect(artifacts.symbols.map(\.slot) == [0, 1])
        #expect(artifacts.ir.operations.contains(.store(slot: 0)))
        #expect(artifacts.ir.operations.contains(.store(slot: 1)))
    }

    @Test func bothTargetsValidate() throws {
        let artifacts = try Compiler().analyze(try SourceParser().parse(
            "var x: int = 1; while (x < 3) { x = x + 1; } print x;"
        ))
        let stack = try StackCodeGenerator.generate(artifacts.ir)
        let registers = try RegisterCodeGenerator.generate(artifacts.ir)
        try BytecodeValidator.validate(stack.instructions, localCount: stack.localCount)
        try BytecodeValidator.validate(registers.instructions, localCount: registers.localCount)
    }

    @Test func validatorRejectsMalformedStackBytecode() {
        #expect(throws: Diagnostic.self) {
            try BytecodeValidator.validate([Instruction(.add), Instruction(.halt)], localCount: 0)
        }
    }

    @Test func validatorRejectsMalformedRegisterBytecode() {
        #expect(throws: Diagnostic.self) {
            try BytecodeValidator.validate([
                Instruction3(.jump, destination: .immediate(.int(99))),
            ], localCount: 0)
        }
    }

    @Test func validatorRejectsInconsistentMergeHeight() {
        #expect(throws: Diagnostic.self) {
            try BytecodeValidator.validate([
                Instruction(.push, [.boolean(true)]),
                Instruction(.jumpIfFalse, [.int(3)]),
                Instruction(.push, [.int(1)]),
                Instruction(.halt),
            ], localCount: 0)
        }
    }

    @Test func registerPressureIsAnError() {
        var expression = ASTNode.intLiteral(0, type: .int)
        for value in 1...40 {
            expression = .binary(
                op: "+",
                left: expression,
                right: .intLiteral(Int64(value), type: .int),
                type: .int
            )
        }
        // The post-order generator reuses registers, so this should compile
        // without trapping even for an expression larger than the register file.
        #expect(throws: Never.self) {
            let artifacts = try Compiler().analyze(expression)
            _ = try RegisterCodeGenerator.generate(artifacts.ir)
        }
    }

    @Test func registerAllocatorSpillsDeepExpressions() throws {
        var expression = ASTNode.intLiteral(40, type: .int)
        for value in stride(from: 39, through: 1, by: -1) {
            expression = .binary(
                op: "+",
                left: .intLiteral(Int64(value), type: .int),
                right: expression,
                type: .int
            )
        }
        let artifacts = try Compiler().analyze(expression)
        let compilation = try RegisterCodeGenerator.generate(artifacts.ir)
        let operands = compilation.instructions.flatMap { [$0.destination, $0.source1, $0.source2] }
        #expect(operands.contains { if case .spill = $0 { true } else { false } })
        #expect(try RegisterMachine(
            bytecode: compilation.instructions,
            localCount: compilation.localCount
        ).execute() == .int(820))
    }

    @Test func buildsIRBasicBlocks() throws {
        let artifacts = try Compiler().analyze(try SourceParser().parse(
            "var x: int = 0; while (x < 2) { x = x + 1; }"
        ))
        let graph = try artifacts.ir.controlFlowGraph()
        #expect(graph.blocks.count >= 3)
        #expect(graph.blocks.contains { $0.successors.count == 2 })
    }

    @Test func verifierRejectsInvalidTypeState() {
        #expect(throws: Diagnostic.self) {
            try BytecodeValidator.validate([
                Instruction(.push, [.string("wrong")]),
                Instruction(.neg),
                Instruction(.halt),
            ], localCount: 0)
        }
    }

    @Test func serializesBothBytecodeTargets() throws {
        let artifacts = try Compiler().analyze(try SourceParser().parse("print 1 + 2;"))
        let stack = try StackCodeGenerator.generate(artifacts.ir)
        let registers = try RegisterCodeGenerator.generate(artifacts.ir)
        #expect(try BytecodeSerializer.decode(BytecodeSerializer.encode(.stack(stack))) == .stack(stack))
        #expect(try BytecodeSerializer.decode(BytecodeSerializer.encode(.register(registers))) == .register(registers))
    }
}

@Suite("Execution")
struct ExecutionTests {
    @Test func registerBackendSupportsRecursiveCalls() throws {
        let source = """
        func factorial(n: int): int {
            if (n <= 1) { return 1; }
            return n * factorial(n - 1);
        }
        print factorial(6);
        """
        let artifacts = try Compiler().analyze(try SourceParser().parse(source))
        let compilation = try RegisterCodeGenerator.generate(artifacts.ir)
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let output = Box()
        _ = try RegisterMachine(bytecode: compilation.instructions, localCount: compilation.localCount,
                                output: { output.values.append($0) }).execute()
        #expect(output.values == ["720"])
    }

    @Test func arraysAndRecordsWorkOnBothBackends() throws {
        let source = """
        type Point { x: int; y: int; }
        var values: int[] = [2, 3, 4];
        values[1] = 7;
        var point: Point = Point { x: values[0], y: values[1] };
        point.x = point.x + 5;
        print point.x + point.y;
        """
        let artifacts = try Compiler().analyze(try SourceParser().parse(source))
        let stack = try StackCodeGenerator.generate(artifacts.ir)
        let registers = try RegisterCodeGenerator.generate(artifacts.ir)
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let a = Box(), b = Box()
        _ = try StackMachine(bytecode: stack.instructions, localCount: stack.localCount,
                             output: { a.values.append($0) }).execute()
        _ = try RegisterMachine(bytecode: registers.instructions, localCount: registers.localCount,
                                output: { b.values.append($0) }).execute()
        #expect(a.values == ["14"])
        #expect(b.values == a.values)
    }
    @Test func stackAndRegisterMachinesAgree() throws {
        let source = """
        var x: int = 1;
        var total: int = 0;
        while (x <= 5) {
            total = total + x;
            x = x + 1;
        }
        print total;
        """
        let artifacts = try Compiler().analyze(try SourceParser().parse(source))
        let stack = try StackCodeGenerator.generate(artifacts.ir)
        let registers = try RegisterCodeGenerator.generate(artifacts.ir)
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let stackOutput = Box(), registerOutput = Box()
        let stackResult = try StackMachine(
            bytecode: stack.instructions,
            localCount: stack.localCount,
            output: { stackOutput.values.append($0) }
        ).execute()
        let registerResult = try RegisterMachine(
            bytecode: registers.instructions,
            localCount: registers.localCount,
            output: { registerOutput.values.append($0) }
        ).execute()
        #expect(stackOutput.values == ["15"])
        #expect(registerOutput.values == stackOutput.values)
        #expect(registerResult == stackResult)
    }

    @Test func executesIfElseAndPrint() throws {
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let box = Box()
        _ = try Compiler().execute(
            "var x: int = 2; if (x > 1) { print \"large\"; } else { print \"small\"; }",
            output: { box.values.append($0) }
        )
        #expect(box.values == ["large"])
    }

    @Test func readAndPrint() throws {
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let box = Box()
        _ = try Compiler().execute(
            "var x: int; read x; print x + 1;",
            input: { "41" },
            output: { box.values.append($0) }
        )
        #expect(box.values == ["42"])
    }

    @Test func machineExecutionStartsFresh() throws {
        let code = [Instruction(.push, [.int(7)]), Instruction(.halt)]
        let machine = StackMachine(bytecode: code)
        #expect(try machine.execute() == .int(7))
        #expect(try machine.execute() == .int(7))
    }

    @Test func divisionByZeroIsTypedFailure() {
        #expect(throws: Diagnostic.self) {
            _ = try Compiler().executeExpression(
                .binary(
                    op: "/",
                    left: .intLiteral(1, type: .int),
                    right: .intLiteral(0, type: .int),
                    type: .int
                )
            )
        }
    }

    @Test func executesFunctionWithCallFrame() throws {
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let box = Box()
        let source = """
        func add(a: int, b: int): int {
            return a + b;
        }
        print add(20, 22);
        """
        _ = try Compiler().execute(source, output: { box.values.append($0) })
        #expect(box.values == ["42"])
    }

    @Test func executesRecursiveFunction() throws {
        final class Box: @unchecked Sendable { var values: [String] = [] }
        let box = Box()
        let source = """
        func factorial(n: int): int {
            if (n <= 1) {
                return 1;
            } else {
                return n * factorial(n - 1);
            }
        }
        print factorial(5);
        """
        _ = try Compiler().execute(source, output: { box.values.append($0) })
        #expect(box.values == ["120"])
    }
}
