const VMError = Error || Io.Writer.Error || Allocator.Error;

const VM = @This();
// It borrows the memory.
chunk: *Chunk,
ip: usize,
stack: Stack,
strings: Strings,
// A linked list for runtime's Objects.
objects: ?*Object,

pub const Error = (RuntimeError || Compiler.Error);

pub const RuntimeError = error{
    EmptyStack,
    InvalidOperation,
    InvalidBinaryOperation,
    UndefinedValue,
    OperandMustBeNumber,
};

pub fn initCapacity(gpa: Allocator, capacity: usize) Allocator.Error!VM {
    return .{
        .chunk = undefined,
        .ip = 0,
        .stack = try .initCapacity(gpa, capacity),
        .strings = .init(gpa),
        .objects = null,
    };
}

pub fn deinit(self: *VM, gpa: Allocator) void {
    self.stack.deinit(gpa);
    self.strings.deinit();

    var object_ptr = self.objects;
    while (object_ptr) |object| {
        object_ptr = object.next;
        object.deinit(gpa);
    }
}

pub fn interpret(self: *VM, gpa: Allocator, ctx: *Context, source: [:0]const u8) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    // Chunk is a constant memory after compilation.
    var chunk = try compiler.compile(arena, ctx, &self.strings, source);

    // It borrows the memory.
    self.chunk = &chunk;
    self.ip = 0;

    try self.run(gpa, ctx);
}

pub fn run(self: *VM, gpa: Allocator, ctx: *Context) VMError!void {
    while (self.ip < self.chunk.codes.items.len) {
        // Uncomment for debugging.
        // try self.dumpStack(ctx.stream.err);
        // try self.chunk.disassembleInstruction(ctx.stream.err, self.ip);

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
            .op_add => {
                const b = self.stack.get(self.stack.len() - 1) orelse return error.UndefinedValue;
                const a = self.stack.get(self.stack.len() - 2) orelse return error.UndefinedValue;
                if (b.isString() and a.isString()) {
                    try self.concatenate(gpa);
                } else if (b.isNumber() and a.isNumber()) {
                    try self.binaryOperation(gpa, ctx, .op_add);
                } else {
                    try self.runtimeError(ctx.stream.err, "Invalid Operands Type.", .{});
                    return error.InvalidBinaryOperation;
                }
            },
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

fn readConstant(self: *VM) Value {
    const index: usize = @intCast(self.readByte());
    return self.chunk.constants.items[index];
}

fn readConstantLong(self: *VM) Value {
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

    const result: Value = switch (code) {
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

fn concatenate(self: *VM, gpa: Allocator) !void {
    // It does not own the ownership.
    const b = self.stack.pop() orelse return error.UndefinedValue;
    // It does not own the ownership.
    const a = self.stack.pop() orelse return error.UndefinedValue;

    if (b.isString() and a.isString()) {
        const a_str = a.object.getParentPtr(String);
        const b_str = b.object.getParentPtr(String);

        const concat = try mem.concat(gpa, u8, &.{ a_str.slice(), b_str.slice() });
        errdefer gpa.free(concat);

        const gop = try self.strings.getOrPut(concat);
        if (gop.found_existing) {
            // It has found a same string.
            gpa.free(concat);
        } else {
            // NOTE: Use imperative way for readability.
            const string_object = try gpa.create(String);
            errdefer gpa.destroy(string_object);

            string_object.* = .init(.owned, concat, Object{
                .kind = .string,
                .next = self.objects,
            });
            // Add the new object to VM's Objects to track the memory.
            self.objects = &string_object.head;
            // Add the new object to VM's Strings.
            gop.value_ptr.* = string_object;
        }

        const head = &gop.value_ptr.*.head;
        try self.stack.push(gpa, .{ .object = head });
    } else {
        return error.InvalidBinaryOperation;
    }
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

const compiler = @import("compiler.zig");
const utils = @import("utils.zig");
const values = @import("values.zig");
const Chunk = @import("Chunk.zig");
const Context = @import("Context.zig");
const Compiler = compiler.Compiler;
const Stack = utils.Stack;
const Strings = utils.Table;
const Object = values.Object;
const String = values.String;
const Value = values.Value;
