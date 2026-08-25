pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    nil: void,
    object: *Object,

    pub fn deinit(self: Value, gpa: Allocator) void {
        if (self == .object) {
            self.object.deinit(gpa);
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
            .object => |object| object.isEqual(target.object),
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
                switch (object.*.kind) {
                    .string => {
                        const parent_ptr: *String = @fieldParentPtr("head", object);
                        try writer.print(
                            "{s:<16} {d:>4} '{s}'\n",
                            .{ name, constant, parent_ptr.slice() },
                        );
                    },
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

pub const Object = struct {
    kind: Kind,
    next: ?*Object = null,

    const Kind = enum { string };

    pub fn deinit(self: *Object, gpa: Allocator) void {
        switch (self.kind) {
            .string => {
                const parent_ptr = self.getParentPtr(String);
                parent_ptr.destroy(gpa);
            },
        }
    }

    pub fn getParentPtr(self: *Object, comptime T: type) *T {
        const parent_ptr: *T = @fieldParentPtr("head", self);
        return parent_ptr;
    }

    pub fn isString(self: Object) bool {
        return self.kind == .string;
    }

    pub fn isSame(self: *Object, target: *Object) bool {
        if (self.isString() and target.isString()) return true;
        return false;
    }

    pub fn isEqual(self: *Object, target: *Object) bool {
        if (!self.isSame(target)) return false;

        return switch (self.kind) {
            .string => {
                const parent_ptr: *String = @fieldParentPtr("head", self);
                const target_ptr: *String = @fieldParentPtr("head", target);
                return mem.eql(u8, parent_ptr.slice(), target_ptr.slice());
            },
        };
    }

    pub fn print(self: *Object, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.kind) {
            .string => {
                const parent_ptr: *String = @fieldParentPtr("head", self);
                try writer.print("{s}", .{parent_ptr.slice()});
            },
        }
    }
};

test "Object" {
    var str: String = .{
        .head = .{
            .kind = .string,
            .next = null,
        },
        .kind = .@"const",
        .str = "hello world",
    };

    var str2: String = .{
        .head = .{
            .kind = .string,
            .next = null,
        },
        .kind = .@"const",
        .str = "hello world",
    };

    const object = &str.head;
    const target = &str2.head;
    try testing.expectEqual(true, object.isSame(target));
    try testing.expectEqual(true, object.isEqual(target));
}

pub const String = struct {
    head: Object,
    kind: Kind,
    str: []const u8,

    const Kind = enum { @"const", owned };

    pub fn init(kind: Kind, str: []const u8, head: Object) String {
        return .{
            .head = head,
            .kind = kind,
            .str = str,
        };
    }

    pub fn destroy(self: *String, gpa: Allocator) void {
        self.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn deinit(self: String, gpa: Allocator) void {
        if (self.kind == .owned) {
            gpa.free(self.str);
        }
    }

    // The caller borrows String's str.
    pub fn slice(self: String) []const u8 {
        return self.str;
    }
};

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Io = std.Io;
