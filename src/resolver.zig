pub fn resolve(gpa: Allocator, ctx: *Ctx, list: []const *ast.Stmt) Resolver.Error!Resolver.Result {
    var resolver: Resolver = .init(gpa, ctx);
    defer resolver.deinit();
    // Transfer the result to the caller.
    return try resolver.resolve(list);
}

pub const Resolver = struct {
    allocator: Allocator,
    ctx: *Ctx,
    // The scope does not own the keys' ownership.
    scopes: ArrayList(StringHashMap(bool)),
    // The resolved does not own the keys' ownership.
    resolved: Result,
    fun_kind: FunKind = .none,
    class_kind: ClassKind = .none,

    const FunKind = enum { none, function, initializer, method };
    const ClassKind = enum { none, class };

    pub const Error = Allocator.Error || Io.Writer.Error;
    pub const Result = AutoHashMap(*ast.Expr, usize);

    pub fn init(gpa: Allocator, ctx: *Ctx) Resolver {
        return .{
            .allocator = gpa,
            .ctx = ctx,
            .scopes = .empty,
            .resolved = .init(gpa),
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
        self.resolved.deinit();
    }

    pub fn resolve(self: *Resolver, list: []const *ast.Stmt) Error!Result {
        try self.resolveStmtList(list);
        // Transfer the locals to the caller.
        return self.resolved.move();
    }

    fn resolveStmtList(self: *Resolver, list: []const *ast.Stmt) Error!void {
        for (list) |stmt| {
            try self.resolveStmt(stmt);
        }
    }

    fn resolveStmt(self: *Resolver, stmt: *ast.Stmt) Error!void {
        switch (stmt.*) {
            .block_statement => |block_stmt| {
                try self.begin();
                defer self.end();

                try self.resolveStmtList(block_stmt.list);
            },
            .var_statement => |var_stmt| {
                try self.declare(var_stmt.name);
                if (var_stmt.initializer) |initializer| {
                    try self.resolveExpr(initializer);
                }
                try self.define(var_stmt.name);
            },
            .fun_statement => |fun_stmt| {
                try self.declare(fun_stmt.name);
                try self.define(fun_stmt.name);
                try self.resolveFun(fun_stmt, .function);
            },
            .expr_statement => |expr_stmt| {
                try self.resolveExpr(expr_stmt.expression);
            },
            .if_statement => |if_stmt| {
                try self.resolveExpr(if_stmt.condition);
                try self.resolveStmt(if_stmt.then_stmt);
                if (if_stmt.else_stmt) |else_stmt| {
                    try self.resolveStmt(else_stmt);
                }
            },
            .print_statement => |print_stmt| {
                try self.resolveExpr(print_stmt.expression);
            },
            .return_statement => |return_stmt| {
                if (self.fun_kind == .none) {
                    try self.report(return_stmt.keyword, "Can't return from top-level code.");
                }
                if (return_stmt.value) |value| {
                    if (self.fun_kind == .initializer) {
                        try self.report(
                            return_stmt.keyword,
                            "Can't return a value from an initializer.",
                        );
                    }
                    try self.resolveExpr(value);
                }
            },
            .while_statement => |while_stmt| {
                try self.resolveExpr(while_stmt.condition);
                try self.resolveStmt(while_stmt.body);
            },
            .class_statement => |class_stmt| {
                const enclosing = self.class_kind;
                defer self.class_kind = enclosing;

                self.class_kind = .class;

                try self.declare(class_stmt.name);
                try self.define(class_stmt.name);

                try self.begin();
                defer self.end();

                try self.scopes.items[self.scopes.items.len - 1].put("this", true);

                for (class_stmt.methods) |method| {
                    const is_init = mem.eql(u8, method.fun_statement.name.lexeme, "init");
                    const declaration: FunKind = if (is_init) .initializer else .method;

                    try self.resolveFun(method.fun_statement, declaration);
                }
            },
        }
    }

    fn resolveExpr(self: *Resolver, expr: *ast.Expr) Error!void {
        switch (expr.*) {
            .variable => |variable| {
                if (self.scopes.items.len == 0) return;

                const scope = self.scopes.getLast();
                if (scope.get(variable.name.lexeme)) |value| {
                    if (value == false) {
                        try self.report(
                            variable.name,
                            "Can't read local variable in its own initializer.",
                        );
                    }
                }

                try self.resolveLocal(expr, variable.name);
                return;
            },
            .assign => |assign| {
                try self.resolveExpr(assign.value);
                try self.resolveLocal(expr, assign.name);
            },
            .binary => |binary| {
                try self.resolveExpr(binary.left);
                try self.resolveExpr(binary.right);
            },
            .call => |call| {
                try self.resolveExpr(call.callee);
                for (call.args) |arg| {
                    try self.resolveExpr(arg);
                }
            },
            .get => |get| {
                try self.resolveExpr(get.object);
            },
            .grouping => |group| {
                try self.resolveExpr(group.expression);
            },
            .literal => {},
            .logical => |logical| {
                try self.resolveExpr(logical.left);
                try self.resolveExpr(logical.right);
            },
            .set => |set| {
                try self.resolveExpr(set.value);
                try self.resolveExpr(set.object);
            },
            .unary => |unary| {
                try self.resolveExpr(unary.right);
            },
            .this => |this| {
                if (self.class_kind == .none) {
                    try self.report(this.name, "Can't use 'this' outsize of a class.");
                }
                try self.resolveLocal(expr, this.name);
            },
        }
    }

    fn resolveFun(self: *Resolver, fun_stmt: ast.Function, fun_type: FunKind) Error!void {
        const enclosing = self.fun_kind;
        defer self.fun_kind = enclosing;

        try self.begin();
        defer self.end();

        self.fun_kind = fun_type;
        for (fun_stmt.params) |param| {
            try self.declare(param);
            try self.define(param);
        }

        try self.resolveStmtList(fun_stmt.body.list);
    }

    fn resolveLocal(self: *Resolver, expr: *ast.Expr, name: Token) !void {
        if (self.scopes.items.len == 0) return;
        const last = self.scopes.items.len - 1;

        var it: ReverseIterator(StringHashMap(bool)) = .init(self.scopes.items);
        while (it.next()) |entry| {
            if (entry.value_ptr.contains(name.lexeme)) {
                try self.resolved.put(expr, last - entry.index);
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

        var scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.contains(value.lexeme)) {
            return try self.report(value, "Already a variable with this name in this scope.");
        }
        try scope.put(value.lexeme, false);
    }

    fn define(self: *Resolver, value: Token) !void {
        if (self.scopes.items.len == 0) return;

        var scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(value.lexeme, true);
    }

    fn report(self: Resolver, value: Token, message: []const u8) !void {
        try self.ctx.report(
            "[{}]: '{s}' {s}\n",
            .{ value.line, value.lexeme, message },
        );
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
    try testResolver(
        \\ var a = "hello";
        \\ { print a; }
    , &.{});

    try testResolver(
        \\ {
        \\   var a;
        \\   {
        \\     a = "hello";
        \\   }
        \\ }
    , &.{
        .{ "a", 1 },
    });

    try testResolver(
        \\ var a = "global";
        \\ {
        \\    fun showA() {
        \\      print a;
        \\    }
        \\
        \\    showA();
        \\    var a = "block";
        \\    showA();
        \\ }
    , &.{
        .{ "showA", 0 },
    });
}

test "fails resolver" {
    try testFailResolver(
        \\ { 
        \\   var a = "hello";
        \\   var a = "world";
        \\ }
    , "[3]: 'a' Already a variable with this name in this scope.\n");

    try testFailResolver(
        \\ return "at top level";
    , "[1]: 'return' Can't return from top-level code.\n");
}

fn testResolver(source: [:0]const u8, expexted_list: []const struct { []const u8, usize }) !void {
    const gpa = testing.allocator;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Ctx = .init(undefined, .{ .err = &stream, .out = &stream });

    var tree = try analyzer.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    var resolver: Resolver = .init(gpa, &ctx);
    defer resolver.deinit();

    var resolved = try resolver.resolve(tree.list);
    defer resolved.deinit();

    var it = resolved.iterator();
    outer: while (it.next()) |entry| {
        const name = switch (entry.key_ptr.*.*) {
            .assign => |assign| assign.name.lexeme,
            .variable => |variable| variable.name.lexeme,
            else => "",
        };
        for (expexted_list) |expected| {
            if (mem.eql(u8, expected[0], name)) {
                try testing.expectEqual(expected[1], entry.value_ptr.*);
                continue :outer;
            }
        }
        return error.NotFoundLocal;
    }
}

fn testFailResolver(source: [:0]const u8, error_message: []const u8) !void {
    const gpa = testing.allocator;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Ctx = .init(undefined, .{ .err = &stream, .out = &stream });

    var tree = try analyzer.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    var resolver: Resolver = .init(gpa, &ctx);
    defer resolver.deinit();

    var resolved = try resolver.resolve(tree.list);
    defer resolved.deinit();

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

const analyzer = @import("analyzer.zig");
const ast = @import("ast.zig");
const Ctx = @import("Context.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
