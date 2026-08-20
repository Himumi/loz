pub fn resolve(gpa: Allocator, ctx: *Ctx, tree: ast.Ast) Resolver.Error!Resolver.Result {
    var resolver: Resolver = .init(gpa, ctx);
    defer resolver.deinit();
    // Transfer the result to the caller.
    return try resolver.resolve(tree);
}

pub const Resolver = struct {
    allocator: Allocator,
    ctx: *Ctx,

    // It borrowed the memory ownership.
    tree: ast.Ast,
    // The caller owns the memory ownership.
    resolved: Result,

    // It owns the memory ownership.
    scopes: ArrayList(StringHashMap(bool)),

    fun_kind: FunKind = .none,
    class_kind: ClassKind = .none,

    const FunKind = enum { none, function, initializer, method };
    const ClassKind = enum { none, class, subclass };

    /// NOTE: Store Node index (u32) as key and distance (usize) as value
    /// TODO: Need to implement binary search, it is sorted by default.
    pub const Result = ast.Store(usize);
    pub const Error = Allocator.Error || Io.Writer.Error;

    pub fn init(gpa: Allocator, ctx: *Ctx) Resolver {
        return .{
            .allocator = gpa,
            .ctx = ctx,
            .scopes = .empty,
            .resolved = undefined,
            .tree = undefined,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, tree: ast.Ast) Error!Result {
        self.tree = tree;
        self.resolved = .empty;
        errdefer self.resolved.deinit(self.allocator);

        for (self.tree.roots) |root| {
            try self.resolveNode(root);
        }

        // Transfer the locals to the caller.
        return self.resolved;
    }

    fn resolveNode(self: *Resolver, node_index: u32) Error!void {
        const node = self.tree.nodes.get(@intCast(node_index));
        switch (node.tag) {
            .root => {},
            .binary => {
                try self.resolveNode(node.data.lhs);
                try self.resolveNode(node.data.rhs);
            },
            .call => {
                try self.resolveNode(node.data.lhs);

                const len = self.tree.getExtra(node.data.rhs);
                const offset = node.data.rhs + 1;

                for (self.tree.sliceExtra(offset, offset + len)) |arg_index| {
                    try self.resolveNode(arg_index);
                }
            },
            .get => {
                try self.resolveNode(node.data.lhs);
            },
            .group => {
                try self.resolveNode(node.data.lhs);
            },
            .unary => {
                try self.resolveNode(node.data.lhs);
            },
            .literal => {},
            .logical => {
                try self.resolveNode(node.data.lhs);
                try self.resolveNode(node.data.rhs);
            },
            .set => {
                try self.resolveNode(node.data.lhs);
                try self.resolveNode(node.data.rhs);
            },
            .variable => {
                if (self.scopes.items.len == 0) return;
                const scope = self.getLastScopePtr();

                const token = self.tree.getToken(node.token);
                if (scope.get(token.lexeme(self.tree.source))) |value| {
                    if (value == false) {
                        try self.report(token, "Can't read local variable in its own initializer.");
                    }
                }

                try self.resolveLocal(node_index, token);
                return;
            },
            .assign => {
                try self.resolveNode(node.data.lhs);
                const token = self.tree.getToken(node.token);
                try self.resolveLocal(node_index, token);
            },
            .super => {
                const keyword_token = self.tree.getToken(node.token);
                if (self.class_kind == .none) {
                    try self.report(
                        keyword_token,
                        "Can't use 'super' outside of a class.",
                    );
                } else if (self.class_kind != .subclass) {
                    try self.report(
                        keyword_token,
                        "Can't use 'super' in a class with no super class.",
                    );
                }
                try self.resolveLocal(node_index, keyword_token);
            },
            .this => {
                const token = self.tree.getToken(node.token);
                if (self.class_kind == .none) {
                    try self.report(token, "Can't use 'this' outsize of a class.");
                }
                try self.resolveLocal(node_index, token);
            },

            // // Statements //

            .expr => {
                try self.resolveNode(node.data.lhs);
            },
            .fun => {
                const name = self.tree.getToken(node.token);
                try self.declare(name);
                try self.define(name);
                try self.resolveFun(node, .function);
            },
            .@"if" => {
                try self.resolveNode(node.data.lhs);

                const offset = node.data.rhs + 1;
                const len = self.tree.getExtra(node.data.rhs);

                try self.resolveNode(self.tree.getExtra(offset)); // then_node
                if (len > 1) {
                    try self.resolveNode(self.tree.getExtra(offset + 1)); // else_node
                }
            },
            .print => {
                try self.resolveNode(node.data.lhs);
            },
            .@"return" => {
                const keyword = self.tree.getToken(node.token);
                if (self.fun_kind == .none) {
                    try self.report(keyword, "Can't return from top-level code.");
                }
                if (node.data.lhs > 0) {
                    if (self.fun_kind == .initializer) {
                        try self.report(keyword, "Can't return a value from an initializer.");
                    }
                    try self.resolveNode(node.data.lhs);
                }
            },
            .@"var" => {
                const name = self.tree.getToken(node.token);
                try self.declare(name);
                if (node.data.lhs > 0) {
                    try self.resolveNode(node.data.lhs);
                }
                try self.define(name);
            },
            .@"while" => {
                try self.resolveNode(node.data.lhs);
                try self.resolveNode(node.data.rhs);
            },
            .block => {
                try self.begin();
                defer self.end();

                for (self.tree.sliceExtra(node.data.lhs, node.data.rhs)) |index| {
                    try self.resolveNode(index);
                }
            },
            .class => {
                const enclosing = self.class_kind;
                defer self.class_kind = enclosing;

                self.class_kind = .class;

                const name = self.tree.getToken(node.token);

                try self.declare(name);
                try self.define(name);

                const class_lexeme = self.tree.getToken(node.token).lexeme(self.tree.source);

                const super_index = node.data.lhs;
                if (super_index > 0) {
                    const super_token = self.tree.getToken(self.tree.getNode(super_index).token);
                    const super_lexeme = super_token.lexeme(self.tree.source);

                    if (mem.eql(u8, class_lexeme, super_lexeme)) {
                        try self.report(super_token, "A class can't inherit from itself.");
                    }
                }

                if (super_index > 0) {
                    self.class_kind = .subclass;
                    try self.resolveNode(super_index);
                }

                if (super_index > 0) {
                    try self.begin();
                    try self.getLastScopePtr().put("super", true);
                }
                defer if (super_index > 0) self.end();

                // Resolve Class methods.
                {
                    try self.begin();
                    defer self.end();

                    try self.getLastScopePtr().put("this", true);

                    const offset = node.data.rhs + 1;
                    const len = self.tree.getExtra(node.data.rhs);

                    for (self.tree.sliceExtra(offset, offset + len)) |method_index| {
                        const method = self.tree.getNode(method_index);
                        const token = self.tree.getToken(method.token);

                        const is_init = mem.eql(u8, token.lexeme(self.tree.source), "init");
                        const declaration: FunKind = if (is_init) .initializer else .method;

                        try self.resolveFun(method, declaration);
                    }
                }
            },
        }
    }

    fn resolveFun(self: *Resolver, fun_node: ast.Node, fun_type: FunKind) Error!void {
        const enclosing = self.fun_kind;
        defer self.fun_kind = enclosing;

        try self.begin();
        defer self.end();

        self.fun_kind = fun_type;

        const offset = fun_node.data.lhs + 1;
        const len = self.tree.getExtra(fun_node.data.lhs);

        for (self.tree.sliceExtra(offset, offset + len)) |param_index| {
            const param = self.tree.getToken(param_index);
            try self.declare(param);
            try self.define(param);
        }

        try self.resolveNode(fun_node.data.rhs);
    }

    fn resolveLocal(self: *Resolver, node_index: u32, name: Token) !void {
        if (self.scopes.items.len == 0) return;
        const last = self.scopes.items.len - 1;

        const lexeme = name.lexeme(self.tree.source);

        var it: ReverseIterator(StringHashMap(bool)) = .init(self.scopes.items);
        while (it.next()) |entry| {
            if (entry.value_ptr.contains(lexeme)) {
                const value = last - entry.index;
                self.resolved.setBackward(node_index, value) catch {
                    try self.resolved.append(self.allocator, node_index, value);
                };
                return;
            }
        }
    }

    fn begin(self: *Resolver) Allocator.Error!void {
        try self.scopes.append(self.allocator, .init(self.allocator));
    }

    fn end(self: *Resolver) void {
        var scope = self.scopes.pop() orelse unreachable;
        scope.deinit();
    }

    fn declare(self: *Resolver, value: Token) !void {
        if (self.scopes.items.len == 0) return;

        const lexeme = value.lexeme(self.tree.source);

        var scope = self.getLastScopePtr();
        if (scope.contains(lexeme)) {
            try self.report(value, "Already a variable with this name in this scope.");
        }
        try scope.put(lexeme, false);
    }

    fn define(self: *Resolver, value: Token) !void {
        if (self.scopes.items.len == 0) return;

        var scope = self.getLastScopePtr();
        try scope.put(value.lexeme(self.tree.source), true);
    }

    fn getLastScopePtr(self: *Resolver) *StringHashMap(bool) {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn report(self: Resolver, value: Token, message: []const u8) !void {
        try tokenizer.report(self.ctx, self.tree.source, value.loc.start + 1, message);
    }
};

fn ReverseIterator(comptime T: type) type {
    const Entry = struct {
        index: usize,
        value_ptr: *T,
    };

    return struct {
        slice: []const T,
        index: usize,

        pub fn init(slice: []const T) ReverseIterator(T) {
            return .{
                .slice = slice,
                .index = slice.len,
            };
        }

        pub fn next(self: *ReverseIterator(T)) ?Entry {
            if (self.index == 0) return null;

            self.index -= 1;
            return .{
                .index = self.index,
                .value_ptr = @constCast(&self.slice[self.index]),
            };
        }
    };
}

test "resolver" {
    // try testResolver(
    //     \\ var a = "hello";
    //     \\ { print a; }
    // , &.{});

    // try testResolver(
    //     \\ {
    //     \\   var a;
    //     \\   {
    //     \\     a = "hello";
    //     \\   }
    //     \\ }
    // , &.{
    //     .{ 7, 1 },
    // });

    // try testResolver(
    //     \\ var a = "global";
    //     \\ {
    //     \\    fun showA() {
    //     \\      print a;
    //     \\    }
    //     \\
    //     \\    showA();
    //     \\    var a = "block";
    //     \\    showA();
    //     \\ }
    // , &.{
    //     .{ 9, 0 },
    //     .{ 14, 0 },
    // });

    // try testResolver(
    //     \\ class A {
    //     \\   method() {
    //     \\     print "A method";
    //     \\   }
    //     \\ }
    //     \\
    //     \\ class B < A {
    //     \\   method() {
    //     \\     print "B method";
    //     \\   }
    //     \\
    //     \\   test() {
    //     \\     super.method();
    //     \\   }
    //     \\ }
    //     \\
    //     \\ class C < B {}
    //     \\
    //     \\ C().test();
    // , &.{
    //     .{ 15, 2 },
    // });
    try testResolver(
        \\ fun fib(n) {
        \\   var a = 0;
        \\   var b = 1;
        \\   var i = 0;
        \\   while (i < n) {
        \\     var temp = a + b;
        \\     a = b;
        \\     b = temp;
        \\     i = i + 1;
        \\   }
        \\   return a;
        \\ }
        \\ print fib(10);
    , &.{});
}

test "fails resolver" {
    try testFailResolver(
        \\ {
        \\   var a = "hello";
        \\   var a = "world";
        \\ }
    ,
        \\3:8 Error: Already a variable with this name in this scope.
        \\   var a = "world";
        \\       ^
        \\
    );

    try testFailResolver(
        \\ return "at top level";
    ,
        \\1:2 Error: Can't return from top-level code.
        \\ return "at top level";
        \\ ^
        \\
    );
}

fn testResolver(source: [:0]const u8, expected_list: []const struct { u32, usize }) !void {
    const gpa = testing.allocator;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Ctx = .init(undefined, .{ .err = &stream, .out = &stream });

    var tree = try parser.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    var resolved = try resolve(gpa, &ctx, tree);
    defer resolved.deinit(gpa);

    // try testing.expectEqual(expected_list.len, resolved.entries.len);
    for (expected_list) |expected| {
        const key_index = resolved.lookUpForward(expected[0]) orelse {
            return error.NotFoundLocal;
        };

        const entry_value: usize = resolved.entries.items(.value)[key_index];
        try testing.expectEqual(expected[1], entry_value);
    }
}

fn testFailResolver(source: [:0]const u8, error_message: []const u8) !void {
    const gpa = testing.allocator;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Ctx = .init(undefined, .{ .err = &stream, .out = &stream });

    var tree = try parser.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    var resolved = try resolve(gpa, &ctx, tree);
    defer resolved.deinit(gpa);

    try testing.expectEqualSlices(u8, error_message, stream.buffered());
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const AutoHashMap = std.AutoHashMap;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const StringHashMap = std.StringHashMap;

const ast = @import("ast.zig");
const ast_printer = @import("ast_printer.zig");
const Ctx = @import("Context.zig");
const parser = @import("parser.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
