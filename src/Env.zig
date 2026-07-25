/// Env reponsibles for their memory.
const Env = @This();

allocator: Allocator,
enclosing: ?*Env, // Temporary upper Env place.
values: StringHashMap(ast.Object),

pub const Error = error{
    UndefinedVariable,
};

pub fn init(gpa: Allocator, enclosing: ?*Env) Env {
    return .{
        .allocator = gpa,
        .values = .init(gpa),
        .enclosing = enclosing,
    };
}

/// deinit releases the keys and values.
pub fn deinit(self: *Env) void {
    var it = self.values.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(self.allocator);
    }
    self.values.deinit();
}

pub fn create(gpa: Allocator, enclosing: ?*Env) Allocator.Error!*Env {
    const env = try gpa.create(Env);
    env.* = .init(gpa, enclosing);
    return env;
}

/// destroy releases the keys, values, and itself.
pub fn destroy(self: *Env) void {
    self.deinit();
    self.allocator.destroy(self);
}

/// The caller reponsibles for the value of Local Env.
/// The function will duplicate the key and the value for Global Env.
pub fn define(self: *Env, name: []const u8, value: ast.Object) Allocator.Error!void {
    const object = if (self.enclosing == null) try value.dupe(self.allocator) else value;
    // Only release the global Env. because Local env using arena allocator. it may occur a bug.
    errdefer if (self.enclosing == null) object.deinit(self.allocator);

    const gput = try self.values.getOrPut(name);
    if (gput.found_existing) {
        gput.value_ptr.deinit(self.allocator);
    } else {
        gput.key_ptr.* = try self.allocator.dupe(u8, name);
    }
    gput.value_ptr.* = object;
}

/// Look up the same key from local to global. It will duplicate value if the key found.
pub fn assign(self: *Env, name: []const u8, value: ast.Object) (Error || Allocator.Error)!void {
    if (self.values.contains(name)) {
        return try self.define(name, value);
    }
    if (self.enclosing) |enclosing| { // Look up in upper Env.
        return try enclosing.assign(name, value);
    }
    return error.UndefinedVariable;
}

/// Needs to duplicate if it will be used in different lifetimes.
pub fn get(self: Env, name: []const u8) (Error || Allocator.Error)!ast.Object {
    if (self.values.get(name)) |object| {
        return object;
    }
    if (self.enclosing) |enclosing| { // Look up in upper Env
        return try enclosing.get(name);
    }
    return error.UndefinedVariable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const ast = @import("ast.zig");
