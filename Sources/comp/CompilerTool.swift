import ArgumentParser

@main
struct CompilerTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "comp",
        abstract: "Parse, compile, and execute source with the Grammar/Lexer/Parser toolchain.",
        version: "0.1.0",
        subcommands: [Comp.self],
        defaultSubcommand: Comp.self
    )
}
