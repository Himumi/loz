pub fn Stack(comptime T: type) type {
    return struct {
        store: ArrayList(T),

        const Self = @This();

        pub fn initCapacity(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            return .{ .store = try .initCapacity(gpa, capacity) };
        }

        pub const empty: Self = .{ .store = .empty };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.store.deinit(gpa);
        }

        pub fn reset(self: *Self) void {
            self.store.items.len = 0;
        }

        pub fn last(self: Self) ?usize {
            if (self.store.items.len > 0) {
                return self.store.items.len - 1;
            }
            return null;
        }

        pub fn len(self: Self) usize {
            return self.store.items.len;
        }

        pub fn push(self: *Self, gpa: Allocator, value: T) Allocator.Error!void {
            try self.store.append(gpa, value);
        }

        pub fn pop(self: *Self) ?T {
            return self.store.pop();
        }

        pub fn peek(self: Self) T {
            return self.store.items[self.store.items.len - 1];
        }

        pub fn set(self: *Self, index: usize, value: Chunk.Value) void {
            self.store.items[index] = value;
        }

        pub fn slice(self: Self) []T {
            if (self.last()) |index| {
                return self.store[0..index];
            }
            return &.{};
        }
    };
}

const VMError = Error || Io.Writer.Error || Allocator.Error;

const VM = @This();
// It borrows the memory.
chunk: *Chunk,
ip: usize,
stack: Stack(Chunk.Value),

pub const Error = (RuntimeError || Compiler.Error);

pub const RuntimeError = error{
    EmptyStack,
    InvalidOperation,
    InvalidBinaryOperation,
    UndefinedValue,
    OperandMustBeNumber,
};

pub const empty: VM = .{
    .chunk = undefined,
    .ip = 0,
    .stack = .empty,
};

pub fn initCapacity(gpa: Allocator, capacity: usize) Allocator.Error!VM {
    return .{
        .chunk = undefined,
        .ip = 0,
        .stack = try .initCapacity(gpa, capacity),
    };
}

pub fn deinit(self: *VM, gpa: Allocator) void {
    self.stack.deinit(gpa);
}

pub fn interpret(self: *VM, gpa: Allocator, ctx: *Context, source: [:0]const u8) !void {
    // It borrows the memory.
    var chunk = try compiler.compile(gpa, ctx, source);
    defer chunk.deinit(gpa);

    self.chunk = &chunk;
    self.ip = 0;

    try self.run(gpa, ctx);
}

pub fn run(self: *VM, gpa: Allocator, ctx: *Context) VMError!void {
    while (self.ip < self.chunk.codes.items.len) {
        // Uncomment for debugging.
        // try self.dumpStack(ctx.stream.err);
        // try self.dumpInstruction(ctx.stream.err, self.ip);

        const code: Chunk.Code = @enumFromInt(self.readByte());
        switch (code) {
            .op_constant => try self.stack.push(gpa, self.readConstant()),
            .op_constant_long => try self.stack.push(gpa, self.readConstantLong()),
            .op_nil => try self.stack.push(gpa, .nil),
            .op_true => try self.stack.push(gpa, .{ .boolean = true }),
            .op_false => try self.stack.push(gpa, .{ .boolean = false }),
            .op_equal => {
                const b = self.stack.store.pop() orelse return error.UndefinedValue;
                const a = self.stack.store.pop() orelse return error.UndefinedValue;
                try self.stack.push(gpa, .{ .boolean = a.isEqual(b) });
            },
            .op_greater => try self.binaryOperation(gpa, ctx, .op_greater),
            .op_less => try self.binaryOperation(gpa, ctx, .op_less),
            .op_add => try self.binaryOperation(gpa, ctx, .op_add),
            .op_subtract => try self.binaryOperation(gpa, ctx, .op_subtract),
            .op_multiply => try self.binaryOperation(gpa, ctx, .op_multiply),
            .op_divide => try self.binaryOperation(gpa, ctx, .op_divide),
            .op_not => {
                if (self.stack.len() == 0) return error.UndefinedValue;
                const last = self.stack.peek();
                self.stack.set(self.stack.len() - 1, .{ .boolean = last.isFalsey() });
            },
            .op_negate => {
                if (self.stack.len() == 0) return error.UndefinedValue;

                const last = self.stack.peek();
                if (last != .number) {
                    try self.runtimeError(ctx.stream.err, "Operand must be a number", .{});
                    return error.OperandMustBeNumber;
                }
                self.stack.set(self.stack.len() - 1, .{ .number = -(last.number) });
            },
            .op_return => {
                const last = self.stack.pop() orelse return error.UndefinedValue;
                return try last.print(ctx.stream.out);
            },
            else => return error.InvalidOperation,
        }
    }
}

fn readByte(self: *VM) u8 {
    const ip = self.chunk.codes.items[self.ip];
    self.ip += 1;
    return ip;
}

fn readConstant(self: *VM) Chunk.Value {
    const index: usize = @intCast(self.readByte());
    return self.chunk.constants.items[index];
}

fn readConstantLong(self: *VM) Chunk.Value {
    const index = self.chunk.getConstantLong(self.ip);
    self.ip += 3;
    return self.chunk.constants.items[@intCast(index)];
}

fn binaryOperation(self: *VM, gpa: Allocator, ctx: *Context, code: Chunk.Code) !void {
    const b = self.stack.pop() orelse return error.UndefinedValue;
    if (!b.isNumber()) {
        try self.runtimeError(ctx.stream.err, "Operand must be a number.", .{});
        return error.OperandMustBeNumber;
    }

    const a = self.stack.pop() orelse return error.UndefinedValue;
    if (!a.isNumber()) {
        try self.runtimeError(ctx.stream.err, "Operand must be a number.", .{});
        return error.OperandMustBeNumber;
    }

    const result: Chunk.Value = switch (code) {
        .op_add => .{ .number = a.number + b.number },
        .op_subtract => .{ .number = a.number - b.number },
        .op_multiply => .{ .number = a.number * b.number },
        .op_divide => .{ .number = a.number / b.number },
        .op_greater => .{ .boolean = a.number > b.number },
        .op_less => .{ .boolean = a.number < b.number },
        else => {
            try self.runtimeError(ctx.stream.err, "Invalid Binary Operation", .{});
            return error.InvalidBinaryOperation;
        },
    };
    try self.stack.push(gpa, result);
}

// For debugging purpose.
fn dumpStack(self: *VM, writer: *Io.Writer) !void {
    try writer.writeAll("          ");
    for (self.stack.slice()) |value| {
        try writer.print("[{}]", .{value});
    }
    try writer.writeByte('\n');
}

fn dumpInstruction(self: *VM, writer: *Io.Writer, offset: usize) !void {
    try self.chunk.disassembleInstruction(writer, offset);
}

fn runtimeError(self: *VM, writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.writeByte('\n');

    const line = self.chunk.getLine(self.ip) orelse 0;
    try writer.print("[line {}] in script.\n", .{line});
}

// A Vitual Machine Challenges
//
// 1. What bytecode instruction sequences would you generate for the following expressions:
//    -> (1 * 2 + 3) => (3, 2, 1, multiply, add)
//    -> (1 + 2 * 3) => (3, 2, multiply, 1, add)
//    -> (3 - 2 - 1) => (3, 2, subtract, 1, subtract)
//    -> (1 + 2 * 3 - 4 / -5) => (3, 2, multiply, 1, add, 4, 5, negate, divide, subtract)

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const Chunk = @import("Chunk.zig");
const Context = @import("Context.zig");
const compiler = @import("compiler.zig");
const Compiler = compiler.Compiler;
