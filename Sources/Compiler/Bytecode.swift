//
//  Bytecode.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public enum StackOpcode: UInt8, CaseIterable, Sendable {
    case push = 0x01, pop = 0x10
    case loadLocal = 0x20, storeLocal = 0x21
    case add = 0x30, sub, mul, div, mod, neg
    case eq = 0x40, ne, lt, le, gt, ge
    case jump = 0x60, jumpIfFalse
    case print = 0x70, readInt, call, `return`, halt
    case buildArray = 0x80, loadIndex, storeIndex, buildRecord, loadField, storeField
}

public struct Instruction: Equatable, CustomStringConvertible, Sendable {
    public let opcode: StackOpcode
    public let operands: [Value]

    public init(_ opcode: StackOpcode, _ operands: [Value] = []) {
        self.opcode = opcode
        self.operands = operands
    }

    public var description: String {
        operands.isEmpty
            ? "\(opcode)"
            : "\(opcode) " + operands.map(\.description).joined(separator: ", ")
    }
}

public enum RegisterOperand: Equatable, CustomStringConvertible, Sendable {
    case register(Int)
    case spill(Int)
    case immediate(Value)

    public var description: String {
        switch self {
        case .register(let index): return "R\(index)"
        case .spill(let index): return "S\(index)"
        case .immediate(let value): return "#\(value)"
        }
    }
}

public enum RegisterOpcode: UInt8, CaseIterable, Sendable {
    case move = 0x01
    case loadLocal = 0x20, storeLocal
    case add = 0x30, sub, mul, div, mod, neg
    case eq = 0x40, ne, lt, le, gt, ge
    case jump = 0x60, jumpIfFalse
    case print = 0x70, readInt, call, `return`, halt
    case buildArray = 0x80, loadIndex, storeIndex, buildRecord, loadField, storeField
}

public struct Instruction3: Equatable, CustomStringConvertible, Sendable {
    public let opcode: RegisterOpcode
    public let destination: RegisterOperand?
    public let source1: RegisterOperand?
    public let source2: RegisterOperand?
    public let extraOperands: [RegisterOperand]

    public init(
        _ opcode: RegisterOpcode,
        destination: RegisterOperand? = nil,
        source1: RegisterOperand? = nil,
        source2: RegisterOperand? = nil,
        extraOperands: [RegisterOperand] = []
    ) {
        self.opcode = opcode
        self.destination = destination
        self.source1 = source1
        self.source2 = source2
        self.extraOperands = extraOperands
    }

    public var description: String {
        (
            [String(describing: opcode)] +
            [destination, source1, source2].compactMap { $0?.description } +
            extraOperands.map(\.description)
        ).joined(separator: " ")
    }
}

public enum AnyBytecode: Equatable, Sendable {
    case stack([Instruction])
    case register([Instruction3])
}

public enum BytecodeValidator {
    public static func validate(_ code: [Instruction], localCount: Int) throws {
        guard localCount >= 0 else {
            throw Diagnostic(stage: .validation, message: "Local count cannot be negative")
        }

        for (index, instruction) in code.enumerated() {
            let expected = stackOperandCount(instruction.opcode)
            guard expected == nil || instruction.operands.count == expected else {
                throw Diagnostic(
                    stage: .validation,
                    message: "\(instruction.opcode) at \(index) expects \(expected ?? 0) operand(s)"
                )
            }

            if [.loadLocal, .storeLocal, .jump, .jumpIfFalse, .storeIndex, .storeField]
                .contains(instruction.opcode) {
                guard case .int(let raw) = instruction.operands[0] else {
                    throw Diagnostic(
                        stage: .validation,
                        message: "\(instruction.opcode) at \(index) needs an integer operand"
                    )
                }
                if [.loadLocal, .storeLocal, .storeIndex, .storeField].contains(instruction.opcode) {
                    guard raw >= 0, raw < localCount else {
                        throw Diagnostic(
                            stage: .validation,
                            message: "Local \(raw) is out of bounds at \(index)"
                        )
                    }
                } else {
                    guard raw >= 0, raw < code.count else {
                        throw Diagnostic(
                            stage: .validation,
                            message: "Jump target \(raw) is out of bounds at \(index)"
                        )
                    }
                }
            }

            if instruction.opcode == .call {
                guard !instruction.operands.isEmpty,
                      case .int(let target) = instruction.operands[0],
                      target >= 0, target < code.count else {
                    throw Diagnostic(stage: .validation, message: "Invalid call target at \(index)")
                }
                for operand in instruction.operands.dropFirst() {
                    guard case .int(let slot) = operand, slot >= 0, slot < localCount else {
                        throw Diagnostic(
                            stage: .validation,
                            message: "Invalid call parameter slot at \(index)"
                        )
                    }
                }
            }

            if instruction.opcode == .buildArray {
                guard case .int(let count) = instruction.operands[0], count >= 0 else {
                    throw Diagnostic(stage: .validation, message: "Invalid array element count at \(index)")
                }
            }

            if instruction.opcode == .buildRecord {
                guard !instruction.operands.isEmpty,
                      instruction.operands.allSatisfy({
                          if case .string = $0 { return true }
                          return false
                      }) else {
                    throw Diagnostic(stage: .validation, message: "Invalid record metadata at \(index)")
                }
            }

            if instruction.opcode == .loadField {
                guard case .string = instruction.operands[0] else {
                    throw Diagnostic(stage: .validation, message: "Invalid field metadata at \(index)")
                }
            }

            if instruction.opcode == .storeField {
                guard case .string = instruction.operands[1] else {
                    throw Diagnostic(stage: .validation, message: "Invalid field metadata at \(index)")
                }
            }
        }

        guard !code.isEmpty else { return }

        let callTargets = code.compactMap { instruction -> Int? in
            guard instruction.opcode == .call,
                  case .int(let target) = instruction.operands.first else { return nil }
            return Int(target)
        }
        var heights: [Int: Int] = [0: 0]
        for target in callTargets { heights[target] = 0 }
        var worklist = [0] + callTargets

        while let index = worklist.popLast() {
            guard let height = heights[index] else { continue }
            let effect = stackEffect(code[index])
            guard height + effect.minimum >= 0 else {
                throw Diagnostic(
                    stage: .validation,
                    message: "Stack underflow is possible at instruction \(index)"
                )
            }
            let outgoingHeight = height + effect.delta
            for successor in successors(of: index, in: code) {
                if let existing = heights[successor] {
                    guard existing == outgoingHeight else {
                        throw Diagnostic(
                            stage: .validation,
                            message: "Inconsistent stack height at instruction \(successor): \(existing) or \(outgoingHeight)"
                        )
                    }
                } else {
                    heights[successor] = outgoingHeight
                    worklist.append(successor)
                }
            }
        }

        try validateTypeState(code)
    }

    public static func validate(
        _ code: [Instruction3],
        localCount: Int,
        registerCount: Int = 32
    ) throws {
        guard localCount >= 0, registerCount > 0 else {
            throw Diagnostic(stage: .validation, message: "Invalid VM storage configuration")
        }

        for (index, instruction) in code.enumerated() {
            let operands =
                [instruction.destination, instruction.source1, instruction.source2].compactMap { $0 } +
                instruction.extraOperands
            for operand in operands {
                switch operand {
                case .register(let register) where !(0..<registerCount).contains(register):
                    throw Diagnostic(
                        stage: .validation,
                        message: "Register R\(register) is out of bounds at \(index)"
                    )
                case .spill(let slot) where slot < 0:
                    throw Diagnostic(
                        stage: .validation,
                        message: "Spill slot S\(slot) is invalid at \(index)"
                    )
                default:
                    break
                }
            }

            switch instruction.opcode {
            case .jump:
                try validateTarget(instruction.destination, index: index, count: code.count)
            case .jumpIfFalse:
                guard isReadable(instruction.source1) else {
                    throw Diagnostic(
                        stage: .validation,
                        message: "jumpIfFalse at \(index) needs a condition operand"
                    )
                }
                try validateTarget(instruction.destination, index: index, count: code.count)
            case .loadLocal:
                try validateLocal(instruction.source1, index: index, count: localCount)
                guard isWritable(instruction.destination) else { throw shape(index, instruction.opcode) }
            case .storeLocal:
                try validateLocal(instruction.destination, index: index, count: localCount)
                guard isReadable(instruction.source1) else { throw shape(index, instruction.opcode) }
            case .move, .neg:
                guard isWritable(instruction.destination), isReadable(instruction.source1) else {
                    throw shape(index, instruction.opcode)
                }
            case .readInt:
                guard isWritable(instruction.destination) else { throw shape(index, instruction.opcode) }
            case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge:
                guard isWritable(instruction.destination),
                      isReadable(instruction.source1),
                      isReadable(instruction.source2) else {
                    throw shape(index, instruction.opcode)
                }
            case .print:
                guard isReadable(instruction.source1) else { throw shape(index, instruction.opcode) }
            case .call:
                try validateTarget(instruction.destination, index: index, count: code.count)
                guard instruction.extraOperands.count <= 8 else { throw shape(index, instruction.opcode) }
                for slot in instruction.extraOperands {
                    try validateLocal(slot, index: index, count: localCount)
                }
            case .return:
                guard isReadable(instruction.source1) else { throw shape(index, instruction.opcode) }
            case .buildArray:
                guard isWritable(instruction.destination),
                      instruction.extraOperands.allSatisfy({ isReadable($0) }) else {
                    throw shape(index, instruction.opcode)
                }
            case .loadIndex:
                guard isWritable(instruction.destination),
                      isReadable(instruction.source1),
                      isReadable(instruction.source2) else {
                    throw shape(index, instruction.opcode)
                }
            case .storeIndex:
                try validateLocal(instruction.destination, index: index, count: localCount)
                guard isReadable(instruction.source1), isReadable(instruction.source2) else {
                    throw shape(index, instruction.opcode)
                }
            case .buildRecord:
                guard isWritable(instruction.destination),
                      !instruction.extraOperands.isEmpty,
                      instruction.extraOperands.count % 2 == 1,
                      instruction.extraOperands.enumerated().allSatisfy({ offset, operand in
                          if offset == 0 || offset % 2 == 1 {
                              if case .immediate(.string) = operand { return true }
                              return false
                          }
                          return isReadable(operand)
                      }) else {
                    throw shape(index, instruction.opcode)
                }
            case .loadField:
                guard isWritable(instruction.destination),
                      isReadable(instruction.source1),
                      isStringImmediate(instruction.source2) else {
                    throw shape(index, instruction.opcode)
                }
            case .storeField:
                try validateLocal(instruction.destination, index: index, count: localCount)
                guard isStringImmediate(instruction.source1), isReadable(instruction.source2) else {
                    throw shape(index, instruction.opcode)
                }
            case .halt:
                break
            }
        }
    }

    private static func stackOperandCount(_ opcode: StackOpcode) -> Int? {
        switch opcode {
        case .call, .buildRecord: return nil
        case .push, .loadLocal, .storeLocal, .jump, .jumpIfFalse,
             .buildArray, .storeIndex, .loadField:
            return 1
        case .storeField:
            return 2
        default:
            return 0
        }
    }

    private static func stackEffect(_ instruction: Instruction) -> (minimum: Int, delta: Int) {
        switch instruction.opcode {
        case .push, .loadLocal, .readInt:
            return (0, 1)
        case .pop, .storeLocal, .jumpIfFalse:
            return (-1, -1)
        case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge:
            return (-2, -1)
        case .neg:
            return (-1, 0)
        case .print, .return:
            return (-1, -1)
        case .call:
            let count = instruction.operands.count - 1
            return (-count, 1 - count)
        case .buildArray:
            let count = Int(instruction.operands[0].intValue ?? 0)
            return (-count, 1 - count)
        case .buildRecord:
            let count = max(0, instruction.operands.count - 1)
            return (-count, 1 - count)
        case .loadIndex:
            return (-2, -1)
        case .storeIndex:
            return (-2, -2)
        case .loadField:
            return (-1, 0)
        case .storeField:
            return (-1, -1)
        case .jump, .halt:
            return (0, 0)
        }
    }

    private static func successors(of index: Int, in code: [Instruction]) -> [Int] {
        switch code[index].opcode {
        case .halt, .return:
            return []
        case .jump:
            return [Int(code[index].operands[0].intValue!)]
        case .jumpIfFalse:
            let target = Int(code[index].operands[0].intValue!)
            return index + 1 < code.count ? [index + 1, target] : [target]
        default:
            return index + 1 < code.count ? [index + 1] : []
        }
    }

    private static func validateTypeState(_ code: [Instruction]) throws {
        typealias AbstractValue = Set<TypeInfo>
        let any: AbstractValue = [.int, .float, .string, .boolean, .null, .array(.any)]
        let callTargets = code.compactMap { instruction -> Int? in
            guard instruction.opcode == .call,
                  case .int(let target) = instruction.operands.first else { return nil }
            return Int(target)
        }
        var states: [Int: [AbstractValue]] = [0: []]
        for target in callTargets { states[target] = [] }
        var worklist = [0] + callTargets

        while let index = worklist.popLast() {
            guard var stack = states[index] else { continue }
            let instruction = code[index]

            func pop() throws -> AbstractValue {
                guard let value = stack.popLast() else {
                    throw Diagnostic(
                        stage: .validation,
                        message: "Stack underflow at instruction \(index)"
                    )
                }
                return value
            }

            func require(
                _ value: AbstractValue,
                allowed: Set<TypeInfo>,
                operation: StackOpcode
            ) throws {
                guard !value.isDisjoint(with: allowed) else {
                    throw Diagnostic(
                        stage: .validation,
                        message: "\(operation) cannot consume \(value.map(\.description).sorted()) at instruction \(index)"
                    )
                }
            }

            switch instruction.opcode {
            case .push:
                stack.append([instruction.operands[0].type])
            case .loadLocal:
                stack.append(any)
            case .readInt:
                stack.append([.int])
            case .pop, .storeLocal, .print, .return:
                _ = try pop()
            case .call:
                for _ in instruction.operands.dropFirst() { _ = try pop() }
                stack.append(any)
            case .jumpIfFalse:
                try require(try pop(), allowed: [.boolean], operation: .jumpIfFalse)
            case .neg:
                let operand = try pop()
                try require(operand, allowed: [.int, .float], operation: .neg)
                stack.append(operand.intersection([.int, .float]))
            case .add, .sub, .mul, .div, .mod:
                let rhs = try pop()
                let lhs = try pop()
                let numeric: Set<TypeInfo> = [.int, .float]
                if instruction.opcode == .add,
                   lhs.contains(.string), rhs.contains(.string) {
                    stack.append([.string])
                } else {
                    try require(lhs, allowed: numeric, operation: instruction.opcode)
                    try require(rhs, allowed: numeric, operation: instruction.opcode)
                    if instruction.opcode == .mod {
                        guard lhs.contains(.int), rhs.contains(.int) else {
                            throw Diagnostic(
                                stage: .validation,
                                message: "mod requires integer values at instruction \(index)"
                            )
                        }
                        stack.append([.int])
                    } else {
                        stack.append(
                            lhs.contains(.float) || rhs.contains(.float)
                                ? [.int, .float]
                                : [.int]
                        )
                    }
                }
            case .eq, .ne:
                _ = try pop()
                _ = try pop()
                stack.append([.boolean])
            case .lt, .le, .gt, .ge:
                let rhs = try pop()
                let lhs = try pop()
                let ordered: Set<TypeInfo> = [.int, .float, .string]
                try require(lhs, allowed: ordered, operation: instruction.opcode)
                try require(rhs, allowed: ordered, operation: instruction.opcode)
                stack.append([.boolean])
            case .buildArray:
                let count = Int(instruction.operands[0].intValue ?? 0)
                for _ in 0..<count { _ = try pop() }
                stack.append([.array(.any)])
            case .buildRecord:
                for _ in instruction.operands.dropFirst() { _ = try pop() }
                let name: String
                if case .string(let value) = instruction.operands.first {
                    name = value
                } else {
                    name = ""
                }
                stack.append([.record(name)])
            case .loadIndex:
                _ = try pop()
                _ = try pop()
                stack.append(any)
            case .storeIndex:
                _ = try pop()
                _ = try pop()
            case .loadField:
                _ = try pop()
                stack.append(any)
            case .storeField:
                _ = try pop()
            case .jump, .halt:
                break
            }

            for successor in successors(of: index, in: code) {
                if let old = states[successor] {
                    guard old.count == stack.count else {
                        throw Diagnostic(
                            stage: .validation,
                            message: "Inconsistent type-state height at instruction \(successor)"
                        )
                    }
                    let merged = zip(old, stack).map { $0.union($1) }
                    if merged != old {
                        states[successor] = merged
                        worklist.append(successor)
                    }
                } else {
                    states[successor] = stack
                    worklist.append(successor)
                }
            }
        }
    }

    private static func validateTarget(
        _ operand: RegisterOperand?,
        index: Int,
        count: Int
    ) throws {
        guard case .immediate(.int(let target)) = operand,
              target >= 0, target < count else {
            throw Diagnostic(stage: .validation, message: "Invalid jump target at \(index)")
        }
    }

    private static func validateLocal(
        _ operand: RegisterOperand?,
        index: Int,
        count: Int
    ) throws {
        guard case .immediate(.int(let slot)) = operand,
              slot >= 0, slot < count else {
            throw Diagnostic(stage: .validation, message: "Invalid local slot at \(index)")
        }
    }

    private static func shape(_ index: Int, _ opcode: RegisterOpcode) -> Diagnostic {
        Diagnostic(stage: .validation, message: "Malformed \(opcode) instruction at \(index)")
    }

    private static func isWritable(_ operand: RegisterOperand?) -> Bool {
        switch operand {
        case .register, .spill: return true
        default: return false
        }
    }

    private static func isReadable(_ operand: RegisterOperand?) -> Bool {
        operand != nil
    }

    private static func isStringImmediate(_ operand: RegisterOperand?) -> Bool {
        if case .immediate(.string) = operand { return true }
        return false
    }
}

private extension Value {
    var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}
