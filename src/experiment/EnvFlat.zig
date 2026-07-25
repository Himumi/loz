const Env = @This();

allocator: Allocator,
values: ArrayList(ast.Object),
keys: ArrayList(u8), // format: |string -> |hello
tracker: ArrayList(usize),

pub const Error = error{
    UndefinedVariable,
};

pub fn init(allocator: Allocator) Env {
    return .{
        .allocator = allocator,
        .keys = .empty,
        .values = .empty,
        .tracker = .empty,
    };
}

/// deinit releases the keys and values. Only call in global lifetimes.
pub fn deinit(self: *Env) void {
    for (self.values.items) |value| {
        value.deinit(self.allocator);
    }
    self.values.deinit(self.allocator);
    self.keys.deinit(self.allocator);
    self.tracker.deinit(self.allocator);
}

pub fn create(gpa: Allocator) Allocator.Error!*Env {
    const env = try gpa.create(Env);
    env.* = .init(gpa);
    return env;
}

pub fn destroy(self: *Env) void {
    self.deinit();
    self.allocator.destroy(self);
}

/// The caller reponsibles for the value of Local Env.
/// The function will duplicate the key and the value for Global Env.
pub fn define(self: *Env, name: []const u8, value: ast.Object) !void {
    const object = try value.dupe(self.allocator);
    errdefer object.deinit(self.allocator);

    try self.values.append(self.allocator, object);
    try self.keys.print(self.allocator, "|{s}", .{name});
}

pub fn append(self: *Env, local: Local) !void {
    try self.keys.appendSlice(self.allocator, local.keys);
    for (local.values) |value| {
        const object = try value.dupe(self.allocator);
        errdefer object.deinit(self.allocator);
        try self.values.append(self.allocator, object);
    }
}

fn getFirstTracker(self: *Env) usize {
    if (self.tracker.items.len > 0) {
        return self.tracker.items[0];
    }
    return 0;
}

/// Look up the same key from local to global.
/// It will duplicate value (global) or steal the memory (local).
pub fn assign(self: *Env, name: []const u8, value: ast.Object) !void {
    var it = self.iterator();
    while (it.next()) |result| {
        // Swap the existing value.
        if (mem.eql(u8, result.key, name)) {
            const object = try value.dupe(self.allocator);
            self.values.items[result.key_index].deinit(self.allocator);
            self.values.items[result.key_index] = object;
            return;
        }
    }
    return error.UndefinedVariable;
}

/// Needs to duplicate if it will be used in different lifetimes.
pub fn get(self: *Env, name: []const u8) !ast.Object {
    var it = self.iterator();
    while (it.next()) |result| {
        if (mem.eql(u8, result.key, name)) {
            return self.values.items[result.key_index];
        }
    }
    return error.UndefinedVariable;
}

/// Declare the next operations are Local Env operation.
pub fn setLocal(self: *Env) Allocator.Error!void {
    const start_local = self.values.items.len;
    try self.tracker.append(self.allocator, start_local);
}

pub const Local = struct {
    keys: []const u8,
    values: []const ast.Object,

    pub const empty: Local = .{
        .keys = &.{},
        .values = &.{},
    };

    pub fn init(keys: []const u8, values: []const ast.Object) Local {
        return .{ .keys = keys, .values = values };
    }

    pub fn deinit(self: Local, gpa: Allocator) void {
        for (self.values) |value| {
            value.deinit(gpa);
        }
        if (self.keys.len > 0) {
            gpa.free(self.values);
        }
        if (self.values.len > 0) {
            gpa.free(self.keys);
        }
    }

    pub fn create(
        gpa: Allocator,
        keys: []const u8,
        values: []const ast.Object,
    ) Allocator.Error!*Local {
        const local = try gpa.create(Local);
        local.* = .init(keys, values);
        return local;
    }

    pub fn destroy(self: *Local, gpa: Allocator) void {
        self.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn dupe(self: Local, gpa: Allocator) Allocator.Error!*Local {
        const keys = try gpa.dupe(u8, self.keys);
        errdefer gpa.free(keys);

        var list: ArrayList(ast.Object) = try .initCapacity(gpa, self.values.len);
        defer {
            for (list.items) |item| item.deinit(gpa);
            list.deinit(gpa);
        }

        for (self.values) |value| {
            const object = try value.dupe(gpa);
            errdefer object.deinit(gpa);
            try list.append(gpa, object);
        }

        const values = try list.toOwnedSlice(gpa);
        errdefer {
            for (values) |value| value.deinit(gpa);
            gpa.free(values);
        }

        return try Local.create(gpa, keys, values);
    }
};

/// Use after using SetLocal to clear Local Env used memory.
pub fn releaseLocal(self: *Env, gpa: Allocator) !Local {
    const start_local = self.tracker.pop() orelse 0;

    var it = self.iterator();
    while (it.next()) |result| {
        if (result.key_index == start_local) {
            const keys = try gpa.dupe(u8, self.keys.items[result.index..]);
            errdefer gpa.free(keys);

            const len = self.values.items[result.key_index..].len;
            var list: ArrayList(ast.Object) = try .initCapacity(gpa, len);
            defer {
                for (list.items) |item| item.deinit(gpa);
                list.deinit(gpa);
            }

            for (self.values.items[result.key_index..]) |value| {
                const object = try value.dupe(gpa);
                errdefer object.deinit(gpa);
                try list.append(gpa, object);
            }

            const values = try list.toOwnedSlice(gpa);

            for (self.values.items[result.key_index..]) |value| {
                value.deinit(self.allocator);
            }

            self.keys.items.len = result.index;
            self.values.items.len = result.key_index;

            return .{
                .keys = keys,
                .values = values,
            };
        }
    }
    return .empty;
}

pub fn iterator(self: *Env) KeyIterator {
    return .{
        .source = self.keys.items,
        .index = self.keys.items.len,
        .len = self.values.items.len,
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
    len: usize,

    pub fn next(self: *KeyIterator) ?Key {
        if (self.source.len == 0 or self.index <= 0) {
            return null;
        }

        var result: Key = .{
            .key = undefined,
            .key_index = 0,
            .index = 0,
        };
        var start = self.index - 1;
        while (self.source[start] != '|' and start >= 0) {
            start -= 1;
        }

        self.len -= 1;

        result.key_index = self.len;
        result.key = self.source[start + 1 .. self.index];
        result.index = start;

        self.index = start;

        return result;
    }
};

test "KeyIterator next" {
    const gpa = testing.allocator;

    var env: Env = .init(gpa);
    defer env.deinit();

    const keys = "|hello|world";
    try env.keys.appendSlice(env.allocator, keys);
    try env.values.appendSlice(env.allocator, &.{ .nil, .nil });

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

test "Env" {
    const gpa = testing.allocator;
    var env: Env = .init(gpa);
    defer env.deinit();

    try env.define("number", .{ .number = 123 });
    try testEnvDefine(&env, "number", .{ .number = 123 });

    try env.define("boolean", .{ .boolean = true });
    try testEnvDefine(&env, "boolean", .{ .boolean = true });

    // The first Local Env
    try env.setLocal();
    try env.define("local_number", .{ .number = 1234 });
    try testEnvDefine(&env, "local_number", .{ .number = 1234 });

    try env.define("local_boolean", .{ .boolean = true });
    try testEnvDefine(&env, "local_boolean", .{ .boolean = true });

    // The first Local Env
    try env.setLocal();
    try env.define("second_local_number", .{ .number = 12345 });
    try testEnvDefine(&env, "second_local_number", .{ .number = 12345 });

    // Assign the global env.
    const env_len = env.values.items.len;
    try env.assign("number", .{ .number = 999 });
    try testing.expectEqual(999, env.values.items[0].number);
    try testing.expectEqual(env_len, env.values.items.len);

    // Get the global env from local env.
    const first_value = try env.get("number");
    try testing.expectEqual(999, first_value.number);
}

fn testEnvDefine(env: *Env, expected_key: []const u8, expected_value: ast.Object) !void {
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
