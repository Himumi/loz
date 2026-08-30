pub const Code = enum(u8) {
    op_constant,
    op_constant_long,
    op_nil,
    op_true,
    op_false,

    op_equal,
    op_greater,
    op_less,

    op_add,
    op_subtract,
    op_multiply,
    op_divide,
    op_not,

    op_negate,

    op_return,
    op_jump,
    op_jump_if_false,
    op_loop,
    op_print,
    op_pop,
    op_define_global,
    op_define_global_long,
    op_get_global,
    op_get_global_long,
    op_set_global,
    op_set_global_long,
    op_get_local,
    op_get_local_long,
    op_set_local,
    op_set_local_long,

    op_empty,
    _,

    pub fn toString(self: Code) []const u8 {
        return switch (self) {
            .op_constant => "CONSTANT",
            .op_constant_long => "CONSTANT_LONG",
            .op_nil => "NIL",
            .op_true => "TRUE",
            .op_false => "FALSE",

            .op_equal => "EQUAL",
            .op_greater => "GREATER",
            .op_less => "LESS",

            .op_add => "ADD",
            .op_subtract => "SUBTRACT",
            .op_multiply => "MULTIPLY",
            .op_divide => "DIVIDE",
            .op_not => "NOT",

            .op_negate => "NEGATE",

            .op_return => "RETURN",
            .op_jump => "JUMP",
            .op_jump_if_false => "JUMP_IF_FALSE",
            .op_loop => "LOOP",
            .op_print => "PRINT",
            .op_pop => "POP",
            .op_define_global => "DEFINE_GLOBAL",
            .op_define_global_long => "DEFINE_GLOBAL_LONG",
            .op_get_global => "GET_GLOBAL",
            .op_get_global_long => "GET_GLOBAL_LONG",
            .op_set_global => "SET_GLOBAL",
            .op_set_global_long => "SET_GLOBAL_LONG",
            .op_get_local => "GET_LOCAL",
            .op_get_local_long => "GET_LOCAL_LONG",
            .op_set_local => "SET_LOCAL",
            .op_set_local_long => "SET_LOCAL_LONG",

            .op_empty => "EMPTY",
            else => "UNKNOWN",
        };
    }
};

pub const Chunk = @This();

codes: ArrayList(u8),
constants: ArrayList(Value),
lines: ArrayList(Line),

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

    for (self.constants.items) |constant| {
        constant.deinit(gpa);
    }
    self.constants.deinit(gpa);

    self.lines.deinit(gpa);
}

pub fn writeLiteral(self: *Chunk, gpa: Allocator, literal: u8, line: usize) Allocator.Error!void {
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

pub fn writeChunk(self: *Chunk, gpa: Allocator, code: Code, line: usize) Allocator.Error!void {
    try self.writeLiteral(gpa, @intFromEnum(code), line);
}

pub fn writeConstant(
    self: *Chunk,
    gpa: Allocator,
    value_index: u32,
    line: usize,
) Allocator.Error!void {
    if (value_index > values.max_u8) {
        try self.writeChunk(gpa, .op_constant_long, line);
        for (utils.writeU24(value_index)) |byte| {
            try self.writeLiteral(gpa, byte, line);
        }
    } else {
        try self.writeChunk(gpa, .op_constant, line);
        try self.writeLiteral(gpa, @intCast(value_index), line);
    }
}

pub fn addValue(self: *Chunk, gpa: Allocator, value: Value) Allocator.Error!u32 {
    try self.constants.append(gpa, value);
    return @intCast(self.constants.items.len - 1);
}

/// For debugging purpose.
/// BUG: diassaemble is broken.
pub fn disassemble(self: Chunk, writer: *Io.Writer, name: []const u8) Io.Writer.Error!void {
    try writer.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < self.codes.items.len) {
        offset = try self.disassembleInstruction(writer, offset);
    }
}

pub fn disassembleInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    try writer.print("{d:0>4} ", .{offset});
    try self.printLine(writer, offset);

    const instruction: Code = @enumFromInt(self.codes.items[offset]);
    return switch (instruction) {
        .op_constant => try self.constantInstruction(writer, .op_constant, offset),
        .op_constant_long => try self.constantLongInstruction(writer, .op_constant_long, offset),

        .op_nil => try simpleInstruction(writer, .op_nil, offset),
        .op_true => try simpleInstruction(writer, .op_true, offset),
        .op_false => try simpleInstruction(writer, .op_false, offset),

        .op_equal => try simpleInstruction(writer, .op_equal, offset),
        .op_greater => try simpleInstruction(writer, .op_greater, offset),
        .op_less => try simpleInstruction(writer, .op_less, offset),

        .op_add => try simpleInstruction(writer, .op_add, offset),
        .op_subtract => try simpleInstruction(writer, .op_subtract, offset),
        .op_multiply => try simpleInstruction(writer, .op_multiply, offset),
        .op_divide => try simpleInstruction(writer, .op_divide, offset),
        .op_not => try simpleInstruction(writer, .op_not, offset),

        .op_negate => try simpleInstruction(writer, .op_negate, offset),
        .op_return => try simpleInstruction(writer, .op_return, offset),
        .op_jump => try self.jumpInstruction(writer, .op_jump, 1, offset),
        .op_jump_if_false => try self.jumpInstruction(writer, .op_jump_if_false, 1, offset),
        .op_loop => try self.jumpInstruction(writer, .op_loop, -1, offset),
        .op_print => try simpleInstruction(writer, .op_print, offset),
        .op_pop => try simpleInstruction(writer, .op_pop, offset),

        .op_define_global => {
            return try self.constantInstruction(writer, .op_define_global, offset);
        },
        .op_define_global_long => {
            return try self.constantLongInstruction(writer, .op_define_global_long, offset);
        },
        .op_get_global => {
            return try self.constantInstruction(writer, .op_get_global, offset);
        },
        .op_get_global_long => {
            return try self.constantLongInstruction(writer, .op_get_global_long, offset);
        },
        .op_set_global => {
            return try self.constantInstruction(writer, .op_set_global, offset);
        },
        .op_set_global_long => {
            return try self.constantInstruction(writer, .op_set_global_long, offset);
        },
        .op_get_local => try self.byteInstruction(writer, .op_get_local, offset),
        .op_get_local_long => try self.byteLongInstruction(writer, .op_get_local_long, offset),
        .op_set_local => try self.byteInstruction(writer, .op_set_local, offset),
        .op_set_local_long => try self.byteLongInstruction(writer, .op_set_local_long, offset),

        else => {
            try writer.print("Unknown opcode {any}\n", .{instruction});
            return offset + 1;
        },
    };
}

fn byteInstruction(self: Chunk, writer: *Io.Writer, code: Code, offset: usize) !usize {
    const name = code.toString();
    const slot = self.codes.items[offset + 1];
    try writer.print("{s:<16} {d:>4}\n", .{ name, slot });
    return offset + 2;
}

fn byteLongInstruction(self: Chunk, writer: *Io.Writer, code: Code, offset: usize) !usize {
    const name = code.toString();
    const slot = self.getConstantLong(offset + 1);
    try writer.print("{s:<16} {d:>4}\n", .{ name, slot });
    return offset + 4;
}

fn constantInstruction(self: Chunk, writer: *Io.Writer, code: Code, offset: usize) !usize {
    const name = code.toString();
    const constant = self.codes.items[offset + 1];
    const value = self.constants.items[@intCast(constant)];

    try value.dumpInstruction(writer, name, constant);
    return offset + 2;
}

fn constantLongInstruction(self: Chunk, writer: *Io.Writer, code: Code, offset: usize) !usize {
    const name = code.toString();
    const constant = self.getConstantLong(offset + 1);
    const value = self.constants.items[@intCast(constant)];

    try value.dumpInstruction(writer, name, constant);
    return offset + 4;
}

fn jumpInstruction(self: Chunk, writer: *Io.Writer, code: Code, sign: isize, offset: usize) !usize {
    const name = code.toString();
    const jump_index: isize = self.getShort(offset + 1);
    const i_offset: isize = @intCast(offset);
    const start_index = (i_offset + 3 + sign + jump_index);
    try writer.print("{s:>16} {d:>4} -> {}\n", .{ name, offset, start_index });
    return offset + 3;
}

pub fn getConstantLong(self: Chunk, offset: usize) u32 {
    const bytes = self.codes.items[offset .. offset + 3];
    return mem.readInt(u24, bytes[0..3], .big);
}

pub fn getShort(self: Chunk, offset: usize) u32 {
    const bytes = self.codes.items[offset .. offset + 2];
    return mem.readInt(u16, bytes[0..2], .big);
}

/// BUG: getLine is broken makes the diassaemble function to not work.
pub fn getLine(self: Chunk, instruction_offset: usize) ?usize {
    var accumulator: usize = 0;

    for (self.lines.items) |line| {
        accumulator += line.count;
        if (instruction_offset < accumulator) {
            return line.line;
        }
    }
    return null;
}

/// BUG: printLine is broken makes the diassaemble function to not work.
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

fn simpleInstruction(writer: *Io.Writer, code: Code, offset: usize) Io.Writer.Error!usize {
    try writer.print("{s}\n", .{code.toString()});
    return offset + 1;
}

test "Chunk" {
    const gpa = testing.allocator;

    var chunk: Chunk = .empty;
    defer chunk.deinit(gpa);

    const constant_index = try chunk.addValue(gpa, .{ .number = 1.2 });
    try chunk.writeConstant(gpa, constant_index, 123);

    const constants = [_]Value{.{ .number = 0 }} ** 256;
    try chunk.constants.appendSlice(gpa, &constants);

    try chunk.writeConstant(gpa, @intCast(chunk.constants.items.len - 1), 123);
    try chunk.writeChunk(gpa, .op_return, 123);

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

const utils = @import("utils.zig");
const values = @import("values.zig");
const Value = values.Value;
