//
//  BytecodeSerialization.swift
//  Compiler
//
//  Created by Ulf Akerstedt-Inoue on 2026/07/25.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

import Foundation

public enum BytecodeImage: Equatable, Sendable {
    case stack(StackCompilation)
    case register(RegisterCompilation)
}

/// Stable binary container for compiler bytecode.
///
/// Layout:
/// `CMPB` magic, format version, target, reserved bytes, local count,
/// instruction count, then target-specific instructions. Multibyte integers
/// use big-endian byte order and strings use UTF-8 with a UInt32 byte length.
public enum BytecodeSerializer {
    public static let formatVersion: UInt8 = 2

    public static func encode(_ image: BytecodeImage) throws -> Data {
        var writer = BinaryWriter()
        writer.bytes([0x43, 0x4D, 0x50, 0x42])
        writer.byte(formatVersion)
        switch image {
        case .stack(let compilation):
            writer.byte(0)
            writer.uint16(0)
            writer.uint32(try checked(compilation.localCount))
            writer.uint32(try checked(compilation.instructions.count))
            for instruction in compilation.instructions {
                writer.byte(instruction.opcode.rawValue)
                writer.byte(try checkedByte(instruction.operands.count, label: "Operand count"))
                for operand in instruction.operands { try writer.value(operand) }
            }
        case .register(let compilation):
            writer.byte(1)
            writer.uint16(0)
            writer.uint32(try checked(compilation.localCount))
            writer.uint32(try checked(compilation.instructions.count))
            for instruction in compilation.instructions {
                writer.byte(instruction.opcode.rawValue)
                try writer.operand(instruction.destination)
                try writer.operand(instruction.source1)
                try writer.operand(instruction.source2)
                writer.uint32(try checked(instruction.extraOperands.count))
                for operand in instruction.extraOperands { try writer.operand(operand) }
            }
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> BytecodeImage {
        var reader = BinaryReader(data: data)
        guard try reader.bytes(count: 4) == [0x43, 0x4D, 0x50, 0x42] else {
            throw format("Invalid bytecode magic")
        }
        let version = try reader.byte()
        guard version == formatVersion else {
            throw format("Unsupported bytecode version \(version)")
        }
        let target = try reader.byte()
        _ = try reader.uint16()
        let localCount = try reader.count()
        let instructionCount = try reader.count()
        switch target {
        case 0:
            var code: [Instruction] = []
            code.reserveCapacity(instructionCount)
            for _ in 0..<instructionCount {
                guard let opcode = StackOpcode(rawValue: try reader.byte()) else {
                    throw format("Unknown stack opcode")
                }
                let operandCount = Int(try reader.byte())
                code.append(Instruction(opcode, try (0..<operandCount).map { _ in try reader.value() }))
            }
            try reader.requireEnd()
            try BytecodeValidator.validate(code, localCount: localCount)
            return .stack(StackCompilation(instructions: code, localCount: localCount))
        case 1:
            var code: [Instruction3] = []
            code.reserveCapacity(instructionCount)
            for _ in 0..<instructionCount {
                guard let opcode = RegisterOpcode(rawValue: try reader.byte()) else {
                    throw format("Unknown register opcode")
                }
                let destination = try reader.operand()
                let source1 = try reader.operand()
                let source2 = try reader.operand()
                let extraCount = try reader.count()
                var extraOperands: [RegisterOperand] = []
                extraOperands.reserveCapacity(extraCount)
                for _ in 0..<extraCount {
                    guard let operand = try reader.operand() else {
                        throw format("A variadic register operand cannot be absent")
                    }
                    extraOperands.append(operand)
                }
                code.append(Instruction3(
                    opcode,
                    destination: destination,
                    source1: source1,
                    source2: source2,
                    extraOperands: extraOperands
                ))
            }
            try reader.requireEnd()
            try BytecodeValidator.validate(code, localCount: localCount)
            return .register(RegisterCompilation(instructions: code, localCount: localCount))
        default:
            throw format("Unknown bytecode target \(target)")
        }
    }

    public static func write(_ image: BytecodeImage, to url: URL) throws {
        try encode(image).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> BytecodeImage {
        try decode(Data(contentsOf: url))
    }

    fileprivate static func checked(_ value: Int) throws -> UInt32 {
        guard value >= 0, let result = UInt32(exactly: value) else {
            throw format("Count \(value) does not fit the bytecode format")
        }
        return result
    }

    private static func checkedByte(_ value: Int, label: String) throws -> UInt8 {
        guard value >= 0, let result = UInt8(exactly: value) else {
            throw format("\(label) \(value) does not fit the bytecode format")
        }
        return result
    }

    fileprivate static func format(_ message: String) -> Diagnostic {
        Diagnostic(stage: .validation, message: "Bytecode format: \(message)")
    }
}

private struct BinaryWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func bytes(_ values: [UInt8]) { data.append(contentsOf: values) }
    mutating func uint16(_ value: UInt16) {
        bytes([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
    mutating func uint32(_ value: UInt32) {
        bytes([
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
    mutating func uint64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            byte(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
    mutating func value(_ value: Value) throws {
        switch value {
        case .int(let number): byte(0); uint64(UInt64(bitPattern: number))
        case .float(let number): byte(1); uint64(number.bitPattern)
        case .string(let string):
            byte(2)
            let utf8 = Array(string.utf8)
            guard let count = UInt32(exactly: utf8.count) else {
                throw BytecodeSerializer.format("String is too large")
            }
            uint32(count); bytes(utf8)
        case .boolean(let boolean): byte(3); byte(boolean ? 1 : 0)
        case .null: byte(4)
        case .array(let values):
            byte(5); uint32(try BytecodeSerializer.checked(values.count))
            for value in values { try self.value(value) }
        case .record(let name, let fields):
            byte(6); try self.value(.string(name)); uint32(try BytecodeSerializer.checked(fields.count))
            for key in fields.keys.sorted() { try self.value(.string(key)); try self.value(fields[key]!) }
        }
    }
    mutating func operand(_ operand: RegisterOperand?) throws {
        guard let operand else { byte(0); return }
        switch operand {
        case .register(let index):
            guard index >= 0, let encoded = UInt32(exactly: index) else {
                throw BytecodeSerializer.format("Invalid register \(index)")
            }
            byte(1); uint32(encoded)
        case .immediate(let value):
            byte(2); try self.value(value)
        case .spill(let index):
            guard index >= 0, let encoded = UInt32(exactly: index) else {
                throw BytecodeSerializer.format("Invalid spill slot \(index)")
            }
            byte(3); uint32(encoded)
        }
    }
}

private struct BinaryReader {
    let data: Data
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw BytecodeSerializer.format("Unexpected end of file") }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func bytes(count: Int) throws -> [UInt8] {
        try (0..<count).map { _ in try byte() }
    }
    mutating func uint16() throws -> UInt16 {
        let raw = try bytes(count: 2)
        return UInt16(raw[0]) << 8 | UInt16(raw[1])
    }
    mutating func uint32() throws -> UInt32 {
        let raw = try bytes(count: 4)
        return UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
    }
    mutating func uint64() throws -> UInt64 {
        var result: UInt64 = 0
        for value in try bytes(count: 8) { result = result << 8 | UInt64(value) }
        return result
    }
    mutating func count() throws -> Int {
        let raw = try uint32()
        guard let value = Int(exactly: raw) else { throw BytecodeSerializer.format("Count is too large") }
        return value
    }
    mutating func value() throws -> Value {
        switch try byte() {
        case 0: return .int(Int64(bitPattern: try uint64()))
        case 1: return .float(Double(bitPattern: try uint64()))
        case 2:
            let raw = try bytes(count: try count())
            guard let string = String(bytes: raw, encoding: .utf8) else {
                throw BytecodeSerializer.format("Invalid UTF-8 string")
            }
            return .string(string)
        case 3:
            let raw = try byte()
            guard raw <= 1 else { throw BytecodeSerializer.format("Invalid Boolean") }
            return .boolean(raw == 1)
        case 4: return .null
        case 5: return .array(try (0..<count()).map { _ in try value() })
        case 6:
            guard case .string(let name) = try value() else { throw BytecodeSerializer.format("Invalid record name") }
            var fields: [String: Value] = [:]
            let fieldCount = try count()
            for _ in 0..<fieldCount {
                guard case .string(let field) = try value() else { throw BytecodeSerializer.format("Invalid field name") }
                fields[field] = try value()
            }
            return .record(name: name, fields: fields)
        default: throw BytecodeSerializer.format("Unknown value tag")
        }
    }
    mutating func operand() throws -> RegisterOperand? {
        switch try byte() {
        case 0: return nil
        case 1: return .register(try count())
        case 2: return .immediate(try value())
        case 3: return .spill(try count())
        default: throw BytecodeSerializer.format("Unknown operand tag")
        }
    }
    mutating func requireEnd() throws {
        guard offset == data.count else { throw BytecodeSerializer.format("Trailing data") }
    }
}
