const EnvSoa = @This();

/// The EnvSoa does not have a right for enclosing memory.
enclosing: ?*EnvSoa,
/// The EnvSoa owns the Store's memory.
store: ast.Store(ast.Object),

pub const Error = error{UndefinedVariable};

pub fn init(enclosing: ?*EnvSoa) EnvSoa {
    return .{
        .enclosing = enclosing,
        .store = .empty,
    };
}

pub fn deinit(self: *EnvSoa, gpa: Allocator) void {
    self.store.deinit(gpa);
}

pub fn create(gpa: Allocator, enclosing: ?*EnvSoa) Allocator.Error!*EnvSoa {
    const env = try gpa.create(EnvSoa);
    env.* = .init(enclosing);
    return env;
}

pub fn destroy(self: *EnvSoa, gpa: Allocator) void {
    self.deinit(gpa);
    gpa.destroy(self);
}

/// Append the input value at the end.
/// It takes the input value's ownership.
pub fn define(self: *EnvSoa, gpa: Allocator, key: u32, value: ast.Object) Allocator.Error!void {
    if (self.store.lookUpBackward(key)) |index| {
        self.store.entries.items(.value)[index] = value;
    } else {
        try self.store.append(gpa, key, value);
    }
}

/// Overwrite the target entry with a new value,
/// It iterates from the current Env until enclosing is null.
/// It takes the input value's ownership.
pub fn assign(self: *EnvSoa, key: u32, value: ast.Object) error{UndefinedVariable}!void {
    return self.set(key, value) catch {
        if (self.enclosing) |enclosing| {
            return try enclosing.assign(key, value);
        }
        return error.UndefinedVariable;
    };
}

/// Overwrite the current Env value.
/// It takes the input value's ownership.
pub fn set(self: *EnvSoa, key: u32, value: ast.Object) error{UndefinedVariable}!void {
    return self.store.setBackward(key, value) catch error.UndefinedVariable;
}

/// Get the target value by iterating from the current Env until enclosing is null.
/// It gets the deep copied value.
pub fn find(self: *EnvSoa, key: u32) error{UndefinedVariable}!ast.Object {
    return self.get(key) catch |err| {
        if (self.enclosing) |enclosing| {
            return try enclosing.get(key);
        }
        return err;
    };
}

/// Get the deep copied value in the current EnvSoa.
pub fn get(self: *EnvSoa, key: u32) error{UndefinedVariable}!ast.Object {
    return self.store.getBackward(key) orelse error.UndefinedVariable;
}

/// Look up the target EnvSoa by distance.
pub fn lookUp(self: *EnvSoa, distance: usize) *EnvSoa {
    var env = self;
    for (0..distance) |_| {
        if (env.enclosing) |enclosing| {
            env = enclosing;
        } else {
            break;
        }
    }
    return env;
}

test "EnvSoa" {
    const gpa = testing.allocator;

    var env: EnvSoa = .init(null);
    defer env.deinit(gpa);

    try env.define(gpa, 12, .{ .number = 12 });
    var twelve = try env.get(12);
    try testing.expectEqual(12, twelve.number);

    var local_env: EnvSoa = .init(&env);
    defer local_env.deinit(gpa);

    try testing.expectError(Error.UndefinedVariable, local_env.get(12));
    try testing.expectError(
        Error.UndefinedVariable,
        local_env.set(12, .{ .number = 12 }),
    );

    try local_env.assign(12, .{ .number = 13 });
    twelve = try local_env.find(12);
    try testing.expectEqual(13, twelve.number);

    try local_env.lookUp(1).set(12, .{ .number = 14 });
    twelve = try local_env.lookUp(1).get(12);
    try testing.expectEqual(14, twelve.number);
}

const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const MultiArrayList = std.MultiArrayList;
const ParseIntError = fmt.ParseIntError;
const assert = debug.assert;

const ast = @import("ast.zig");
