const EnvFlat = @This();

/// It owns the objects memory.
values: ArrayList(ast.Object),
/// Format: |string -> |hello.
keys: ArrayList(u8), // format: |string -> |hello

pub const Error = error{
    InvalidLocation,
    OutOfBound,
    UndefinedVariable,
};

pub const empty: EnvFlat = .{
    .keys = .empty,
    .values = .empty,
};

pub fn deinit(self: *EnvFlat, gpa: Allocator) void {
    for (self.values.items) |value| {
        value.deinit(gpa);
    }
    self.values.deinit(gpa);
    self.keys.deinit(gpa);
}

pub fn create(gpa: Allocator) Allocator.Error!*EnvFlat {
    const env = try gpa.create(EnvFlat);
    env.* = .empty;
    return env;
}

pub fn destroy(self: *EnvFlat, gpa: Allocator) void {
    self.deinit(gpa);
    gpa.destroy(self);
}

pub fn len(self: EnvFlat) usize {
    return self.values.items.len;
}

/// Take the value's ownership but duplicate the key.
pub fn define(self: *EnvFlat, gpa: Allocator, name: []const u8, value: ast.Object) !void {
    try self.values.append(gpa, value);
    try self.keys.print(gpa, "|{s}", .{name});
}

test "define" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const key = "hello";
    const hello: ast.Object = .{ .string = try gpa.dupe(u8, "hello") };
    errdefer hello.deinit(gpa);

    try env.define(gpa, key, hello);

    try testing.expectEqual(env.values.items.len, 1);
    try testing.expectEqualSlices(u8, hello.string, env.values.items[0].string);
    try testing.expectEqualSlices(u8, "|hello", env.keys.items);
}

/// Take the values' ownership but duplicate the keys.
pub fn append(self: *EnvFlat, gpa: Allocator, local: Local) !void {
    try self.keys.appendSlice(gpa, local.keys);
    try self.values.appendSlice(gpa, local.values);
}

test "append" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const closure: Local = .{
        .keys = "|hello|konnichiwa",
        .values = &.{
            .{ .string = try gpa.dupe(u8, "hello") },
            .{ .string = try gpa.dupe(u8, "konnichiwa") },
        },
    };
    errdefer for (closure.values) |value| value.deinit(gpa);

    try env.append(gpa, closure);

    try testing.expectEqual(2, env.values.items.len);
    try testing.expectEqualSlices(u8, closure.keys, env.keys.items);
    for (env.values.items, closure.values) |got, want| {
        try testing.expectEqualSlices(u8, want.string, got.string);
    }
}

/// Look up the existing data from behind.
/// It will take the value's ownership and duplicate the key.
pub fn assign(self: *EnvFlat, gpa: Allocator, name: []const u8, value: ast.Object) !void {
    var it = self.keyIterator();
    while (it.next()) |result| {
        // Swap the existing value.
        if (mem.eql(u8, result.key, name)) {
            self.values.items[result.key_index].deinit(gpa);
            self.values.items[result.key_index] = value;
            return;
        }
    }
    return error.UndefinedVariable;
}

test "assign" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const key = "greet";
    const hello: ast.Object = .{ .string = try gpa.dupe(u8, "hello") };
    errdefer hello.deinit(gpa);

    try env.define(gpa, key, hello);
    try testing.expectEqual(1, env.len());
    try testing.expectEqualSlices(u8, "hello", env.values.items[0].string);

    const konnichiwa: ast.Object = .{ .string = try gpa.dupe(u8, "konnichiwa") };
    errdefer konnichiwa.deinit(gpa);

    try env.assign(gpa, key, konnichiwa);
    try testing.expectEqual(1, env.len());
    try testing.expectEqualSlices(u8, "konnichiwa", env.values.items[0].string);
}

/// Use to replace the invalid memory with the new memory.
/// You have to know when the old memory become invalid.
/// for instance: after transfered the memory to a different lifetime.
pub fn replace(
    self: *EnvFlat,
    closure: ast.Closure,
    new_local: Local,
) error{ InvalidLocation, OutOfBound }!void {
    if (closure.keys.end > self.keys.items.len or closure.values.end > self.values.items.len) {
        return error.OutOfBound;
    }
    const keys = self.keys.items[closure.keys.start..closure.keys.end];
    if (!mem.eql(u8, keys, new_local.keys)) {
        return error.InvalidLocation;
    }
    @memmove(keys, new_local.keys);
    @memmove(self.values.items[closure.values.start..closure.values.end], new_local.values);
}

test "replace" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const old_local: Local = .{
        .keys = "|first|second",
        .values = &.{
            .{ .number = 123 },
            .{ .number = 1234 },
        },
    };

    try env.append(gpa, old_local);
    try testing.expectEqual(2, env.len());
    try testing.expectEqualSlices(u8, old_local.keys, env.keys.items);
    var it = env.keyIterator();
    try testEnvFlat(&env, "second", .{ .number = 1234 }, it.next());
    try testEnvFlat(&env, "first", .{ .number = 123 }, it.next());

    const closure: ast.Closure = .{
        .keys = .{ .start = 0, .end = old_local.keys.len },
        .values = .{ .start = 0, .end = old_local.values.len },
    };

    const new_local: Local = .{
        .keys = "|first|second",
        .values = &.{
            .{ .string = try gpa.dupe(u8, "first") },
            .{ .string = try gpa.dupe(u8, "second") },
        },
    };
    try env.replace(closure, new_local);
    try testing.expectEqual(2, env.len());
    try testing.expectEqualSlices(u8, old_local.keys, env.keys.items);
    it = env.keyIterator();
    try testEnvFlat(&env, "second", .{ .string = "second" }, it.next());
    try testEnvFlat(&env, "first", .{ .string = "first" }, it.next());
}

/// Needs to duplicate if it will be used in different lifetimes.
pub fn get(self: *EnvFlat, name: []const u8) !ast.Object {
    var it = self.keyIterator();
    while (it.next()) |result| {
        if (mem.eql(u8, result.key, name)) {
            return self.values.items[result.key_index];
        }
    }
    return error.UndefinedVariable;
}

test "get" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const key = "greet";
    const hello: ast.Object = .{ .string = try gpa.dupe(u8, "hello") };
    errdefer hello.deinit(gpa);

    try env.define(gpa, key, hello);
    try testing.expectEqual(1, env.len());
    try testing.expectEqualSlices(u8, "hello", env.values.items[0].string);

    const first = try env.get("greet"); // It belongs to the Env.
    try testing.expectEqual(1, env.len());
    try testing.expectEqualSlices(u8, "hello", first.string);
}

/// Take the keys and values ownership from offset until the last.
pub fn steal(self: *EnvFlat, gpa: Allocator, offset: usize) !Local {
    var it = self.keyIterator();
    while (it.next()) |result| {
        if (result.key_index != offset) continue;

        const keys = try gpa.dupe(u8, self.keys.items[result.index..]);
        errdefer gpa.free(keys);
        const values = try gpa.dupe(ast.Object, self.values.items[result.key_index..]);

        self.keys.items.len = result.index;
        self.values.items.len = result.key_index;

        return .{
            .keys = keys,
            .values = values,
        };
    }
    return .empty;
}

test "steal" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const local: Local = .{
        .keys = "|hello|konnichiwa",
        .values = &.{
            .{ .string = try gpa.dupe(u8, "hello") },
            .{ .string = try gpa.dupe(u8, "konnichiwa") },
        },
    };
    errdefer for (local.values) |value| value.deinit(gpa);

    try env.append(gpa, local);

    try testing.expectEqual(2, env.values.items.len);
    try testing.expectEqualSlices(u8, local.keys, env.keys.items);
    for (env.values.items, local.values) |got, want| {
        try testing.expectEqualSlices(u8, want.string, got.string);
    }

    // Steal the memory from env.
    const stolen_local = try env.steal(gpa, 0);
    defer {
        for (stolen_local.values) |value| {
            value.deinit(gpa);
        }
        stolen_local.deinit(gpa);
    }
}

/// Slice the keys and values and takes the contents' ownership.
pub fn slice(self: *EnvFlat, loc: ast.Closure) !Local {
    if (loc.keys.end > self.keys.items.len or loc.values.end > self.values.items.len) {
        return error.OutOfBound;
    }
    return .{
        .keys = self.keys.items[loc.keys.start..loc.keys.end],
        .values = self.values.items[loc.values.start..loc.values.end],
    };
}

/// Temporary place to store the local env keys and values.
pub const Local = struct {
    // It owns the memory.
    keys: []const u8,
    // It owns the container memory.
    // The objects belongs to interpreter.
    values: []const ast.Object,

    pub const empty: Local = .{
        .keys = &.{},
        .values = &.{},
    };

    // Accept the transfer memory.
    pub fn init(keys: []const u8, values: []const ast.Object) Local {
        return .{ .keys = keys, .values = values };
    }

    /// Release the containers.
    pub fn deinit(self: Local, gpa: Allocator) void {
        if (self.keys.len > 0) {
            gpa.free(self.keys);
        }
        if (self.values.len > 0) {
            gpa.free(self.values);
        }
    }
};

/// Return KeyIterator.
fn keyIterator(self: *EnvFlat) KeyIterator {
    return .init(self.keys.items, self.values.items.len);
}

const Key = struct {
    /// It Belongs to Env keys.
    key: []const u8,
    key_index: usize,
    index: usize,
};

/// Iterate KeyList from last item.
const KeyIterator = struct {
    /// It belongs to Env keys.
    source: []const u8,
    /// The last index of Env's keys.
    index: usize,
    /// The last index of Env's values.
    key_index: usize,

    pub fn init(source: []const u8, value_len: usize) KeyIterator {
        return .{
            .source = source,
            .index = source.len,
            .key_index = value_len,
        };
    }

    /// Iterate key from behind.
    pub fn next(self: *KeyIterator) ?Key {
        if (self.source.len == 0 or self.index == 0 or self.key_index == 0) {
            return null;
        }
        self.key_index -= 1;

        var start = self.index - 1;
        while (self.source[start] != '|' and start >= 0) {
            start -= 1;
        }
        defer self.index = start;

        return .{
            .key = self.source[start + 1 .. self.index],
            .key_index = self.key_index,
            .index = start,
        };
    }
};

test "KeyIterator next" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const keys = "|hello|world";
    try env.keys.appendSlice(gpa, keys);
    try env.values.appendSlice(gpa, &.{ .nil, .nil });

    var it = env.keyIterator();
    try testKeyIterator(1, 6, "world", it.next());
    try testKeyIterator(0, 0, "hello", it.next());
    try testing.expectEqual(null, it.next());
}

fn testKeyIterator(key_index: usize, index: usize, key: []const u8, expected: ?Key) !void {
    if (expected) |got| {
        try testing.expectEqual(key_index, got.key_index);
        try testing.expectEqual(index, got.index);
        try testing.expectEqualSlices(u8, key, got.key);
    }
}

test "EnvFlat" {
    const gpa = testing.allocator;

    var env: EnvFlat = .empty;
    defer env.deinit(gpa);

    const first: ast.Object = .{ .string = try gpa.dupe(u8, "first") };
    errdefer first.deinit(gpa);

    try env.define(gpa, "first", first);
    try testing.expectEqual(1, env.len());
    try testing.expectEqualSlices(u8, "|first", env.keys.items);
    try testing.expectEqualSlices(u8, "first", env.values.items[0].string);

    const local: Local = .{
        .keys = "|second|third",
        .values = &.{
            .{ .string = try gpa.dupe(u8, "second") },
            .{ .string = try gpa.dupe(u8, "third") },
        },
    };
    errdefer for (local.values) |value| value.deinit(gpa);

    try env.append(gpa, local);
    var it = env.keyIterator();
    try testing.expectEqual(3, env.len());
    try testEnvFlat(&env, "third", .{ .string = "third" }, it.next());
    try testEnvFlat(&env, "second", .{ .string = "second" }, it.next());
    try testEnvFlat(&env, "first", .{ .string = "first" }, it.next());
    try testing.expectEqual(null, it.next());

    const assign_object: ast.Object = .{ .string = try gpa.dupe(u8, "forth") };
    errdefer assign_object.deinit(gpa);

    try env.assign(gpa, "first", assign_object);
    try testing.expectEqual(3, env.len());
    try testing.expectEqualSlices(u8, "forth", env.values.items[0].string);
    try testing.expectEqualSlices(u8, "|first|second|third", env.keys.items);

    const second = try env.get("second");
    try testing.expectEqual(3, env.len());
    try testing.expectEqualSlices(u8, "second", second.string);
    try testing.expectEqualSlices(u8, "|first|second|third", env.keys.items);

    const stolen_local = try env.steal(gpa, 0);
    defer {
        for (stolen_local.values) |value| value.deinit(gpa);
        stolen_local.deinit(gpa);
    }

    try testing.expectEqual(0, env.len());
    try testing.expectEqual(3, stolen_local.values.len);
    try testing.expectEqualSlices(u8, "|first|second|third", stolen_local.keys);
    inline for (stolen_local.values, &.{ "forth", "second", "third" }) |got, want| {
        try testing.expectEqualSlices(u8, want, got.string);
    }
}

fn testEnvFlat(
    env: *EnvFlat,
    expected_key: []const u8,
    expected_value: ast.Object,
    actual_key: ?Key,
) !void {
    if (actual_key) |result| {
        switch (env.values.items[result.key_index]) {
            .boolean => |boolean| try testing.expectEqual(expected_value.boolean, boolean),
            .number => |number| try testing.expectEqual(expected_value.number, number),
            .string => |string| try testing.expectEqualSlices(u8, expected_value.string, string),
            .nil => try testing.expect(expected_value.isNil()),
            .callable => try testing.expect(expected_value.isCallable()),
        }
        try testing.expectEqualSlices(u8, expected_key, result.key);
    }
}

const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const ParseIntError = fmt.ParseIntError;
const assert = debug.assert;

const ast = @import("ast.zig");
