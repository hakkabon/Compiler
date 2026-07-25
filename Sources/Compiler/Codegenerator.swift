//
//  CodeGenerator.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public struct StackCompilation: Equatable, Sendable {
    public let instructions: [Instruction]
    public let localCount: Int
    public init(instructions: [Instruction], localCount: Int) {
        self.instructions = instructions
        self.localCount = localCount
    }
}

public struct RegisterCompilation: Equatable, Sendable {
    public let instructions: [Instruction3]
    public let localCount: Int
    public init(instructions: [Instruction3], localCount: Int) {
        self.instructions = instructions
        self.localCount = localCount
    }
}

public enum StackCodeGenerator {
    public static func generate(_ program: IRProgram) throws -> StackCompilation {
        var labels: [IRLabel: Int] = [:]
        var offset = 0
        for operation in program.operations {
            if case .label(let label) = operation { labels[label] = offset }
            else if case .read = operation { offset += 2 }
            else { offset += 1 }
        }
        var code: [Instruction] = []
        let functions = Dictionary(uniqueKeysWithValues: program.functions.map { ($0.name, $0) })
        for operation in program.operations {
            switch operation {
            case .constant(let value): code.append(Instruction(.push, [value]))
            case .load(let slot): code.append(Instruction(.loadLocal, [.int(Int64(slot))]))
            case .store(let slot): code.append(Instruction(.storeLocal, [.int(Int64(slot))]))
            case .binary(let op): code.append(Instruction(try stackOpcode(op)))
            case .unary(let op):
                guard op == "-" else { throw Diagnostic(stage: .lowering, message: "Unknown unary operation '\(op)'") }
                code.append(Instruction(.neg))
            case .label: break
            case .jump(let label): code.append(Instruction(.jump, [.int(Int64(try target(label, labels)))]))
            case .jumpIfFalse(let label): code.append(Instruction(.jumpIfFalse, [.int(Int64(try target(label, labels)))]))
            case .print: code.append(Instruction(.print))
            case .read(let slot):
                code.append(Instruction(.readInt))
                code.append(Instruction(.storeLocal, [.int(Int64(slot))]))
            case .discard: code.append(Instruction(.pop))
            case .call(let name, let argumentCount):
                guard let function = functions[name], function.parameterSlots.count == argumentCount else {
                    throw Diagnostic(stage: .lowering, message: "Invalid call metadata for '\(name)'")
                }
                code.append(Instruction(
                    .call,
                    [.int(Int64(try target(function.entry, labels)))] +
                    function.parameterSlots.map { .int(Int64($0)) }
                ))
            case .returnValue:
                code.append(Instruction(.return))
            case .buildArray(let count):
                code.append(Instruction(.buildArray, [.int(Int64(count))]))
            case .loadIndex: code.append(Instruction(.loadIndex))
            case .storeIndex(let slot): code.append(Instruction(.storeIndex, [.int(Int64(slot))]))
            case .buildRecord(let name, let fields):
                code.append(Instruction(.buildRecord, [.string(name)] + fields.map(Value.string)))
            case .loadField(let field): code.append(Instruction(.loadField, [.string(field)]))
            case .storeField(let slot, let field):
                code.append(Instruction(.storeField, [.int(Int64(slot)), .string(field)]))
            case .halt: code.append(Instruction(.halt))
            }
        }
        try BytecodeValidator.validate(code, localCount: program.localCount)
        return StackCompilation(instructions: code, localCount: program.localCount)
    }

    private static func target(_ label: IRLabel, _ labels: [IRLabel: Int]) throws -> Int {
        guard let target = labels[label] else {
            throw Diagnostic(stage: .lowering, message: "Undefined IR label \(label.rawValue)")
        }
        return target
    }
    private static func stackOpcode(_ op: String) throws -> StackOpcode {
        guard let opcode: StackOpcode = [
            "+": .add, "-": .sub, "*": .mul, "/": .div, "%": .mod,
            "==": .eq, "!=": .ne, "<": .lt, "<=": .le, ">": .gt, ">=": .ge,
        ][op] else { throw Diagnostic(stage: .lowering, message: "Unknown binary operation '\(op)'") }
        return opcode
    }
}

private struct RegisterPool {
    var free = Array((0..<32).reversed())
    var freeSpills: [Int] = []
    var nextSpill = 0
    mutating func allocate() -> RegisterOperand {
        if let register = free.popLast() { return .register(register) }
        if let spill = freeSpills.popLast() { return .spill(spill) }
        defer { nextSpill += 1 }
        return .spill(nextSpill)
    }
    mutating func release(_ operand: RegisterOperand) {
        switch operand {
        case .register(let register):
            if !free.contains(register) { free.append(register) }
        case .spill(let slot):
            if !freeSpills.contains(slot) { freeSpills.append(slot) }
        case .immediate:
            break
        }
    }
    mutating func allocateSpill() -> RegisterOperand {
        if let spill = freeSpills.popLast() { return .spill(spill) }
        defer { nextSpill += 1 }; return .spill(nextSpill)
    }
}

public enum RegisterCodeGenerator {
    public static func generate(_ program: IRProgram) throws -> RegisterCompilation {
        var labels: [IRLabel: Int] = [:]
        var emitted = 0
        for operation in program.operations {
            if case .label(let label) = operation { labels[label] = emitted }
            else {
                switch operation {
                case .read: emitted += 2
                case .call(_, let count): emitted += count * 2 + 2
                case .returnValue: emitted += 2
                case .halt: emitted += 2
                default: emitted += 1
                }
            }
        }

        var code: [Instruction3] = []
        var stack: [RegisterOperand] = []
        var pool = RegisterPool()

        func require(_ count: Int, operation: String) throws {
            guard stack.count >= count else {
                throw Diagnostic(stage: .lowering, message: "IR stack underflow while lowering \(operation)")
            }
        }

        for operation in program.operations {
            switch operation {
            case .constant(let value):
                let location = pool.allocate()
                code.append(Instruction3(.move, destination: location, source1: .immediate(value)))
                stack.append(location)
            case .load(let slot):
                let location = pool.allocate()
                code.append(Instruction3(.loadLocal, destination: location, source1: .immediate(.int(Int64(slot)))))
                stack.append(location)
            case .store(let slot):
                try require(1, operation: "store")
                let register = stack.removeLast()
                code.append(Instruction3(.storeLocal, destination: .immediate(.int(Int64(slot))), source1: register))
                pool.release(register)
            case .binary(let op):
                try require(2, operation: op)
                let rhs = stack.removeLast(), lhs = stack.removeLast()
                let destination = pool.allocate()
                code.append(Instruction3(try registerOpcode(op), destination: destination, source1: lhs, source2: rhs))
                pool.release(lhs); pool.release(rhs); stack.append(destination)
            case .unary(let op):
                try require(1, operation: op)
                guard op == "-" else { throw Diagnostic(stage: .lowering, message: "Unknown unary operation '\(op)'") }
                let source = stack.removeLast(), destination = pool.allocate()
                code.append(Instruction3(.neg, destination: destination, source1: source))
                pool.release(source); stack.append(destination)
            case .label:
                break
            case .jump(let label):
                code.append(Instruction3(.jump, destination: .immediate(.int(Int64(try target(label, labels))))))
            case .jumpIfFalse(let label):
                try require(1, operation: "conditional jump")
                let condition = stack.removeLast()
                code.append(Instruction3(.jumpIfFalse, destination: .immediate(.int(Int64(try target(label, labels)))), source1: condition))
                pool.release(condition)
            case .print:
                try require(1, operation: "print")
                let value = stack.removeLast()
                code.append(Instruction3(.print, source1: value))
                pool.release(value)
            case .read(let slot):
                let register = pool.allocate()
                code.append(Instruction3(.readInt, destination: register))
                code.append(Instruction3(.storeLocal, destination: .immediate(.int(Int64(slot))), source1: register))
                pool.release(register)
            case .discard:
                try require(1, operation: "discard")
                pool.release(stack.removeLast())
            case .call(let name, let argumentCount):
                guard argumentCount <= 8,
                      let function = program.functions.first(where: { $0.name == name }),
                      function.parameterSlots.count == argumentCount else {
                    throw Diagnostic(stage: .lowering, message: "Register calls support at most eight arguments")
                }
                try require(argumentCount, operation: "call")
                let arguments = Array(stack.suffix(argumentCount))
                stack.removeLast(argumentCount)
                var temporaries: [RegisterOperand] = []
                for argument in arguments {
                    let temporary = pool.allocateSpill()
                    code.append(Instruction3(.move, destination: temporary, source1: argument))
                    temporaries.append(temporary)
                    pool.release(argument)
                }
                for (index, temporary) in temporaries.enumerated() {
                    code.append(Instruction3(.move, destination: .register(index), source1: temporary))
                    pool.release(temporary)
                }
                code.append(Instruction3(
                    .call,
                    destination: .immediate(.int(Int64(try target(function.entry, labels)))),
                    extraOperands: function.parameterSlots.map { .immediate(.int(Int64($0))) }
                ))
                let result = pool.allocate()
                code.append(Instruction3(.move, destination: result, source1: .register(0)))
                stack.append(result)
            case .returnValue:
                try require(1, operation: "return")
                let result = stack.removeLast()
                code.append(Instruction3(.move, destination: .register(0), source1: result))
                pool.release(result)
                code.append(Instruction3(.return, source1: .register(0)))
            case .buildArray(let count):
                try require(count, operation: "array literal")
                let values = Array(stack.suffix(count)); stack.removeLast(count)
                let destination = pool.allocate()
                code.append(Instruction3(.buildArray, destination: destination, extraOperands: values))
                values.forEach { pool.release($0) }; stack.append(destination)
            case .loadIndex:
                try require(2, operation: "index")
                let index = stack.removeLast(), collection = stack.removeLast(), destination = pool.allocate()
                code.append(Instruction3(.loadIndex, destination: destination, source1: collection, source2: index))
                pool.release(collection); pool.release(index); stack.append(destination)
            case .storeIndex(let slot):
                try require(2, operation: "indexed assignment")
                let value = stack.removeLast(), index = stack.removeLast()
                code.append(Instruction3(.storeIndex, destination: .immediate(.int(Int64(slot))), source1: index, source2: value))
                pool.release(index); pool.release(value)
            case .buildRecord(let name, let fields):
                try require(fields.count, operation: "record literal")
                let values = Array(stack.suffix(fields.count)); stack.removeLast(fields.count)
                let destination = pool.allocate()
                var extras: [RegisterOperand] = [.immediate(.string(name))]
                for (field, value) in zip(fields, values) {
                    extras.append(.immediate(.string(field))); extras.append(value)
                }
                code.append(Instruction3(.buildRecord, destination: destination, extraOperands: extras))
                values.forEach { pool.release($0) }; stack.append(destination)
            case .loadField(let field):
                try require(1, operation: "field access")
                let base = stack.removeLast(), destination = pool.allocate()
                code.append(Instruction3(.loadField, destination: destination, source1: base, source2: .immediate(.string(field))))
                pool.release(base); stack.append(destination)
            case .storeField(let slot, let field):
                try require(1, operation: "field assignment")
                let value = stack.removeLast()
                code.append(Instruction3(.storeField, destination: .immediate(.int(Int64(slot))), source1: .immediate(.string(field)), source2: value))
                pool.release(value)
            case .halt:
                code.append(Instruction3(.move, destination: .register(0), source1: stack.last ?? .immediate(.null)))
                code.append(Instruction3(.halt))
            }
        }
        try BytecodeValidator.validate(code, localCount: program.localCount)
        return RegisterCompilation(instructions: code, localCount: program.localCount)
    }

    private static func target(_ label: IRLabel, _ labels: [IRLabel: Int]) throws -> Int {
        guard let target = labels[label] else {
            throw Diagnostic(stage: .lowering, message: "Undefined IR label \(label.rawValue)")
        }
        return target
    }
    private static func registerOpcode(_ op: String) throws -> RegisterOpcode {
        guard let opcode: RegisterOpcode = [
            "+": .add, "-": .sub, "*": .mul, "/": .div, "%": .mod,
            "==": .eq, "!=": .ne, "<": .lt, "<=": .le, ">": .gt, ">=": .ge,
        ][op] else { throw Diagnostic(stage: .lowering, message: "Unknown binary operation '\(op)'") }
        return opcode
    }
}
