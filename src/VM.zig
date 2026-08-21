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

        pub fn push(self: *Self, gpa: Allocator, value: T) Allocator.Error!void {
            try self.store.append(gpa, value);
        }

        pub fn pop(self: *Self) ?T {
            return self.store.pop();
        }

        pub fn slice(self: Self) []T {
            if (self.last()) |index| {
                return self.store[0..index];
            }
            return &.{};
        }
    };
}

const VMError = Error || Io.Writer.Error;

const VM = @This();
// It borrows the memory.
chunk: *Chunk,
ip: usize,
stack: Stack(Chunk.Value),

pub const Error = error{
    compile_error,
    runtime_error,
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

pub fn interpret(self: *VM, chunk: *Chunk) Error!void {
    // It borrows the memory.
    self.chunk = chunk;
    self.ip = 0;
}

pub fn run(self: *VM, gpa: Allocator, ctx: *Context) VMError!void {
    while (self.ip < self.chunk.codes.items.len) {
        // Uncomment for debugging.
        // try self.dumpStack(ctx.stream.err);
        // try self.dumpInstruction(ctx.stream.err, self.ip);

        const op_code: Chunk.OpCode = @enumFromInt(self.readByte());
        switch (op_code) {
            .constant => {
                const constant = self.readConstant();
                self.stack.push(gpa, constant) catch return VMError.runtime_error;
            },
            .constant_long => {
                const constant = self.readConstantLong();
                self.stack.push(gpa, constant) catch return VMError.runtime_error;
            },

            .add => self.binaryOperation(gpa, .add) catch return Error.runtime_error,
            .subtract => self.binaryOperation(gpa, .subtract) catch return Error.runtime_error,
            .multiply => self.binaryOperation(gpa, .multiply) catch return Error.runtime_error,
            .divide => self.binaryOperation(gpa, .divide) catch return Error.runtime_error,

            .negate => {
                if (self.stack.store.items.len > 0) {
                    const last = self.stack.store.items.len - 1;
                    self.stack.store.items[last] = -(self.stack.store.items[last]);
                } else {
                    return VMError.runtime_error;
                }
            },

            .@"return" => {
                if (self.stack.pop()) |value| {
                    return try ctx.stream.out.print("{}\n", .{value});
                }
                return VMError.runtime_error;
            },
            _ => return Error.runtime_error,
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

fn binaryOperation(self: *VM, gpa: Allocator, code: Chunk.OpCode) !void {
    const b = self.stack.pop() orelse return error.UndefinedValue;
    const a = self.stack.pop() orelse return error.UndefinedValue;

    switch (code) {
        .add => try self.stack.push(gpa, a + b),
        .subtract => try self.stack.push(gpa, a - b),
        .multiply => try self.stack.push(gpa, a * b),
        .divide => try self.stack.push(gpa, a / b),
        else => return error.InvalidBinaryOperation,
    }
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

test "VM" {
    const gpa = testing.allocator;

    var chunk: Chunk = .empty;
    defer chunk.deinit(gpa);

    var constant_index = try chunk.addValue(gpa, 1.2);
    try chunk.writeConstant(gpa, constant_index, 123);

    constant_index = try chunk.addValue(gpa, 3.4);
    try chunk.writeConstant(gpa, constant_index, 123);

    try chunk.writeChunk(gpa, .add, 123);

    constant_index = try chunk.addValue(gpa, 5.6);
    try chunk.writeConstant(gpa, constant_index, 123);

    try chunk.writeChunk(gpa, .divide, 123);

    try chunk.writeChunk(gpa, .negate, 123);
    try chunk.writeChunk(gpa, .@"return", 123);

    try chunk.writeChunk(gpa, .@"return", 123);

    var writer: Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();

    var ctx: Context = .init(undefined, .{ .out = &writer.writer });

    var vm: VM = .empty;
    defer vm.deinit(gpa);

    try vm.interpret(&chunk);
    try vm.run(gpa, &ctx);

    // Uncomment to print debugging.
    // std.debug.print("{s}", .{writer.written()});
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
