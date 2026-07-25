//
//  IRControlFlow.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public struct IRBasicBlock: Equatable, Sendable {
    public let id: Int
    public let label: IRLabel?
    public let operations: [IROperation]
    public let successors: [Int]

    public init(id: Int, label: IRLabel?, operations: [IROperation], successors: [Int]) {
        self.id = id
        self.label = label
        self.operations = operations
        self.successors = successors
    }
}

public struct IRControlFlowGraph: Equatable, Sendable {
    public let blocks: [IRBasicBlock]
    public let entry: Int?

    public init(program: IRProgram) throws {
        guard !program.operations.isEmpty else {
            blocks = []
            entry = nil
            return
        }

        var starts: Set<Int> = [0]
        for (index, operation) in program.operations.enumerated() {
            if case .label = operation { starts.insert(index) }
            if Self.isTerminator(operation), index + 1 < program.operations.count {
                starts.insert(index + 1)
            }
        }
        let orderedStarts = starts.sorted()
        var rawBlocks: [(range: Range<Int>, label: IRLabel?)] = []
        for (position, start) in orderedStarts.enumerated() {
            let end = position + 1 < orderedStarts.count ? orderedStarts[position + 1] : program.operations.count
            let label: IRLabel?
            if case .label(let value) = program.operations[start] { label = value } else { label = nil }
            rawBlocks.append((start..<end, label))
        }

        let labelToBlock = Dictionary(uniqueKeysWithValues: rawBlocks.enumerated().compactMap { entry in
            entry.element.label.map { label in (label, entry.offset) }
        })
        var result: [IRBasicBlock] = []
        for (id, raw) in rawBlocks.enumerated() {
            let operations = Array(program.operations[raw.range])
            let terminal = operations.last
            let successors: [Int]
            switch terminal {
            case .jump(let label):
                successors = [try Self.block(for: label, in: labelToBlock)]
            case .jumpIfFalse(let label):
                var values = [try Self.block(for: label, in: labelToBlock)]
                if id + 1 < rawBlocks.count { values.insert(id + 1, at: 0) }
                successors = values
            case .halt, .returnValue:
                successors = []
            default:
                successors = id + 1 < rawBlocks.count ? [id + 1] : []
            }
            result.append(IRBasicBlock(id: id, label: raw.label, operations: operations, successors: successors))
        }
        blocks = result
        entry = 0
    }

    private static func isTerminator(_ operation: IROperation) -> Bool {
        switch operation {
        case .jump, .jumpIfFalse, .returnValue, .halt: return true
        default: return false
        }
    }

    private static func block(for label: IRLabel, in labels: [IRLabel: Int]) throws -> Int {
        guard let block = labels[label] else {
            throw Diagnostic(stage: .validation, message: "Undefined IR label \(label.rawValue)")
        }
        return block
    }
}

public extension IRProgram {
    func controlFlowGraph() throws -> IRControlFlowGraph {
        try IRControlFlowGraph(program: self)
    }
}
