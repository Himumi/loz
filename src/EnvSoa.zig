const EnvSoa = @This();

enclosing: ?*EnvSoa,
/// It has the ownership.
values: ArrayList(ast.Object),
keys: ArrayList(u8), // format: |string -> |hello

pub const Error = error{
    UndefinedVariable,
};

pub fn init(enclosing: ?*EnvSoa) EnvSoa {
    return .{
        .enclosing = enclosing,
        .keys = .empty,
        .values = .empty,
    };
}

pub fn deinit(self: *EnvSoa, gpa: Allocator) void {
    for (self.values.items) |value| {
        value.deinit(gpa);
    }
    self.values.deinit(gpa);
    self.keys.deinit(gpa);
}

pub fn create(gpa: Allocator, enclosing: ?*EnvSoa) Allocator.Error!*EnvSoa {
    const env = try gpa.create(EnvSoa);
    env.* = .init(enclosing);
    return env;
}

/// destroy releases the keys, values, and itself.
pub fn destroy(self: *EnvSoa, gpa: Allocator) void {
    self.deinit(gpa);
    gpa.destroy(self);
}

/// Take the value's ownership but duplicate the key.
pub fn define(self: *EnvSoa, gpa: Allocator, name: []const u8, value: ast.Object) !void {
    try self.values.append(gpa, value);
    try self.keys.print(gpa, "|{s}", .{name});
}

/// Take the value's ownership.
pub fn assign(self: *EnvSoa, gpa: Allocator, name: []const u8, value: ast.Object) !void {
    var it = self.iterator();
    while (it.next()) |result| {
        // Swap the existing value.
        if (mem.eql(u8, result.key, name)) {
            self.values.items[result.key_index].deinit(gpa);
            self.values.items[result.key_index] = value;
            return;
        }
    }

    if (self.enclosing) |enclosing| {
        return try enclosing.assign(gpa, name, value);
    }
    return error.UndefinedVariable;
}

/// Needs to duplicate if it will be used in different lifetimes.
pub fn get(self: *EnvSoa, name: []const u8) !ast.Object {
    var it = self.iterator();
    while (it.next()) |result| {
        if (mem.eql(u8, result.key, name)) {
            return self.values.items[result.key_index];
        }
    }

    if (self.enclosing) |enclosing| {
        return try enclosing.get(name);
    }
    return error.UndefinedVariable;
}

pub fn iterator(self: *EnvSoa) KeyIterator {
    return .{
        .source = self.keys.items,
        .index = self.keys.items.len,
        .key_index = self.values.items.len,
    };
}

const Key = struct {
    key: []const u8,
    key_index: usize,
    index: usize,
};

/// Iterate KeyList from last item.
const KeyIterator = struct {
    source: []const u8,
    index: usize,
    key_index: usize,

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

    var env: EnvSoa = .init(null);
    defer env.deinit(gpa);

    const keys = "|hello|world";
    const values: []const ast.Object = &.{
        .{ .string = try gpa.dupe(u8, "hello") },
        .{ .string = try gpa.dupe(u8, "world") },
    };
    errdefer for (values) |value| value.deinit(gpa);

    try env.keys.appendSlice(gpa, keys);
    try env.values.appendSlice(gpa, values);

    var it = env.iterator();
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

// test "EnvSoa" {
//     const gpa = testing.allocator;
//
//     const env = try EnvSoa.create(gpa, null);
//     defer env.destroy();
//
//     try env.define("number", .{ .number = 123 });
//     try testEnvSoa(env, "number", .{ .number = 123 });
//
//     try env.define("boolean", .{ .boolean = true });
//     try testEnvSoa(env, "boolean", .{ .boolean = true });
//
//     // The first Local Env
//     const first_env = try EnvSoa.create(gpa, env);
//     defer first_env.destroy();
//
//     try first_env.define("local_number", .{ .number = 1234 });
//     try testEnvSoa(first_env, "local_number", .{ .number = 1234 });
//
//     try first_env.define("local_boolean", .{ .boolean = true });
//     try testEnvSoa(first_env, "local_boolean", .{ .boolean = true });
//
//     // The second Local Env
//     const second_env = try EnvSoa.create(gpa, first_env);
//     defer second_env.destroy();
//
//     try second_env.define("second_local_number", .{ .number = 12345 });
//     try testEnvSoa(second_env, "second_local_number", .{ .number = 12345 });
//
//     // Assign the global env.
//     try second_env.assign("number", .{ .number = 999 });
//     try testing.expectEqual(999, env.values.items[0].number);
//
//     // Get the global env from local env.
//     const first_value = try second_env.get("number");
//     try testing.expectEqual(999, first_value.number);
// }

fn testEnvSoa(env: *EnvSoa, expected_key: []const u8, expected_value: ast.Object) !void {
    switch (env.values.getLast()) {
        .boolean => |boolean| try testing.expectEqual(expected_value.boolean, boolean),
        .number => |number| try testing.expectEqual(expected_value.number, number),
        .string => |string| try testing.expectEqualSlices(u8, expected_value.string, string),
        .nil => try testing.expect(expected_value.isNil()),
        .callable => try testing.expect(expected_value.isCallable()),
    }

    var it = env.iterator();
    const result = it.next() orelse return error.EmptyKeyList;
    try testing.expectEqualSlices(u8, expected_key, result.key);
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
