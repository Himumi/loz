const VM = @This();

allocator: Allocator,
// It borrows the memory.
chunk: *Chunk,
ip: usize,
stack: Stack,
// A linked list for runtime's Objects.
objects: ?*Object,

globals: std.ArrayList(Value),
strings: Strings,

const VMError =
    RuntimeError ||
    Compiler.Error ||
    Io.Writer.Error ||
    Allocator.Error;

pub const RuntimeError = error{
    EmptyStack,
    InvalidOperation,
    InvalidBinaryOperation,
    UndefinedValue,
    OperandMustBeNumber,
};

pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!VM {
    return .{
        .allocator = gpa,
        .chunk = undefined,
        .ip = 0,
        .stack = try .initCapacity(gpa, capacity),
        .objects = null,
        .strings = .init(gpa),
        .globals = .empty,
    };
}

pub fn deinit(self: *VM) void {
    self.globals.deinit(self.allocator);
    self.stack.deinit(self.allocator);
    self.strings.deinit();

    var object_ptr = self.objects;
    while (object_ptr) |object| {
        object_ptr = object.next;
        object.deinit(self.allocator);
    }
}

pub fn interpret(self: *VM, ctx: *Context, source: [:0]const u8) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    // Chunk is a constant memory after compilation.
    var chunk = try compiler.compile(arena, ctx, &self.strings, source);

    // It borrows the memory.
    self.chunk = &chunk;
    self.ip = 0;

    try self.run(ctx);
}

pub fn run(self: *VM, ctx: *Context) VMError!void {
    const gpa = self.allocator;
    while (self.ip < self.chunk.codes.len) {
        // Uncomment for debugging.
        // try self.dumpStack(ctx.stream.err);
        // try self.chunk.disassembleInstruction(ctx.stream.err, self.ip);

        const code: Chunk.Code = @enumFromInt(self.readByte());
        switch (code) {
            .op_constant => {
                try self.stack.push(gpa, self.readConstant());
            },
            .op_constant_long => {
                try self.stack.push(gpa, self.readConstantLong());
            },
            .op_nil => {
                try self.stack.push(gpa, .nil);
            },
            .op_true => {
                try self.stack.push(gpa, .{ .boolean = true });
            },
            .op_false => {
                try self.stack.push(gpa, .{ .boolean = false });
            },
            .op_equal => {
                const right = self.stack.store.pop() orelse return error.UndefinedValue;
                const left = self.stack.store.pop() orelse return error.UndefinedValue;
                try self.stack.push(gpa, .{ .boolean = left.isEqual(right) });
            },
            .op_greater => {
                try self.binaryOperation(ctx, .op_greater);
            },
            .op_less => {
                try self.binaryOperation(ctx, .op_less);
            },
            .op_add => {
                try self.addOperation(ctx);
            },
            .op_subtract => {
                try self.binaryOperation(ctx, .op_subtract);
            },
            .op_multiply => {
                try self.binaryOperation(ctx, .op_multiply);
            },
            .op_divide => {
                try self.binaryOperation(ctx, .op_divide);
            },
            .op_not => {
                try self.notOperation();
            },
            .op_negate => {
                try self.negateOperation(ctx);
            },
            .op_return => {
                // Exit interpreter
            },
            .op_jump => {
                const offset = self.readShort();
                self.ip += offset;
            },
            .op_jump_if_false => {
                const offset = self.readShort();
                if (self.stack.peek().isFalsey()) {
                    self.ip += offset;
                }
            },
            .op_loop => {
                const offset = self.readShort();
                self.ip -= offset;
            },
            .op_print => {
                const value = self.stack.pop() orelse return error.UndefinedValue;
                try value.print(ctx.stream.out);
            },
            .op_pop => {
                _ = self.stack.pop() orelse return error.UndefinedValue;
            },
            .op_define_global => {
                try self.defineVariable(self.readIndex());
            },
            .op_define_global_long => {
                try self.defineVariable(self.readIndexLong());
            },
            .op_get_global => {
                const index = self.readIndex();
                try self.getVariable(ctx, index);
            },
            .op_get_global_long => {
                const index = self.readIndexLong();
                try self.getVariable(ctx, index);
            },
            .op_set_global => {
                const index = self.readIndex();
                try self.setVariable(ctx, index);
            },
            .op_set_global_long => {
                const index = self.readIndexLong();
                try self.setVariable(ctx, index);
            },
            .op_get_local => {
                const index = self.readIndex();
                const value = self.stack.get(index) orelse return error.UndefinedValue;
                try self.stack.push(gpa, value);
            },
            .op_get_local_long => {
                const index = self.readIndexLong();
                const value = self.stack.get(index) orelse return error.UndefinedValue;
                try self.stack.push(gpa, value);
            },
            .op_set_local => {
                const index = self.readIndex();
                const value = self.stack.peek();
                self.stack.set(index, value);
            },
            .op_set_local_long => {
                const index = self.readIndexLong();
                const value = self.stack.peek();
                self.stack.set(index, value);
            },
            else => return error.InvalidOperation,
        }
    }
}

fn readByte(self: *VM) u8 {
    const ip = self.chunk.codes[self.ip];
    self.ip += 1;
    return ip;
}

fn readConstant(self: *VM) Value {
    const index: usize = @intCast(self.readByte());
    return self.chunk.constants[index];
}

fn readConstantLong(self: *VM) Value {
    const index = Chunk.getConstantLong(self.chunk.codes, self.ip);
    self.ip += 3;
    return self.chunk.constants[@intCast(index)];
}

fn readShort(self: *VM) u32 {
    const bytes = self.chunk.codes[self.ip .. self.ip + 2];
    const index = mem.readInt(u16, bytes[0..2], .big);
    self.ip += 2;
    return index;
}

fn readIndex(self: *VM) u32 {
    return @intCast(self.readByte());
}

fn readIndexLong(self: *VM) u32 {
    const index = Chunk.getConstantLong(self.chunk.codes, self.ip);
    self.ip += 3;
    return index;
}

fn addOperation(self: *VM, ctx: *Context) !void {
    if (self.stack.len() < 2) return error.UndefinedValue;

    const last = self.stack.last() orelse unreachable;
    const right = self.stack.get(last) orelse unreachable;
    const left = self.stack.get(last - 1) orelse unreachable;

    if (left.isString()) {
        try self.concatenate();
    } else if (left.isNumber() and right.isNumber()) {
        try self.binaryOperation(ctx, .op_add);
    } else {
        try self.runtimeError(ctx.stream.err, "Invalid Operands Type.", .{});
        return error.InvalidBinaryOperation;
    }
}

fn binaryOperation(self: *VM, ctx: *Context, code: Chunk.Code) !void {
    const right = self.stack.pop() orelse return error.UndefinedValue;
    const left = self.stack.pop() orelse return error.UndefinedValue;

    if (!left.isSame(right) or !left.isNumber()) {
        try self.runtimeError(ctx.stream.err, "Operand must be a number.", .{});
        return error.OperandMustBeNumber;
    }

    const result: Value = switch (code) {
        .op_add => .{ .number = left.number + right.number },
        .op_subtract => .{ .number = left.number - right.number },
        .op_multiply => .{ .number = left.number * right.number },
        .op_divide => .{ .number = left.number / right.number },
        .op_greater => .{ .boolean = left.number > right.number },
        .op_less => .{ .boolean = left.number < right.number },
        else => {
            try self.runtimeError(ctx.stream.err, "Invalid Binary Operation", .{});
            return error.InvalidBinaryOperation;
        },
    };
    try self.stack.push(self.allocator, result);
}

fn notOperation(self: *VM) !void {
    if (self.stack.len() == 0) return error.UndefinedValue;

    const index = self.stack.last() orelse unreachable;
    const value = self.stack.peek();
    self.stack.set(index, .{ .boolean = value.isFalsey() });
}

fn negateOperation(self: *VM, ctx: *Context) !void {
    if (self.stack.len() == 0) return error.UndefinedValue;

    const index = self.stack.last() orelse unreachable;
    const value = self.stack.peek();
    if (value != .number) {
        try self.runtimeError(ctx.stream.err, "Operand must be a number", .{});
        return error.OperandMustBeNumber;
    }
    self.stack.set(index, .{ .number = -(value.number) });
}

fn defineVariable(self: *VM, index: u32) !void {
    if (index >= self.globals.items.len) {
        const count = (index + 1) - self.globals.items.len;
        try self.globals.appendNTimes(self.allocator, .nil, count);
    }
    self.globals.items[@intCast(index)] = self.stack.peek();
    _ = self.stack.pop() orelse return error.UndefinedValue;
}

fn getVariable(self: *VM, ctx: *Context, index: u32) !void {
    if (index >= self.globals.items.len) {
        try self.runtimeError(ctx.stream.err, "Undefined Variable.", .{});
        return error.UndefinedValue;
    }
    try self.stack.push(self.allocator, self.globals.items[@intCast(index)]);
}

fn setVariable(self: *VM, ctx: *Context, index: u32) !void {
    if (index >= self.globals.items.len) {
        try self.runtimeError(ctx.stream.err, "Undefined Variable.", .{});
        return error.UndefinedValue;
    }
    self.globals.items[@intCast(index)] = self.stack.peek();
}

fn concatenate(self: *VM) !void {
    // It does not own the ownership.
    const right = self.stack.pop() orelse return error.UndefinedValue;
    // It does not own the ownership.
    const left = self.stack.pop() orelse return error.UndefinedValue;

    if (!left.isString()) return error.InvalidBinaryOperation;
    const left_str = left.object.getParentPtr(String);

    const concat = try concatToString(self.allocator, left_str, right);
    errdefer self.allocator.free(concat);

    // Transfer the concat memory.
    const head = try self.putToStrings(concat);
    try self.stack.push(self.allocator, .{ .object = head });
}

fn concatToString(gpa: Allocator, str: *String, value: Value) ![]const u8 {
    if (value.isString()) {
        const value_str = value.object.getParentPtr(String);
        return try mem.concat(gpa, u8, &.{ str.slice(), value_str.slice() });
    }
    if (value.isNumber()) {
        return try fmt.allocPrint(gpa, "{s}{d}", .{ str.slice(), value.number });
    }
    if (value.isBoolean()) {
        return try fmt.allocPrint(gpa, "{s}{}", .{ str.slice(), value.boolean });
    }
    if (value.isNil()) {
        return try fmt.allocPrint(gpa, "{s}nil", .{str.slice()});
    }
    return error.InvalidBinaryOperation;
}

/// Take the concat memory and return String's head(Object) pointer.
fn putToStrings(self: *VM, concat: []const u8) !*Object {
    const gop = try self.strings.getOrPut(concat);
    if (gop.found_existing) {
        // It has found a same string.
        self.allocator.free(concat);
    } else {
        // NOTE: Use imperative way for readability.
        const string_object = try self.allocator.create(String);
        errdefer self.allocator.destroy(string_object);

        string_object.* = .init(.owned, concat, Object{
            .kind = .string,
            .next = self.objects,
        });
        // Add the new object to VM's Objects to track the memory.
        self.objects = &string_object.head;
        // Add the new object to VM's Strings.
        gop.value_ptr.* = string_object;
    }
    return &gop.value_ptr.*.head;
}

fn runtimeError(self: *VM, writer: *Io.Writer, comptime format: []const u8, args: anytype) !void {
    try writer.print(format, args);
    try writer.writeByte('\n');

    const line = Chunk.getLine(self.chunk.lines, self.ip) orelse 0;
    try writer.print("[line {}] in script.\n", .{line});
}

// A Vitual Machine Challenges
//
// 1. What bytecode instruction sequences would you generate for the following expressions:
//    -> (1 * 2 + 3) => (3, 2, 1, multiply, add)
//    -> (1 + 2 * 3) => (3, 2, multiply, 1, add)
//    -> (3 - 2 - 1) => (3, 2, subtract, 1, subtract)
//    -> (1 + 2 * 3 - 4 / -5) => (3, 2, multiply, 1, add, 4, 5, negate, divide, subtract)

test "VM" {
    try testCompile("print (1 + 2) * 3;", "9");
    try testCompile("print 1 + 2 * 3;", "7");
    try testCompile("print 10 - 5 / 1;", "5");
    try testCompile("print true;", "true");
    try testCompile("print false;", "false");
    try testCompile("print nil;", "nil");
    try testCompile("print !true;", "false");
    try testCompile("print !false;", "true");
    try testCompile("print !nil;", "true");
    try testCompile("print !10;", "false");
    try testCompile("print 10 == 10;", "true");
    try testCompile("print 10 != 10;", "false");
    try testCompile("print 10 < 10;", "false");
    try testCompile("print 10 <= 10;", "true");
    try testCompile("print 10 > 10;", "false");
    try testCompile("print 10 >= 10;", "true");
    try testCompile("print !(5 - 4 > 3 * 2 == !nil);", "true");
    try testCompile(
        \\ print "hello";
    , "hello");

    try testCompile(
        \\ print "hello, " + "world!";
    , "hello, world!");

    try testCompile(
        \\ print "hello, " + 10;
    , "hello, 10");

    try testCompile(
        \\ print "hello, " + true;
    , "hello, true");

    try testCompile(
        \\ print "hello, " + false;
    , "hello, false");

    try testCompile(
        \\ print "hello, " + nil;
    , "hello, nil");

    try testCompile(
        \\ print "hello" == "hello";
    , "true");
    try testCompile(
        \\ print "hello" == "world";
    , "false");

    try testCompile(
        \\ var name = "John";
        \\ print "Hello " + name;
    , "Hello John");

    try testCompile(
        \\ var name;
        \\ name = "John";
        \\ print name;
    , "John");

    try testCompile(
        \\ var breakfast = "beignets";
        \\ var beverage = "cafe au lait";
        \\ breakfast = "beignets with " + beverage;
        \\
        \\ print breakfast;
    , "beignets with cafe au lait");

    try testCompile(
        \\ var name = "John";
        \\ { name = "lua"; }
        \\ print name;
    , "lua");

    try testCompile(
        \\ if (false) print "true"; else print "false";
    , "false");

    try testCompile("print true and true;", "true");
    try testCompile("print false or true;", "true");

    try testCompile(
        \\ var i = 0;
        \\ while (i < 2) {
        \\   print i;
        \\   i = i + 1;
        \\ }
    , "01");

    try testCompile(
        \\ for (var i = 0; i < 2; i = i + 1) {
        \\   print i;
        \\ }
    , "01");

    try testCompile(
        \\ var i = 0;
        \\ while (i < 2) {
        \\   print i;
        \\   i = i + 1;
        \\   break;
        \\ }
    , "0");

    try testCompile(
        \\ var i = 0;
        \\ while (i < 2) {
        \\   if (i == 0) {
        \\     i = i + 1;
        \\     continue;
        \\   }
        \\   print i;
        \\   i = i + 1;
        \\ }
    , "1");

    try testCompile(
        \\ for (var i = 0; i < 2; i = i + 1) {
        \\   print i;
        \\   if (i == 0) break;
        \\ }
    , "0");

    try testCompile(
        \\ for (var i = 0; i < 2; i = i + 1) {
        \\   if (i == 0) continue;
        \\   print i;
        \\ }
    , "1");
}

fn testCompile(source: [:0]const u8, expected: []const u8) !void {
    const gpa = testing.allocator;

    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    var ctx: Context = .init(undefined, .{ .out = &stream.writer, .err = &stream.writer });

    var vm: VM = try .init(gpa, 256);
    defer vm.deinit();

    try vm.interpret(&ctx, source);
    try testing.expectEqualSlices(u8, expected, stream.written());
}

const std = @import("std");
const fmt = std.fmt;
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
const Strings = utils.Strings;
const Object = values.Object;
const String = values.String;
const Value = values.Value;
