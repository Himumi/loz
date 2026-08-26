/// Table does not own the memory.
pub const Table = std.StringHashMap(*String);

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
        if (self.last()) |index| {
            return self.store[0..index];
        }
        return &.{};
    }
};

const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const Io = std.Io;

const values = @import("values.zig");
const String = values.String;
const Value = values.Value;
