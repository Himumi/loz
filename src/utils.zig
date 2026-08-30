/// Strings does not own the memory.
pub const Strings = std.StringHashMap(*String);

pub const Stack = struct {
    /// Store borrowed memory from Chunk or VM's Objects.
    store: std.ArrayList(Value),

    pub fn initCapacity(gpa: Allocator, capacity: usize) Allocator.Error!Stack {
        return .{ .store = try .initCapacity(gpa, capacity) };
    }

    pub const empty: Stack = .{ .store = .empty };

    pub fn deinit(self: *Stack, gpa: Allocator) void {
        self.store.deinit(gpa);
    }

    pub fn reset(self: *Stack) void {
        self.store.items.len = 0;
    }

    // For debugging purpose.
    fn dump(self: *Stack, writer: *Io.Writer) !void {
        try writer.writeAll("          ");
        for (self.stack.slice()) |value| {
            try writer.print("[{}]", .{value});
        }
        try writer.writeByte('\n');
    }

    pub fn last(self: Stack) ?usize {
        if (self.store.items.len > 0) {
            return self.store.items.len - 1;
        }
        return null;
    }

    pub fn len(self: Stack) usize {
        return self.store.items.len;
    }

    pub fn push(self: *Stack, gpa: Allocator, value: Value) Allocator.Error!void {
        try self.store.append(gpa, value);
    }

    pub fn pop(self: *Stack) ?Value {
        return self.store.pop();
    }

    pub fn peek(self: Stack) Value {
        return self.store.items[self.store.items.len - 1];
    }

    pub fn get(self: Stack, index: usize) ?Value {
        if (self.len() == 0 or index == self.len()) return null;
        return self.store.items[index];
    }

    pub fn set(self: *Stack, index: usize, value: Value) void {
        self.store.items[index] = value;
    }

    pub fn slice(self: Stack) []Value {
        return self.store.items;
    }
};

pub const Scope = struct {
    locals: [local_max]Local,
    count: u32,
    depth: u32,

    pub const local_max: usize = values.max_u16;
    pub const Local = struct {
        token: Token,
        depth: ?u32,
    };

    pub const empty: Scope = .{
        .locals = undefined,
        .count = 0,
        .depth = 0,
    };

    pub fn add(self: *Scope, token: Token) error{TooManyLocalVariables}!void {
        if (self.count == local_max) {
            return error.TooManyLocalVariables;
        }

        self.locals[self.count] = .{
            .token = token,
            .depth = null,
        };
        self.count += 1;
    }

    pub fn mark(self: *Scope) void {
        if (self.count > 0) {
            self.locals[self.count - 1].depth = self.depth;
        }
    }

    pub fn begin(self: *Scope) void {
        self.depth += 1;
    }

    pub fn end(self: *Scope) void {
        self.depth -= 1;
    }
};

pub fn writeU16(index: u32) [2]u8 {
    const truncated: u16 = @truncate(index);

    var bytes: [2]u8 = undefined;
    mem.writeInt(u16, &bytes, truncated, .big);

    return bytes;
}

pub fn writeU24(index: u32) [3]u8 {
    const truncated: u24 = @truncate(index);

    var bytes: [3]u8 = undefined;
    mem.writeInt(u24, &bytes, truncated, .big);

    return bytes;
}

const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const Io = std.Io;

const Token = @import("tokenizer.zig").Token;
const values = @import("values.zig");
const String = values.String;
const Value = values.Value;
