import CompilerConformance
import Foundation

do {
    guard CommandLine.arguments.count == 3 else {
        throw ConformanceCommandError("usage: compiler-conformance CORPUS OUTPUT")
    }

    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let observations = try CompilerCorpusConformance.evaluate(Data(contentsOf: input))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(observations).write(to: output, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("compiler-conformance: \(error)\n".utf8))
    exit(1)
}

private struct ConformanceCommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
