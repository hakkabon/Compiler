import Foundation

public typealias InputProvider = @Sendable () throws -> String
public typealias OutputHandler = @Sendable (String) -> Void

private func binary(_ opcode: StackOpcode, _ lhs: Value, _ rhs: Value) throws -> Value {
    switch opcode {
    case .add:
        if case (.string(let a), .string(let b)) = (lhs, rhs) { return .string(a + b) }
        return try numeric(lhs, rhs, int: { .int($0 &+ $1) }, float: { .float($0 + $1) })
    case .sub: return try numeric(lhs, rhs, int: { .int($0 &- $1) }, float: { .float($0 - $1) })
    case .mul: return try numeric(lhs, rhs, int: { .int($0 &* $1) }, float: { .float($0 * $1) })
    case .div:
        return try numeric(lhs, rhs, int: {
            guard $1 != 0 else { throw Diagnostic(stage: .runtime, message: "Division by zero") }
            return .int($0 / $1)
        }, float: {
            guard $1 != 0 else { throw Diagnostic(stage: .runtime, message: "Division by zero") }
            return .float($0 / $1)
        })
    case .mod:
        guard case .int(let a) = lhs, case .int(let b) = rhs else { throw typeError(opcode, lhs, rhs) }
        guard b != 0 else { throw Diagnostic(stage: .runtime, message: "Division by zero") }
        return .int(a % b)
    case .eq: return .boolean(lhs == rhs || numericEqual(lhs, rhs))
    case .ne: return .boolean(!(lhs == rhs || numericEqual(lhs, rhs)))
    case .lt, .le, .gt, .ge:
        let order = try compare(lhs, rhs)
        switch opcode {
        case .lt: return .boolean(order < 0)
        case .le: return .boolean(order <= 0)
        case .gt: return .boolean(order > 0)
        default: return .boolean(order >= 0)
        }
    default: throw Diagnostic(stage: .runtime, message: "\(opcode) is not a binary operation")
    }
}

private func numeric(
    _ lhs: Value,
    _ rhs: Value,
    int: (Int64, Int64) throws -> Value,
    float: (Double, Double) throws -> Value
) throws -> Value {
    switch (lhs, rhs) {
    case (.int(let a), .int(let b)): return try int(a, b)
    case (.float(let a), .float(let b)): return try float(a, b)
    case (.int(let a), .float(let b)): return try float(Double(a), b)
    case (.float(let a), .int(let b)): return try float(a, Double(b))
    default: throw typeError(.add, lhs, rhs)
    }
}
private func numericEqual(_ lhs: Value, _ rhs: Value) -> Bool {
    switch (lhs, rhs) {
    case (.int(let a), .float(let b)): return Double(a) == b
    case (.float(let a), .int(let b)): return a == Double(b)
    default: return false
    }
}
private func compare(_ lhs: Value, _ rhs: Value) throws -> Int {
    switch (lhs, rhs) {
    case (.int(let a), .int(let b)): return a == b ? 0 : (a < b ? -1 : 1)
    case (.float(let a), .float(let b)): return a == b ? 0 : (a < b ? -1 : 1)
    case (.int(let a), .float(let b)): return Double(a) == b ? 0 : (Double(a) < b ? -1 : 1)
    case (.float(let a), .int(let b)): return a == Double(b) ? 0 : (a < Double(b) ? -1 : 1)
    case (.string(let a), .string(let b)): return a == b ? 0 : (a < b ? -1 : 1)
    default: throw typeError(.lt, lhs, rhs)
    }
}
private func typeError(_ opcode: StackOpcode, _ lhs: Value, _ rhs: Value) -> Diagnostic {
    Diagnostic(stage: .runtime, message: "Cannot apply \(opcode) to \(lhs.type) and \(rhs.type)")
}
private func stackOpcode(_ opcode: RegisterOpcode) throws -> StackOpcode {
    guard let result: StackOpcode = [
        .add: .add, .sub: .sub, .mul: .mul, .div: .div, .mod: .mod,
        .eq: .eq, .ne: .ne, .lt: .lt, .le: .le, .gt: .gt, .ge: .ge,
    ][opcode] else { throw Diagnostic(stage: .runtime, message: "\(opcode) is not binary") }
    return result
}

public final class StackMachine {
    private let code: [Instruction]
    private let localCount: Int
    private let input: InputProvider
    private let output: OutputHandler

    public init(
        bytecode: [Instruction],
        localCount: Int = 0,
        input: @escaping InputProvider = { readLine() ?? "" },
        output: @escaping OutputHandler = { print($0) }
    ) {
        code = bytecode; self.localCount = localCount; self.input = input; self.output = output
    }

    public func execute() throws -> Value? { try run(trace: nil) }
    public func executeWithTrace(_ trace: @escaping OutputHandler = { print($0) }) throws -> Value? { try run(trace: trace) }

    private func run(trace: OutputHandler?) throws -> Value? {
        try BytecodeValidator.validate(code, localCount: localCount)
        var ip = 0, stack: [Value] = [], locals = Array(repeating: Value.null, count: localCount)
        var frames: [(returnIP: Int, locals: [Value])] = []
        func pop() throws -> Value {
            guard let value = stack.popLast() else { throw Diagnostic(stage: .runtime, message: "Stack underflow") }
            return value
        }
        while ip < code.count {
            let instruction = code[ip]
            trace?("[\(ip)] \(instruction) stack=\(stack)")
            switch instruction.opcode {
            case .push: stack.append(instruction.operands[0])
            case .pop: _ = try pop()
            case .loadLocal: stack.append(locals[Int(instruction.operands[0].intValue!)])
            case .storeLocal: locals[Int(instruction.operands[0].intValue!)] = try pop()
            case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge:
                let rhs = try pop(), lhs = try pop(); stack.append(try binary(instruction.opcode, lhs, rhs))
            case .neg:
                let value = try pop()
                switch value {
                case .int(let number): stack.append(.int(-number))
                case .float(let number): stack.append(.float(-number))
                default: throw Diagnostic(stage: .runtime, message: "Cannot negate \(value.type)")
                }
            case .jump:
                ip = Int(instruction.operands[0].intValue!); continue
            case .jumpIfFalse:
                let target = Int(instruction.operands[0].intValue!)
                if !(try pop()).isTruthy { ip = target; continue }
            case .print: output(try pop().description)
            case .readInt:
                guard let value = Int64(try input()) else { throw Diagnostic(stage: .runtime, message: "Expected integer input") }
                stack.append(.int(value))
            case .call:
                let target = Int(instruction.operands[0].intValue!)
                let slots = instruction.operands.dropFirst().map { Int($0.intValue!) }
                var arguments: [Value] = []
                arguments.reserveCapacity(slots.count)
                for _ in slots { arguments.append(try pop()) }
                arguments.reverse()
                frames.append((returnIP: ip + 1, locals: locals))
                for (slot, argument) in zip(slots, arguments) { locals[slot] = argument }
                ip = target
                continue
            case .return:
                let result = try pop()
                guard let frame = frames.popLast() else {
                    throw Diagnostic(stage: .runtime, message: "Return without a call frame")
                }
                locals = frame.locals
                stack.append(result)
                ip = frame.returnIP
                continue
            case .halt: return stack.last ?? .null
            }
            ip += 1
        }
        return stack.last ?? .null
    }
}


public final class RegisterMachine {
    private let code: [Instruction3]
    private let localCount: Int
    private let input: InputProvider
    private let output: OutputHandler

    public init(
        bytecode: [Instruction3],
        localCount: Int = 0,
        input: @escaping InputProvider = { readLine() ?? "" },
        output: @escaping OutputHandler = { print($0) }
    ) {
        code = bytecode; self.localCount = localCount; self.input = input; self.output = output
    }

    public func execute() throws -> Value? { try run(trace: nil) }
    public func executeWithTrace(_ trace: @escaping OutputHandler = { print($0) }) throws -> Value? { try run(trace: trace) }

    private func run(trace: OutputHandler?) throws -> Value? {
        try BytecodeValidator.validate(code, localCount: localCount)
        var ip = 0, registers = Array(repeating: Value.null, count: 32), locals = Array(repeating: Value.null, count: localCount)
        let spillCount = code.flatMap { [$0.destination, $0.source1, $0.source2] }
            .compactMap { operand -> Int? in
                guard case .spill(let slot) = operand else { return nil }
                return slot
            }
            .max().map { $0 + 1 } ?? 0
        var spills = Array(repeating: Value.null, count: spillCount)
        func value(_ operand: RegisterOperand?) throws -> Value {
            guard let operand else { throw Diagnostic(stage: .runtime, message: "Missing register operand") }
            switch operand {
            case .immediate(let value): return value
            case .register(let register): return registers[register]
            case .spill(let slot): return spills[slot]
            }
        }
        func write(_ operand: RegisterOperand?, _ value: Value) throws {
            switch operand {
            case .register(let register): registers[register] = value
            case .spill(let slot): spills[slot] = value
            default:
                throw Diagnostic(stage: .runtime, message: "Expected writable register or spill slot")
            }
        }
        func immediateInt(_ operand: RegisterOperand?) throws -> Int {
            guard case .immediate(.int(let integer)) = operand else {
                throw Diagnostic(stage: .runtime, message: "Expected integer immediate")
            }
            return Int(integer)
        }
        while ip < code.count {
            let instruction = code[ip]
            trace?("[\(ip)] \(instruction) R0=\(registers[0])")
            switch instruction.opcode {
            case .move: try write(instruction.destination, value(instruction.source1))
            case .loadLocal: try write(instruction.destination, locals[try immediateInt(instruction.source1)])
            case .storeLocal: locals[try immediateInt(instruction.destination)] = try value(instruction.source1)
            case .add, .sub, .mul, .div, .mod, .eq, .ne, .lt, .le, .gt, .ge:
                try write(
                    instruction.destination,
                    binary(stackOpcode(instruction.opcode), value(instruction.source1), value(instruction.source2))
                )
            case .neg:
                let source = try value(instruction.source1)
                switch source {
                case .int(let number): try write(instruction.destination, .int(-number))
                case .float(let number): try write(instruction.destination, .float(-number))
                default: throw Diagnostic(stage: .runtime, message: "Cannot negate \(source.type)")
                }
            case .jump: ip = try immediateInt(instruction.destination); continue
            case .jumpIfFalse:
                if !(try value(instruction.source1)).isTruthy {
                    ip = try immediateInt(instruction.destination); continue
                }
            case .print: output(try value(instruction.source1).description)
            case .readInt:
                guard let value = Int64(try input()) else { throw Diagnostic(stage: .runtime, message: "Expected integer input") }
                try write(instruction.destination, .int(value))
            case .halt: return registers[0]
            }
            ip += 1
        }
        return registers[0]
    }
}

private extension Value {
    var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}
