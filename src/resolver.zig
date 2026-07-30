pub fn resolve(gpa: Allocator, ctx: *Ctx, list: []const *ast.Stmt) !AutoHashMap(*ast.Expr, usize) {
    var resolver: Resolver = .init(gpa);
    defer resolver.deinit();
    // Transfer the result to the caller.
    return try resolver.resolve(ctx, list);
}

pub const Resolver = struct {
    allocator: Allocator,
    // The scope does not own the keys' ownership.
    scopes: ArrayList(StringHashMap(bool)),
    // The locals does not own the keys' ownership.
    locals: AutoHashMap(*ast.Expr, usize),
    current_fun: FunType = .none,

    const FunType = enum { none, function };

    pub const Error = Allocator.Error || Io.Writer.Error;

    pub fn init(gpa: Allocator) Resolver {
        return .{
            .allocator = gpa,
            .scopes = .empty,
            .locals = .init(gpa),
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
        self.locals.deinit();
    }

    pub fn resolve(
        self: *Resolver,
        ctx: *Ctx,
        list: []const *ast.Stmt,
    ) Error!AutoHashMap(*ast.Expr, usize) {
        try self.resolveStmtList(ctx, list);
        // Transfer the locals to the caller.
        return self.locals.move();
    }

    fn resolveStmtList(self: *Resolver, ctx: *Ctx, list: []const *ast.Stmt) Error!void {
        for (list) |stmt| {
            try self.resolveStmt(ctx, stmt);
        }
    }

    fn resolveStmt(self: *Resolver, ctx: *Ctx, stmt: *ast.Stmt) Error!void {
        switch (stmt.*) {
            .block_statement => |block_stmt| {
                try self.begin();
                try self.resolveStmtList(ctx, block_stmt.list);
                try self.end();
            },
            .var_statement => |var_stmt| {
                try self.declare(ctx, var_stmt.name);
                if (var_stmt.initializer) |initializer| {
                    try self.resolveExpr(ctx, initializer);
                }
                try self.define(var_stmt.name);
            },
            .fun_statement => |fun_stmt| {
                try self.declare(ctx, fun_stmt.name);
                try self.define(fun_stmt.name);
                try self.resolveFun(ctx, fun_stmt, .function);
            },
            .expr_statement => |expr_stmt| {
                try self.resolveExpr(ctx, expr_stmt.expression);
            },
            .if_statement => |if_stmt| {
                try self.resolveExpr(ctx, if_stmt.condition);
                try self.resolveStmt(ctx, if_stmt.then_stmt);
                if (if_stmt.else_stmt) |else_stmt| {
                    try self.resolveStmt(ctx, else_stmt);
                }
            },
            .print_statement => |print_stmt| {
                try self.resolveExpr(ctx, print_stmt.expression);
            },
            .return_statement => |return_stmt| {
                if (self.current_fun == .none) {
                    try ctx.report(
                        "'{s}' Can't return from top-level code.\n",
                        .{return_stmt.keyword.lexeme},
                    );
                }
                if (return_stmt.value) |value| {
                    try self.resolveExpr(ctx, value);
                }
            },
            .while_statement => |while_stmt| {
                try self.resolveExpr(ctx, while_stmt.condition);
                try self.resolveStmt(ctx, while_stmt.body);
            },
        }
    }

    fn resolveExpr(self: *Resolver, ctx: *Ctx, expr: *ast.Expr) Error!void {
        switch (expr.*) {
            .variable => |variable| {
                if (self.scopes.items.len == 0) return;

                const scope = self.scopes.getLast();
                if (scope.get(variable.name.lexeme)) |value| {
                    if (value == false) {
                        try ctx.report(
                            "'{s}' Can't read local variable in its own initializer.\n",
                            .{variable.name.lexeme},
                        );
                    }
                }

                try self.resolveLocal(expr, variable.name);
                return;
            },
            .assign => |assign| {
                try self.resolveExpr(ctx, assign.value);
                try self.resolveLocal(expr, assign.name);
            },
            .binary => |binary| {
                try self.resolveExpr(ctx, binary.left);
                try self.resolveExpr(ctx, binary.right);
            },
            .call => |call| {
                try self.resolveExpr(ctx, call.callee);
                for (call.args) |arg| {
                    try self.resolveExpr(ctx, arg);
                }
            },
            .grouping => |group| {
                try self.resolveExpr(ctx, group.expression);
            },
            .literal => {},
            .logical => |logical| {
                try self.resolveExpr(ctx, logical.left);
                try self.resolveExpr(ctx, logical.right);
            },
            .unary => |unary| {
                try self.resolveExpr(ctx, unary.right);
            },
        }
    }

    fn resolveFun(
        self: *Resolver,
        ctx: *Ctx,
        fun_stmt: ast.Function,
        fun_type: FunType,
    ) Error!void {
        const enclosing = self.current_fun;
        defer self.current_fun = enclosing;

        try self.begin();
        self.current_fun = fun_type;

        for (fun_stmt.params) |param| {
            try self.declare(ctx, param);
            try self.define(param);
        }

        try self.resolveStmtList(ctx, fun_stmt.body.list);
        try self.end();
    }

    fn resolveLocal(self: *Resolver, expr: *ast.Expr, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        const last = self.scopes.items.len - 1;

        var it: ReverseIterator(StringHashMap(bool)) = .init(self.scopes.items);
        while (it.next()) |entry| {
            if (entry.value_ptr.contains(name.lexeme)) {
                try self.locals.put(expr, last - entry.index);
            }
        }
    }

    fn begin(self: *Resolver) Error!void {
        try self.scopes.append(self.allocator, .init(self.allocator));
    }

    fn end(self: *Resolver) Error!void {
        var scope = self.scopes.pop() orelse unreachable;
        scope.deinit();
    }

    fn declare(self: *Resolver, ctx: *Ctx, value: Token) Error!void {
        if (self.scopes.items.len == 0) return;

        var scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.contains(value.lexeme)) {
            try ctx.report(
                "'{s}' Already a variable with this name in this scope.\n",
                .{value.lexeme},
            );
        }
        try scope.put(value.lexeme, false);
    }

    fn define(self: *Resolver, value: Token) Error!void {
        if (self.scopes.items.len == 0) return;

        var scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(value.lexeme, true);
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
    , "'a' Already a variable with this name in this scope.\n");

    try testFailResolver(
        \\ return "at top level";
    , "'return' Can't return from top-level code.\n");
}

fn testResolver(source: [:0]const u8, expexted_list: []const struct { []const u8, usize }) !void {
    const gpa = testing.allocator;

    var stream_buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&stream_buffer);

    var ctx: Ctx = .init(undefined, .{ .err = &stream, .out = &stream });

    var tree = try analyzer.parse(gpa, &ctx, source);
    defer tree.deinit(gpa);

    var resolver: Resolver = .init(gpa);
    defer resolver.deinit();

    var locals = try resolver.resolve(&ctx, tree.list);
    defer locals.deinit();

    var it = locals.iterator();
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

    var resolver: Resolver = .init(gpa);
    defer resolver.deinit();

    var locals = try resolver.resolve(&ctx, tree.list);
    defer locals.deinit();

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
