pub const Ast = struct {
    source: [:0]const u8,

    roots: []const Index,
    nodes: NodeList.Slice,
    tokens: TokenList.Slice,
    literals: []const Value,

    symbols: []const u32,
    extra: []const u32,

    pub fn deinit(self: *Ast, gpa: Allocator) void {
        gpa.free(self.roots);
        self.nodes.deinit(gpa);
        self.tokens.deinit(gpa);
        gpa.free(self.literals);

        gpa.free(self.symbols);
        gpa.free(self.extra);
    }
};

const Index = u32;

pub const NodeList = MultiArrayList(Node);

pub const Node = struct {
    tag: Tag,
    token: Token.Index,
    data: Data,

    const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    const Tag = enum {
        // Expressions //

        /// lhs: left Expr
        /// rhs: right Expr
        binary,
        /// lhs: arg start index
        /// rhs: arg end index
        call,
        /// lhs: Object Expr
        /// rhs: 0
        get,
        /// lhs: Expression Expr
        /// rhs: 0
        group,
        /// lhs: right Expr
        /// rhs: 0
        unary,
        /// lhs: Object index
        /// rhs: 0
        literal,
        /// lhs: left Expr
        /// rhs: right Expr
        logical,
        /// lhs: Object Expr
        /// rhs: Value Expr
        set,
        /// lhs: 0
        /// rhs: 0
        variable,
        /// lhs: Value Expr
        /// rhs: 0
        assign,
        /// lhs: 0
        /// rhs: 0
        this,

        // Statements //

        /// lhs: Expression Expr
        /// rhs: 0
        expr,
        /// lhs: Extra Token: [offset, len]
        /// rhs: Block Stmt
        fun,
        /// lhs: condition Expr
        /// rhs: Extra Node: [len, then, else]
        @"if",
        /// lhs: Expression Expr
        /// rhs: 0
        print,
        /// lhs: 0 orelse Value Expr
        /// rhs: 0
        @"return",
        /// lhs: 0 orelse Initializer Expr
        /// rhs: 0
        @"var",
        /// lhs: Condition Expr
        /// rhs: Body Stmt
        @"while",
        /// lhs: List start index
        /// rhs: List end index
        block,
        /// lhs: Methods start index
        /// rhs: Methods end index
        class,
    };
};

pub fn Store(comptime T: type) type {
    return struct {
        entries: MultiArrayList(Entry),

        const Symbol = u32;
        const Entry = struct {
            key: Symbol,
            value: T,
        };

        pub const empty: Store(T) = .{ .entries = .empty };

        pub fn deinit(self: *Store(T), gpa: Allocator) void {
            self.entries.deinit(gpa);
        }

        /// Append the entry at the end of list.
        /// It does not guarantee the uniqueness.
        pub fn append(self: *Store(T), gpa: Allocator, key: u32, value: T) Allocator.Error!void {
            try self.entries.append(gpa, .{ .key = key, .value = value });
        }

        /// Overwrite the target key's value with a new value.
        /// It iterates forward.
        pub fn setForward(self: *Store(T), key: u32, value: T) error{NotFoundEntry}!void {
            if (self.lookUpForward(key)) |index| {
                self.entries.items(.value)[@intCast(index)] = value;
            } else {
                return error.NotFoundEntry;
            }
        }

        /// Overwrite the target key's value with a new value
        /// It iterates backward.
        pub fn setBackward(self: *Store(T), key: u32, value: T) error{NotFoundEntry}!void {
            if (self.lookUpBackward(key)) |index| {
                self.entries.items(.value)[@intCast(index)] = value;
            } else {
                return error.NotFoundEntry;
            }
        }

        /// Get the target key's value by iterating forward.
        pub fn getForward(self: Store(T), key: u32) ?T {
            const index = self.lookUpForward(key) orelse return null;
            const entry = self.entries.get(@intCast(index));
            return entry.value;
        }

        /// Get the target key's value by iterating backward
        pub fn getBackward(self: Store(T), key: u32) ?T {
            const index = self.lookUpBackward(key) orelse return null;
            const entry = self.entries.get(@intCast(index));
            return entry.value;
        }

        /// look up the target position index by iterating forward.
        pub fn lookUpForward(self: Store(T), key: u32) ?u32 {
            const keys: []const u32 = self.entries.items(.key);
            for (keys, 0..) |store_key, index| {
                if (store_key == key) return @intCast(index);
            }
            return null;
        }

        /// look up the target position index by iterating backward.
        pub fn lookUpBackward(self: Store(T), key: u32) ?u32 {
            const keys: []const u32 = self.entries.items(.key);

            var index: usize = self.entries.len;
            while (index > 0) {
                index -= 1;
                if (keys[index] == key) return @intCast(index);
            }
            return null;
        }
    };
}

test "Store" {
    const gpa = testing.allocator;

    var store: Store(Object) = .empty;
    defer store.deinit(gpa);

    try store.append(gpa, 1, .{ .boolean = true });
    try testing.expectEqual(true, store.entries.get(0).value.boolean);

    const object = store.getForward(1) orelse return error.NotFoundEntry;
    try testing.expectEqual(true, object.boolean);

    try store.setForward(1, .{ .boolean = false });
    try testing.expectEqual(false, store.entries.get(0).value.boolean);

    const found_index = store.lookUpForward(1);
    try testing.expectEqual(0, found_index);
}

pub const Value = union(enum) {
    string: String,
    number: Number,
    boolean: Boolean,
    nil: Nil,

    /// For debuging purposes.
    pub fn dump(self: Value, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .string => |string| try string.dump(writer),
            .number => |number| try dumpNumber(number, writer),
            .boolean => |boolean| try dumpBoolean(boolean, writer),
            .nil => try dumpNil(writer),
        }
    }
};

pub const Number = f64;

pub fn dumpNumber(self: Number, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("<number {}>", .{self});
}

pub const Boolean = bool;

pub fn dumpBoolean(self: Boolean, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("<boolean {}>", .{self});
}

pub const Nil = void;

pub fn dumpNil(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.writeAll("<nil>");
}

const StringPool = struct {
    pool: ArrayList(String),

    const empty: StringPool = .{ .pool = .empty };

    pub fn deinit(self: *StringPool, gpa: Allocator) void {
        self.pool.deinit(gpa);
    }

    pub fn get(self: *StringPool, index: u32) String {
        return self.pool.items[@intCast(index)];
    }

    pub fn append(self: *StringPool, gpa: Allocator, string: String) !u32 {
        for (self.pool.items, 0..) |item, index| {
            if (item.equal(string)) return @intCast(index);
        }
        try self.pool.append(gpa, string);
        return @intCast(self.pool.items.len - 1);
    }
};

test "StringPool" {
    const gpa = testing.allocator;

    var list: StringPool = .empty;
    defer list.deinit(gpa);

    var index = try list.append(gpa, .{ .literal = 12 });
    try testing.expectEqual(@as(u32, 0), index);
    try testing.expect(list.get(index).equal(.{ .literal = 12 }));

    index = try list.append(gpa, .{ .literal = 12 });
    try testing.expectEqual(@as(u32, 0), index);
    try testing.expect(list.get(index).equal(.{ .literal = 12 }));
}

pub const String = union(enum) {
    literal: Token.Index,
    concat: Concat,

    const Concat = struct {
        // It points to Interpreter's Strings pool.
        left: Index,
        // It points to Interpreter's Strings pool.
        right: Index,
    };

    /// For debuging purposes.
    fn dump(self: String, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .literal => |literal| {
                try writer.print("<string literal {}>", .{literal});
            },
            .concat => |concat| {
                try writer.print("<string concat {} {}>", .{ concat.left, concat.right });
            },
        }
    }

    pub fn isLiteral(self: String) bool {
        return self == .literal;
    }

    pub fn isConcat(self: String) bool {
        return self == .concat;
    }

    pub fn isSame(self: String, target: String) bool {
        if (self.isLiteral() and target.isLiteral()) return true;
        if (self.isConcat() and target.isConcat()) return true;
        return false;
    }

    pub fn equal(self: String, target: String) bool {
        if (!self.isSame(target)) return false;

        if (self.isLiteral() and target.isLiteral()) {
            return self.literal == target.literal;
        }

        if (self.isConcat() and target.isConcat()) {
            return self.concat.left == target.concat.left and
                self.concat.right == self.concat.right;
        }
        return false;
    }
};

pub const Object = union(enum) {
    string: String,
    number: Number,
    boolean: Boolean,
    nil: Nil,

    /// It points to interpreter's fun list.
    fun: Index,
    /// It points to interpreter's class list.
    class: Index,
    /// It points to interpreter's instance list.
    instance: Index,

    /// For debuging purposes.
    pub fn dump(self: Object, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .string => |string| try string.dump(writer),
            .number => |number| try dumpNumber(number, writer),
            .boolean => |boolean| try dumpBoolean(boolean, writer),
            .nil => try dumpNil(writer),

            .fun => |fun| try writer.print("<fun {}>", .{fun}),
            .class => |class| try writer.print("<class {}>", .{class}),
            .instance => |instance| try writer.print("<instance {}>", .{instance}),
        }
    }

    pub fn from(value: Value) Object {
        return switch (value) {
            .string => |string| .{ .string = string },
            .number => |number| .{ .number = number },
            .boolean => |boolean| .{ .boolean = boolean },
            .nil => .nil,
        };
    }
};

const Fun = struct {
    tag: enum { fun, init },
    stmt: Index,
    closure: *Env,
};

const Class = struct {
    stmt: Index,
    super: ?Index,
    /// It Points to interpreter's classes_methods.
    methods: Index,
};

const Instance = struct {
    stmt: Index,
    /// It Points to interpreter's instances_fields.
    fields: Index,
    /// It Points to interpreter's classes_methods.
    methods: Index,
};

test "object dump" {
    try testObjectDump(.{ .string = .{ .literal = 0 } }, "<string literal 0>");
    try testObjectDump(
        .{ .string = .{ .concat = .{ .left = 1, .right = 2 } } },
        "<string concat 1 2>",
    );
    try testObjectDump(.{ .number = 123 }, "<number 123>");
    try testObjectDump(.{ .boolean = true }, "<boolean true>");
    try testObjectDump(.nil, "<nil>");
    try testObjectDump(.{ .fun = 1 }, "<fun 1>");
    try testObjectDump(.{ .class = 1 }, "<class 1>");
    try testObjectDump(.{ .instance = 1 }, "<instance 1>");
}

fn testObjectDump(value: Object, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&buffer);

    try value.dump(&stream);
    try testing.expectEqualSlices(u8, expected, stream.buffered());
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const MultiArrayList = std.MultiArrayList;
const StringHashMap = std.StringHashMap;

const Env = @import("EnvSoa.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
const TokenList = tokenizer.TokenList;
