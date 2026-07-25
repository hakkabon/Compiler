# Compiler

A small compiler and bytecode interpreter written in Swift. It includes an
end-to-end source pipeline, semantic analysis, a backend-neutral intermediate
representation, stack and register bytecode targets, validation, and virtual
machines for both targets.

The project is intentionally compact and suitable for experimenting with
language implementation techniques. Its `comp` executable is also an
integration harness for the companion Grammar, Lexer, Parser, Earley, CYK, and
RNGLR packages.

## Features

- source lexer and recursive-descent/precedence parser;
- concrete adapter for the shared generalized-parser `ParseTree`;
- selectable Earley, CYK, and RNGLR parsing from the command line;
- selectable hand-written tokenizer or DFA Lexer frontend;
- declarative syntax-tree-to-AST actions;
- one AST for expressions, declarations, statements, and programs;
- source-located lexer, parser, semantic, lowering, validation, and runtime
  diagnostics;
- static types for integers, floats, strings, Booleans, and null;
- declarations, initialization, assignment, blocks, `if`/`else`, `while`,
  functions, recursive calls, returns, `print`, and integer `read`;
- stable symbol identities and distinct local storage slots;
- shared, backend-neutral IR with symbolic labels and basic-block CFGs;
- stack and 32-register bytecode targets;
- control-flow and type-state bytecode verification before execution;
- register spilling for expressions exceeding the 32-register file;
- versioned, big-endian binary bytecode serialization;
- injectable input, output, and trace handlers;
- public compilation artifacts for inspecting the typed AST, symbols, and IR;
- unit, integration, negative, and cross-backend equivalence tests.

## Architecture

```mermaid
flowchart LR
    Source["Source text"] --> External["Grammar + Lexer/Tokenizer + Earley/CYK/RNGLR"]
    External --> Adapter["GeneralizedParseTreeAdapter"]
    Adapter --> Syntax["SyntaxNode"]
    Syntax --> Builder["ASTBuilder + ASTMapping"]
    Parser --> AST["ASTNode"]
    Builder --> AST
    AST --> Semantic["SemanticAnalyzer"]
    Semantic --> Typed["Typed AST + Symbols"]
    Typed --> IR["IRLowerer"]
    IR --> StackGen["StackCodeGenerator"]
    IR --> RegisterGen["RegisterCodeGenerator"]
    StackGen --> StackCheck["BytecodeValidator"]
    RegisterGen --> RegisterCheck["BytecodeValidator"]
    StackCheck --> StackVM["StackMachine"]
    RegisterCheck --> RegisterVM["RegisterMachine"]
```

The external parser first validates the source and exposes its derivations for
inspection and ambiguity handling. The compiler-owned `SourceParser` then
builds the language AST. This deliberate two-step design lets `comp` exercise
arbitrary Grammar/Lexer/Parser combinations without making compiler semantics
depend on grammar-specific production names.

## Language

### Types and values

| Source type | Compile-time type  | Runtime value          |
| ----------- | ------------------ | ---------------------- |
| `int`       | `TypeInfo.int`     | `Value.int(Int64)`     |
| `float`     | `TypeInfo.float`   | `Value.float(Double)`  |
| `string`    | `TypeInfo.string`  | `Value.string(String)` |
| `boolean`   | `TypeInfo.boolean` | `Value.boolean(Bool)`  |
| `null`      | `TypeInfo.null`    | `Value.null`           |

`TypeInfo.any` is an unresolved AST annotation used before semantic analysis.
It is not a runtime type.

Integer values may be assigned to floating-point variables. Other assignments
must have matching types. Conditions for `if` and `while` must be Boolean.

### Expressions

The parser implements conventional precedence:

1. grouping and literals;
2. unary `-`;
3. `*`, `/`, `%`;
4. `+`, `-`;
5. `<`, `<=`, `>`, `>=`;
6. `==`, `!=`.

Arithmetic supports mixed integer/floating-point operands. `+` also
concatenates two strings. Ordered string comparisons are supported.

### Statements

```text
var count: int = 1;
var inferred = 10;
count = count + inferred;

if (count > 5) {
    print "large";
} else {
    print "small";
}

while (count < 20) {
    count = count + 1;
}

read count;
print count;

func factorial(n: int): int {
    if (n <= 1) {
        return 1;
    } else {
        return n * factorial(n - 1);
    }
}

print factorial(5);
```

Semicolons terminate declarations, assignments, I/O statements, and expression
statements. Blocks use braces. Line comments begin with `//`.

## Quick start

Requirements:

- Swift tools 5.9 or newer;
- macOS 13+ or iOS 14+ for the package (RNGLR currently requires macOS 13);
- network access when dependencies are first resolved.

Build and test:

```sh
swift build
swift test
```

Run the included end-to-end example:

```sh
swift run comp Examples/arithmetic.bnf Examples/arithmetic.comp \
  --start program --parser earley --lexer tokenizer \
  --target stack --emit trees bytecode result
```

## Command-line integration

Synopsis:

```text
comp <grammar-file> <source-file>
  --start <rule>
  [--notation bnf|ebnf|wsn|gen]
  [--parser earley|cyk|rnglr]
  [--lexer tokenizer|dfa]
  [--ambiguity reject|first|all]
  [--target stack|register]
  [--emit grammar tokens trees ast typed-ast ir bytecode result ...]
  [--parse-only]
  [--trace]
  [--output <bytecode-file>]
```

The grammar notation defaults to the grammar file extension. `--start` is
required for BNF, EBNF, and WSN; `.gen` grammars carry their own start
declaration.

The default `--lexer tokenizer` path exercises GrammarTokenizer through each
parser's standard interface. `--lexer dfa` constructs a DFA lexer from the
grammar's terminals, feeds a `LexerTokenStream` to Earley, and is currently
restricted to `--parser earley` because only that parser exposes both generic
token-stream parsing and natural-grammar tree reconstruction publicly.

Examples:

```sh
# Earley + GrammarTokenizer
swift run comp Examples/arithmetic.bnf Examples/arithmetic.comp \
  --start program --parser earley --emit trees result

# DFA Lexer + Earley + SPPF extraction
swift run comp Examples/arithmetic.bnf Examples/arithmetic.comp \
  --start program --parser earley --lexer dfa --emit tokens trees result

# Exercise the alternative generalized parsers
swift run comp Examples/arithmetic.bnf Examples/arithmetic.comp \
  --start program --parser cyk
swift run comp Examples/arithmetic.bnf Examples/arithmetic.comp \
  --start program --parser rnglr

# Inspect only parsing and every derivation
swift run comp grammar.bnf source.comp --start program \
  --ambiguity all --emit grammar trees --parse-only

# Compile, trace, and save a versioned bytecode image
swift run comp grammar.bnf source.comp --start program \
  --target stack --trace --output program.cmpb
```

By default ambiguous input is rejected. `first` selects the first deduplicated
derivation, while `all` adapts and prints every derivation. Compilation still
uses the compiler language parser; the supplied grammar should therefore
recognize the same source language when running beyond `--parse-only`.

## Library usage

### Compile and execute source

```swift
import Compiler

let source = """
var x: int = 1;
var total: int = 0;

while (x <= 5) {
    total = total + x;
    x = x + 1;
}

print total;
"""

let compiler = Compiler()
let result = try compiler.execute(
    source,
    output: { print("program:", $0) }
)
```

### Inspect compilation artifacts

```swift
let ast = try compiler.parse(source, file: "example.comp")
let artifacts = try compiler.analyze(ast)

print(artifacts.typedAST)
print(artifacts.symbols)
print(artifacts.ir.operations)

let stack = try StackCodeGenerator.generate(artifacts.ir)
let registers = try RegisterCodeGenerator.generate(artifacts.ir)
```

### Select a backend

```swift
let artifacts = try compiler.analyze(ast)
let stackCode = try StackCodeGenerator.generate(artifacts.ir)
let registerCode = try RegisterCodeGenerator.generate(artifacts.ir)

let stackResult = try StackMachine(
    bytecode: stackCode.instructions,
    localCount: stackCode.localCount
).execute()
let registerResult = try RegisterMachine(
    bytecode: registerCode.instructions,
    localCount: registerCode.localCount
).execute()
```

### Inject input, output, and tracing

```swift
let compilation = try compiler.compile("var x: int; read x; print x + 1;")

let machine = StackMachine(
    bytecode: compilation.instructions,
    localCount: compilation.localCount,
    input: { "41" },
    output: { value in print("output:", value) }
)

_ = try machine.executeWithTrace { event in
    print("trace:", event)
}
```

Machine state is local to each `execute` call, so an instance can be executed
again as a fresh run.

## External parser integration

`GeneralizedParseTreeAdapter` directly adapts the shared Parser package tree:

```swift
let trees = try EarleyParser(grammar: grammar).allSyntaxTrees(for: source)
let forest = try GeneralizedParseTreeAdapter(source: source)
    .adapt(trees, ambiguity: .reject)
print(forest.trees[0].formattedTree())
```

`ASTBuilder` interprets the resulting tree using an `ASTMapping`. The built-in
mapping supports expression nodes named `integer`, `float`, `string`,
`boolean`, `null`, `identifier`, `unary`, `binary`, `group`, and `expression`.
Projects can provide a mapping matching their grammar rule names:

```swift
let mapping = ASTMapping(actions: [
    "sum": .binary(leftChild: 0, operatorChild: 1, rightChild: 2),
    "wholeNumber": .integer,
])

let ast = try ASTBuilder(mapping: mapping).build(from: syntaxTree)
```

Malformed child shapes and unmapped productions produce parsing diagnostics
instead of unchecked child indexing.

## Intermediate representation

`IRProgram` contains typed, backend-neutral stack operations:

- constants and local loads/stores;
- unary and binary operations;
- symbolic labels and conditional/unconditional jumps;
- print, read, discard, and halt.
- function calls and returns.

Both code generators consume this IR. Control-flow lowering therefore has one
implementation, and label resolution happens independently for each concrete
instruction layout. `IRProgram.controlFlowGraph()` partitions operations into
`IRBasicBlock` values and records successor edges for analysis.

## Bytecode

### Stack target

Stack instructions use implicit operands:

```text
push 2
push 3
add
push 4
mul
halt
```

`StackCompilation` includes the instruction array and required local count.

### Register target

Register instructions expose data flow:

```text
move R0 #2
move R1 #3
add R2 R0 R1
```

The generator uses 32 physical registers and reuses temporaries. When pressure
exceeds the register file, additional values are assigned explicit spill slots
(`S0`, `S1`, …), which the register VM stores separately.

Functions currently compile to stack bytecode because call frames are a
stack-machine feature. Selecting the register target for a program containing
calls produces a clear lowering diagnostic.

### Validation

`BytecodeValidator` checks:

- stack instruction operand counts;
- stack underflow across control-flow edges;
- equal stack heights at CFG merge points;
- abstract stack type compatibility for arithmetic, comparisons, negation, and
  Boolean branches;
- operand kinds;
- jump bounds;
- local-slot bounds;
- register bounds;
- register instruction shapes.

Both machines validate bytecode before executing it. Malformed instructions
produce validation diagnostics rather than force-unwrap traps.

### Serialization

`BytecodeSerializer` encodes either target as a `.cmpb` image with:

- magic bytes `CMPB`;
- format version `1`;
- target and local-count metadata;
- big-endian integer encoding;
- UTF-8 length-prefixed strings;
- target-specific instructions and operands.

Decoding rejects unknown versions, malformed tags, invalid UTF-8, trailing
data, and bytecode that fails verification:

```swift
let data = try BytecodeSerializer.encode(.stack(compilation))
let image = try BytecodeSerializer.decode(data)
try BytecodeSerializer.write(image, to: outputURL)
```

## Diagnostics

All stages use `Diagnostic`:

```swift
public struct Diagnostic: Error {
    public let stage: Stage
    public let message: String
    public let range: SourceRange?
}
```

Stages are `lexing`, `parsing`, `semantic`, `lowering`, `validation`, and
`runtime`. Source parsing preserves file, line, column, and offset information.

## Package layout

```text
Sources/
├── Compiler/
│   ├── Model.swift
│   ├── Frontend.swift
│   ├── ExternalParserAdapter.swift
│   ├── SemanticAnalyzer.swift
│   ├── IR.swift
│   ├── IRControlFlow.swift
│   ├── Bytecode.swift
│   ├── BytecodeSerialization.swift
│   ├── CodeGenerator.swift
│   ├── Runtime.swift
│   └── Compiler.swift
└── comp/
    ├── CompilerTool.swift
    ├── Comp.swift
    └── Definitions.swift

Tests/
└── CompilerTests/
    └── CompilerTests.swift
```

The module name and library product are both `Compiler`.

## Tests

The Swift Testing suite covers:

- precedence parsing and source-located lexer errors;
- declarative AST mapping and malformed rules;
- real Earley parse-tree adaptation and ambiguity handling;
- type inference, undefined symbols, assignments, and Boolean conditions;
- distinct declaration slots and initializers;
- IR lowering and both code generators;
- malformed stack/register bytecode;
- control flow, input, output, and runtime failures;
- repeatable machine execution;
- stack/register behavioral equivalence;
- recursive function call frames;
- CFG formation and type-state rejection;
- register spilling;
- stack/register serialization round trips.

Run it with:

```sh
swift test
```

## Dependencies

Direct dependencies are:

- [Grammar](https://github.com/hakkabon/Grammar);
- [Lexer](https://github.com/hakkabon/Lexer) and
  [Lexer-FSA](https://github.com/hakkabon/Lexer-FSA);
- [Parser](https://github.com/hakkabon/Parser);
- [Earley-Parser](https://github.com/hakkabon/Earley-Parser);
- [CYK-Parser](https://github.com/hakkabon/CYK-Parser);
- [RNGLR-Parser](https://github.com/hakkabon/RNGLR-Parser);
- [swift-argument-parser](https://github.com/apple/swift-argument-parser).

The hakkabon packages currently track their `main` branches so this repository
can exercise their latest implementations together. `Package.resolved` records
the exact tested revisions.

## Current limitations and roadmap

- The built-in source parser intentionally implements a small language.
- External parse trees are used for validation, diagnostics, ambiguity
  inspection, and frontend testing. Turning arbitrary grammar productions
  directly into language semantics still requires an `ASTMapping`.
- The DFA grammar-to-lexer bridge supports literal, list, range, and regular
  expression terminals. A literal double quote cannot currently be represented
  by the Lexer-FSA escape syntax used by the bridge.
- DFA mode currently pairs with Earley; CYK's natural-tree transformer and
  RNGLR's token-stream entry point are not public in forms that can be composed
  this way.
- Lexical shadowing is rejected, and parameter names must presently be unique
  across the program, because AST references do not yet carry resolved symbol
  IDs.
- Function calls and recursion use stack-machine call frames; the register
  backend reports calls as unsupported.
- User-defined types, arrays, modules, closures, and captured variables are not
  implemented.
- Register spills are explicit VM locations rather than loads/stores inserted
  by a liveness-based allocator.
- The bytecode format is versioned but not promised ABI-stable across a future
  major format version.

The next useful work is resolved-symbol IDs in the typed AST, register-machine
calling conventions, user-defined aggregate types, and a grammar action format
capable of constructing the complete compiler AST directly from external parse
trees.
