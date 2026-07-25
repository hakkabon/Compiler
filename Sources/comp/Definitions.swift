//
//  Definitions.swift
//  comp
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import ArgumentParser
import Compiler

enum GrammarNotation: String, ExpressibleByArgument, CaseIterable {
    case bnf, ebnf, wsn, gen
}

enum ParserMethod: String, ExpressibleByArgument, CaseIterable {
    case earley, cyk, rnglr
}

enum LexerMethod: String, ExpressibleByArgument, CaseIterable {
    case tokenizer, dfa
}

enum CompilationTarget: String, ExpressibleByArgument, CaseIterable {
    case stack, register
}

enum AmbiguityArgument: String, ExpressibleByArgument, CaseIterable {
    case reject, first, all

    var policy: AmbiguityPolicy {
        switch self {
        case .reject: return .reject
        case .first: return .first
        case .all: return .all
        }
    }
}

enum EmitStage: String, ExpressibleByArgument, CaseIterable {
    case grammar, tokens, trees, ast, typedAST = "typed-ast", ir, bytecode, result
}
