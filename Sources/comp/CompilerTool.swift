//
//  CompilerTool.swift
//  comp
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

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
