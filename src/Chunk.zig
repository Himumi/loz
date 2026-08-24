pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    nil: void,

    pub fn isNumber(self: Value) bool {
        return self == .number;
    }

    pub fn isBoolean(self: Value) bool {
        return self == .boolean;
    }

    pub fn isNil(self: Value) bool {
        return self == .nil;
    }

    pub fn isSame(self: Value, target: Value) bool {
        if (self.isNumber() and target.isNumber()) return true;
        if (self.isNil() and target.isNil()) return true;
        if (self.isBoolean() and target.isBoolean()) return true;

        return false;
    }

    pub fn isEqual(self: Value, target: Value) bool {
        if (!self.isSame(target)) return false;

        return switch (self) {
            .nil => return true,
            .boolean => |boolean| boolean == target.boolean,
            .number => |number| number == target.number,
        };
    }

    pub fn print(self: Value, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .number => |number| try writer.print("{}", .{number}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .nil => try writer.writeAll("nil"),
        }
    }

    fn dumpInstruction(
        self: Value,
        writer: *Io.Writer,
        name: []const u8,
        constant: u32,
    ) Io.Writer.Error!void {
        switch (self) {
            .number => |number| {
                try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, number });
            },
            .boolean => |boolean| {
                try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, boolean });
            },
            .nil => {
                try writer.print("{s:<16} {d:>4} 'nil'\n", .{ name, constant });
            },
        }
    }

    pub fn isFalsey(self: Value) bool {
        return switch (self) {
            .nil => true,
            .boolean => |boolean| !boolean,
            else => false,
        };
    }
};

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
            _ => "UNKNOWN",
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

pub fn writeChunk(
    self: *Chunk,
    gpa: Allocator,
    code: Code,
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

        try self.writeChunk(gpa, .op_constant_long, line);
        for (bytes) |byte| {
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
        .op_constant => try self.constantInstruction(writer, offset),
        .op_constant_long => try self.constantLongInstruction(writer, offset),

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

        else => {
            try writer.print("Unknown opcode {any}\n", .{instruction});
            return offset + 1;
        },
    };
}

fn constantInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    const name = Code.op_constant.toString();
    const constant = self.codes.items[offset + 1];
    const value = self.constants.items[@intCast(constant)];

    try value.dumpInstruction(writer, name, constant);
    return offset + 2;
}

fn constantLongInstruction(self: Chunk, writer: *Io.Writer, offset: usize) !usize {
    const name = Code.op_constant_long.toString();
    const constant = self.getConstantLong(offset + 1);
    const value = self.constants.items[@intCast(constant)];

    try value.dumpInstruction(writer, name, constant);
    return offset + 4;
}

pub fn getConstantLong(self: Chunk, offset: usize) u32 {
    const bytes = self.codes.items[offset .. offset + 3];
    return mem.readInt(u24, bytes[0..3], .big);
}

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

    const values = [_]Value{.{ .number = 0 }} ** 256;
    try chunk.constants.appendSlice(gpa, &values);

    try chunk.writeConstant(gpa, chunk.constants.items.len - 1, 123);
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
