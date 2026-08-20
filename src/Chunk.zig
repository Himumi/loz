pub const OpCode = enum(u8) {
    constant,
    constant_long,
    @"return",
    _,

    pub fn toString(self: OpCode) []const u8 {
        return switch (self) {
            .constant => "CONSTANT",
            .constant_long => "CONSTANT_LONG",
            .@"return" => "RETURN",
            _ => "UNKNOWN",
        };
    }
};

pub const Chunk = @This();

codes: ArrayList(u8),
constants: ArrayList(Value),
lines: ArrayList(Line),

const Value = f64;
const Line = struct {
    count: usize,
    line: usize,
};

pub const empty: Chunk = .{
    .codes = .empty,
    .constants = .empty,
    .lines = .empty,
};

pub fn deinit(self: *Chunk, gpa: Allocator) void {
    self.codes.deinit(gpa);
    self.constants.deinit(gpa);
    self.lines.deinit(gpa);
}

pub fn writeLiteral(
    self: *Chunk,
    gpa: Allocator,
    literal: u8,
    line: usize,
) Allocator.Error!void {
    try self.codes.append(gpa, literal);

    if (self.lines.items.len > 0) {
        const last_index = self.lines.items.len - 1;
        if (self.lines.items[last_index].line == line) {
            self.lines.items[last_index].count += 1;
            return;
        }
    }

    try self.lines.append(gpa, .{ .count = 1, .line = line });
}

pub fn writeCode(
    self: *Chunk,
    gpa: Allocator,
    code: OpCode,
    line: usize,
) Allocator.Error!void {
    try self.writeLiteral(gpa, @intFromEnum(code), line);
}

pub fn writeConstant(
    self: *Chunk,
    gpa: Allocator,
    value_index: usize,
    line: usize,
) Allocator.Error!void {
    if (value_index > 255) {
        const value_24: u24 = @truncate(value_index);
        const bytes: [3]u8 = @bitCast(value_24);

        try self.writeCode(gpa, .constant_long, line);
        for (bytes) |byte| {
            try self.writeLiteral(gpa, byte, line);
        }
    } else {
        try self.writeCode(gpa, .constant, line);
        try self.writeLiteral(gpa, @intCast(value_index), line);
    }
}

pub fn addValue(self: *Chunk, gpa: Allocator, value: Value) Allocator.Error!u32 {
    try self.constants.append(gpa, value);
    return @intCast(self.constants.items.len - 1);
}

pub fn disassemble(self: Chunk, writer: *Io.Writer, name: []const u8) Io.Writer.Error!void {
    try writer.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < self.codes.items.len) {
        offset = try self.disassembleInstruction(writer, offset);
    }
}

fn disassembleInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    try writer.print("{d:0>4} ", .{offset});
    try self.printLine(writer, offset);

    const instruction: OpCode = @enumFromInt(self.codes.items[offset]);
    return switch (instruction) {
        .@"return" => try simpleInstruction(writer, OpCode.@"return".toString(), offset),
        .constant => try self.constantInstruction(writer, offset),
        .constant_long => try self.constantLongInstruction(writer, offset),
        _ => {
            try writer.print("Unknown opcode {any}\n", .{instruction});
            return offset + 1;
        },
    };
}

fn constantInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    const name = OpCode.constant.toString();
    const constant = self.codes.items[offset + 1];
    const value = self.constants.items[@intCast(constant)];

    try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, value });
    return offset + 2;
}

fn constantLongInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    const name = OpCode.constant_long.toString();
    const constant = self.getConstantLong(offset + 1);
    const value = self.constants.items[@intCast(constant)];

    try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, value });
    return offset + 4;
}

fn getConstantLong(self: Chunk, offset: usize) u32 {
    const bytes = self.codes.items[offset .. offset + 3];
    return mem.readInt(u24, bytes[0..3], .big);
}

fn getLine(self: Chunk, instruction_offset: usize) ?usize {
    var accumulator: usize = 0;

    for (self.lines.items) |line| {
        accumulator += line.count;
        if (instruction_offset < accumulator) {
            return line.line;
        }
    }
    return null;
}

fn printLine(self: Chunk, writer: *Io.Writer, offset: usize) Io.Writer.Error!void {
    if (self.getLine(offset)) |line| {
        if (offset > 0) {
            const previous_line = self.getLine(offset - 1).?;
            if (line == previous_line) {
                return try writer.writeAll("   | ");
            }
        }
        try writer.print("{d:>4} ", .{line});
    }
}

fn simpleInstruction(writer: *Io.Writer, name: []const u8, offset: usize) Io.Writer.Error!usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
}

test "Chunk" {
    const gpa = testing.allocator;

    var chunk: Chunk = .empty;
    defer chunk.deinit(gpa);

    const constant_index = try chunk.addValue(gpa, 1.2);
    try chunk.writeConstant(gpa, constant_index, 123);

    const values = [_]f64{0} ** 256;
    try chunk.constants.appendSlice(gpa, &values);

    try chunk.writeConstant(gpa, chunk.constants.items.len - 1, 123);
    try chunk.writeCode(gpa, .@"return", 123);

    var writer: Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    try chunk.disassemble(&writer.writer, "test chunk");
    const expected =
        \\== test chunk ==
        \\0000  123 CONSTANT            0 '1.2'
        \\0002    | CONSTANT_LONG     256 '0'
        \\0006    | RETURN
        \\
    ;
    try testing.expectEqualSlices(u8, expected, writer.written());
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
