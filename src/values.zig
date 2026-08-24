pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    nil: void,
    object: *Obj,

    pub fn deinit(self: Value, gpa: Allocator) void {
        if (self == .object) {
            self.object.destroy(gpa);
        }
    }

    pub fn isNumber(self: Value) bool {
        return self == .number;
    }

    pub fn isBoolean(self: Value) bool {
        return self == .boolean;
    }

    pub fn isNil(self: Value) bool {
        return self == .nil;
    }

    pub fn isObject(self: Value) bool {
        return self == .object;
    }

    pub fn isString(self: Value) bool {
        return self.isObject() and self.object.isString();
    }

    pub fn isSame(self: Value, target: Value) bool {
        if (self.isNumber() and target.isNumber()) return true;
        if (self.isNil() and target.isNil()) return true;
        if (self.isBoolean() and target.isBoolean()) return true;
        if (self.isObject() and target.isObject()) return true;

        return false;
    }

    pub fn isEqual(self: Value, target: Value) bool {
        if (!self.isSame(target)) return false;

        return switch (self) {
            .nil => return true,
            .boolean => |boolean| boolean == target.boolean,
            .number => |number| number == target.number,
            // TODO: Evaluation for Object.
            .object => |object| object.isEqual(target.object.*),
            // else => false,
        };
    }

    pub fn print(self: Value, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .number => |number| try writer.print("{}", .{number}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .object => |object| try object.print(writer),
            .nil => try writer.writeAll("nil"),
        }
    }

    pub fn dumpInstruction(
        self: Value,
        writer: *Io.Writer,
        name: []const u8,
        constant: u32,
    ) Io.Writer.Error!void {
        switch (self) {
            .number => |number| {
                try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, number });
            },
            .boolean => |boolean| {
                try writer.print("{s:<16} {d:>4} '{}'\n", .{ name, constant, boolean });
            },
            .nil => {
                try writer.print("{s:<16} {d:>4} 'nil'\n", .{ name, constant });
            },
            .object => |object| {
                switch (object.*.data) {
                    .string => |string| try writer.print(
                        "{s:<16} {d:>4} '{s}'\n",
                        .{ name, constant, string },
                    ),
                }
            },
        }
    }

    pub fn isFalsey(self: Value) bool {
        return switch (self) {
            .nil => true,
            .boolean => |boolean| !boolean,
            else => false,
        };
    }
};

pub const Obj = struct {
    data: Data,
    next: ?*Obj = null,

    const Data = union(enum) {
        string: []const u8,
    };

    pub fn create(gpa: Allocator, obj: Obj) Allocator.Error!*Obj {
        const new_obj = try gpa.create(Obj);
        new_obj.* = obj;
        return new_obj;
    }

    pub fn destroy(self: *Obj, gpa: Allocator) void {
        switch (self.data) {
            .string => |string| gpa.free(string),
        }
        gpa.destroy(self);
    }

    pub fn isString(self: Obj) bool {
        return self.data == .string;
    }

    pub fn isSame(self: Obj, target: Obj) bool {
        if (self.isString() and target.isString()) return true;
        return false;
    }

    pub fn isEqual(self: Obj, target: Obj) bool {
        if (!self.isSame(target)) return false;

        return switch (self.data) {
            .string => |string| mem.eql(u8, string, target.data.string),
        };
    }

    pub fn print(self: Obj, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.data) {
            .string => |string| try writer.print("{s}", .{string}),
        }
    }
};

const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;
const Io = std.Io;
