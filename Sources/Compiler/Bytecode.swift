import Foundation

public enum StackOpcode: UInt8, CaseIterable, Sendable {
    case push = 0x01, pop = 0x10
    case loadLocal = 0x20, storeLocal = 0x21
    case add = 0x30, sub, mul, div, mod, neg
    case eq = 0x40, ne, lt, le, gt, ge
    case jump = 0x60, jumpIfFalse
    case print = 0x70, readInt, call, `return`, halt
}

public struct Instruction: Equatable, CustomStringConvertible, Sendable {
    public let opcode: StackOpcode
    public let operands: [Value]
    public init(_ opcode: StackOpcode, _ operands: [Value] = []) {
        self.opcode = opcode
        self.operands = operands
    }
    public var description: String {
        operands.isEmpty ? "\(opcode)" : "\(opcode) " + operands.map(\.description).joined(separator: ", ")
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
    case print = 0x70, readInt, halt
}

public struct Instruction3: Equatable, CustomStringConvertible, Sendable {
    public let opcode: RegisterOpcode
    public let destination: RegisterOperand?
    public let source1: RegisterOperand?
    public let source2: RegisterOperand?

    public init(
        _ opcode: RegisterOpcode,
        destination: RegisterOperand? = nil,
        source1: RegisterOperand? = nil,
        source2: RegisterOperand? = nil
    ) {
        self.opcode = opcode
        self.destination = destination
        self.source1 = source1
        self.source2 = source2
    }

    public var description: String {
        ([String(describing: opcode)] + [destination, source1, source2].compactMap { $0?.description })
            .joined(separator: " ")
    }
}

public enum AnyBytecode: Equatable, Sendable {
    case stack([Instruction])
    case register([Instruction3])
}

public enum BytecodeValidator {
    public static func validate(_ code: [Instruction], localCount: Int) throws {
        for (index, instruction) in code.enumerated() {
            let expected = stackOperandCount(instruction.opcode)
            guard expected == nil || instruction.operands.count == expected else {
                throw Diagnostic(
                    stage: .validation,
                    message: "\(instruction.opcode) at \(index) expects \(expected ?? 0) operand(s)"
                )
            }
            if [.loadLocal, .storeLocal, .jump, .jumpIfFalse].contains(instruction.opcode) {
                guard case .int(let raw) = instruction.operands[0] else {
                    throw Diagnostic(stage: .validation, message: "\(instruction.opcode) at \(index) needs an integer operand")
                }
                if instruction.opcode == .loadLocal || instruction.opcode == .storeLocal {
                    guard raw >= 0 && raw < localCount else {
                        throw Diagnostic(stage: .validation, message: "Local \(raw) is out of bounds at \(index)")
                    }
                } else {
                    guard raw >= 0 && raw < code.count else {
                        throw Diagnostic(stage: .validation, message: "Jump target \(raw) is out of bounds at \(index)")
                    }
                }
            }
            if instruction.opcode == .call {
                guard instruction.operands.count >= 1,
                      case .int(let target) = instruction.operands[0],
                      target >= 0, target < code.count else {
                    throw Diagnostic(stage: .validation, message: "Invalid call target at \(index)")
                }
                for operand in instruction.operands.dropFirst() {
                    guard case .int(let slot) = operand, slot >= 0, slot < localCount else {
                        throw Diagnostic(stage: .validation, message: "Invalid call parameter slot at \(index)")
                    }
                }
            }
        }
        guard !code.isEmpty else { return }
        var heights: [Int: Int] = [0: 0]
        let callTargets = code.compactMap { instruction -> Int? in
            guard instruction.opcode == .call, case .int(let target) = instruction.operands[0] else { return nil }
            return Int(target)
        }
        for target in callTargets { heights[target] = 0 }
        var worklist = [0] + callTargets
        while let index = worklist.popLast() {
            let height = heights[index]!
            let effect = stackEffect(code[index])
            guard height + effect.minimum >= 0 else {
                throw Diagnostic(stage: .validation, message: "Stack underflow is possible at instruction \(index)")
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

    public static func validate(_ code: [Instruction3], localCount: Int, registerCount: Int = 32) throws {
        for (index, instruction) in code.enumerated() {
            let operands = [instruction.destination, instruction.source1, instruction.source2].compactMap { $0 }
            for operand in operands {
                if case .register(let register) = operand, !(0..<registerCount).contains(register) {
                    throw Diagnostic(stage: .validation, message: "Register R\(register) is out of bounds at \(index)")
                }
                if case .spill(let slot) = operand, slot < 0 {
                    throw Diagnostic(stage: .validation, message: "Spill slot S\(slot) is invalid at \(index)")
                }
            }
            switch instruction.opcode {
            case .jump:
                try validateTarget(instruction.destination, index: index, count: code.count)
            case .jumpIfFalse:
                guard isReadable(instruction.source1) else {
                    throw Diagnostic(stage: .validation, message: "jumpIfFalse at \(index) needs a condition register")
                }
                try validateTarget(instruction.destination, index: index, count: code.count)
            case .loadLocal:
                try validateLocal(instruction.source1, index: index, count: localCount)
                guard isWritable(instruction.destination) else { throw shape(index, instruction.opcode) }
            case .storeLocal:
                try validateLocal(instruction.destination, index: index, count: localCount)
                guard instruction.source1 != nil else { throw shape(index, instruction.opcode) }
            case .move:
                guard isWritable(instruction.destination), instruction.source1 != nil else {
                    throw shape(index, instruction.opcode)
                }
            case .neg:
                guard isWritable(instruction.destination), instruction.source1 != nil else {
                    throw shape(index, instruction.opcode)
                }
            case .readInt:
                guard isWritable(instruction.destination) else { throw shape(index, instruction.opcode) }
            case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge:
                guard isWritable(instruction.destination), instruction.source1 != nil, instruction.source2 != nil else {
                    throw shape(index, instruction.opcode)
                }
            case .print:
                guard instruction.source1 != nil else { throw shape(index, instruction.opcode) }
            case .halt:
                break
            }
        }
    }

    private static func stackOperandCount(_ opcode: StackOpcode) -> Int? {
        if opcode == .call { return nil }
        return [.push, .loadLocal, .storeLocal, .jump, .jumpIfFalse].contains(opcode) ? 1 : 0
    }
    private static func stackEffect(_ instruction: Instruction) -> (minimum: Int, delta: Int) {
        switch instruction.opcode {
        case .push, .loadLocal, .readInt: return (0, 1)
        case .pop, .storeLocal, .jumpIfFalse: return (-1, -1)
        case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge: return (-2, -1)
        case .neg: return (-1, 0)
        case .print, .return: return (-1, -1)
        case .call:
            let count = instruction.operands.count - 1
            return (-count, 1 - count)
        case .jump, .halt: return (0, 0)
        }
    }
    private static func successors(of index: Int, in code: [Instruction]) -> [Int] {
        switch code[index].opcode {
        case .halt, .return: return []
        case .jump: return [Int(code[index].operands[0].intValue!)]
        case .jumpIfFalse:
            let target = Int(code[index].operands[0].intValue!)
            return index + 1 < code.count ? [index + 1, target] : [target]
        default: return index + 1 < code.count ? [index + 1] : []
        }
    }
    private static func validateTypeState(_ code: [Instruction]) throws {
        typealias AbstractValue = Set<TypeInfo>
        let any: AbstractValue = [.int, .float, .string, .boolean, .null]
        var states: [Int: [AbstractValue]] = [0: []]
        let callTargets = code.compactMap { instruction -> Int? in
            guard instruction.opcode == .call, case .int(let target) = instruction.operands[0] else { return nil }
            return Int(target)
        }
        for target in callTargets { states[target] = [] }
        var worklist = [0] + callTargets

        while let index = worklist.popLast() {
            var stack = states[index]!
            let instruction = code[index]
            func pop() throws -> AbstractValue {
                guard let value = stack.popLast() else {
                    throw Diagnostic(stage: .validation, message: "Stack underflow at instruction \(index)")
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
                        message: "\(operation) cannot consume \(value.map(\.rawValue).sorted()) at instruction \(index)"
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
            case .pop, .storeLocal, .print:
                _ = try pop()
            case .return:
                _ = try pop()
            case .call:
                for _ in instruction.operands.dropFirst() { _ = try pop() }
                stack.append(any)
            case .jumpIfFalse:
                let condition = try pop()
                try require(condition, allowed: [.boolean], operation: .jumpIfFalse)
            case .neg:
                let operand = try pop()
                try require(operand, allowed: [.int, .float], operation: .neg)
                stack.append(operand.intersection([.int, .float]))
            case .add, .sub, .mul, .div, .mod:
                let rhs = try pop(), lhs = try pop()
                let numeric: Set<TypeInfo> = [.int, .float]
                if instruction.opcode == .add,
                   lhs.contains(.string), rhs.contains(.string) {
                    stack.append([.string])
                } else {
                    try require(lhs, allowed: numeric, operation: instruction.opcode)
                    try require(rhs, allowed: numeric, operation: instruction.opcode)
                    if instruction.opcode == .mod {
                        guard lhs.contains(.int), rhs.contains(.int) else {
                            throw Diagnostic(stage: .validation, message: "mod requires integer values at instruction \(index)")
                        }
                        stack.append([.int])
                    } else {
                        stack.append(lhs.contains(.float) || rhs.contains(.float) ? [.int, .float] : [.int])
                    }
                }
            case .eq, .ne:
                _ = try pop(); _ = try pop(); stack.append([.boolean])
            case .lt, .le, .gt, .ge:
                let rhs = try pop(), lhs = try pop()
                let ordered: Set<TypeInfo> = [.int, .float, .string]
                try require(lhs, allowed: ordered, operation: instruction.opcode)
                try require(rhs, allowed: ordered, operation: instruction.opcode)
                stack.append([.boolean])
            case .jump, .halt:
                break
            }

            for successor in successors(of: index, in: code) {
                if let old = states[successor] {
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
    private static func validateTarget(_ operand: RegisterOperand?, index: Int, count: Int) throws {
        guard case .immediate(.int(let target)) = operand, target >= 0, target < count else {
            throw Diagnostic(stage: .validation, message: "Invalid jump target at \(index)")
        }
    }
    private static func validateLocal(_ operand: RegisterOperand?, index: Int, count: Int) throws {
        guard case .immediate(.int(let slot)) = operand, slot >= 0, slot < count else {
            throw Diagnostic(stage: .validation, message: "Invalid local slot at \(index)")
        }
    }
    private static func shape(_ index: Int, _ opcode: RegisterOpcode) -> Diagnostic {
        Diagnostic(stage: .validation, message: "Malformed \(opcode) instruction at \(index)")
    }
    private static func isWritable(_ operand: RegisterOperand?) -> Bool {
        if case .register = operand { return true }
        if case .spill = operand { return true }
        return false
    }
    private static func isReadable(_ operand: RegisterOperand?) -> Bool {
        operand != nil
    }
}

private extension Value {
    var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}
