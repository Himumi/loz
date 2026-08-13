/// print prints expression into (not)pretty format.
pub fn printExpr(writer: *Io.Writer, value: *ast.Expr) Io.Writer.Error!void {
    var printer: Printer = .init;
    try printer.printExpr(writer, value);
}

pub fn printStmt(writer: *Io.Writer, value: *ast.Stmt) Io.Writer.Error!void {
    var printer: Printer = .init;
    try printer.printStmt(writer, value);
}

pub const Printer = struct {
    pub const init: Printer = .{};

    pub fn printExpr(self: *Printer, writer: *Io.Writer, value: *ast.Expr) Io.Writer.Error!void {
        return switch (value.*) {
            .binary => |binary| {
                try self.parenthesize(writer, "{s}", .{binary.operator.tag.symbol()}, &.{
                    binary.left,
                    binary.right,
                });
            },
            .call => |call| {
                try writer.writeAll("(call ");
                try self.printExpr(writer, call.callee);
                try writer.print(" '{s}'", .{call.paren.tag.symbol()});
                if (call.args.len > 0) {
                    try writer.writeByte(' ');
                    try self.parenthesize(writer, "args", .{}, call.args);
                }
                try writer.writeByte(')');
            },
            .get => |get| {
                try self.parenthesize(writer, "get {s}", .{get.name.lexeme}, &.{get.object});
            },
            .grouping => |group| {
                try self.parenthesize(writer, "group", .{}, &.{group.expression});
            },
            .unary => |unary| {
                try self.parenthesize(writer, "{s}", .{unary.operator.tag.symbol()}, &.{
                    unary.right,
                });
            },
            .literal => |literal| {
                try literal.value.toPrint(writer);
            },
            .logical => |logical| {
                try self.parenthesize(writer, "{s}", .{logical.operator.tag.symbol()}, &.{
                    logical.left,
                    logical.right,
                });
            },
            .set => |set| {
                try self.parenthesize(writer, "set {s}", .{set.name.lexeme}, &.{
                    set.object,
                    set.value,
                });
            },
            .variable => |variable| {
                try writer.writeAll(variable.name.lexeme);
            },
            .assign => |assign| {
                try self.parenthesize(writer, "assign {s}", .{assign.name.lexeme}, &.{
                    assign.value,
                });
            },
            .this => |this| {
                try self.parenthesize(writer, "this {s}", .{this.name.lexeme}, &.{});
            },
        };
    }

    pub fn printStmt(self: *Printer, writer: *Io.Writer, value: *ast.Stmt) Io.Writer.Error!void {
        switch (value.*) {
            .expr_statement => |expr_statement| {
                try self.printExpr(writer, expr_statement.expression);
            },
            .fun_statement => |fun_statement| {
                try self.parenthesizeStmt(
                    writer,
                    "fun {s}",
                    .{fun_statement.name.lexeme},
                    fun_statement.body.list,
                );
            },
            .if_statement => |if_statement| {
                var condition_stmt: ast.Stmt = .{ .expr_statement = .init(if_statement.condition) };
                const stmts: []const *ast.Stmt =
                    if (if_statement.else_stmt) |else_stmt|
                        &.{ &condition_stmt, if_statement.then_stmt, else_stmt }
                    else
                        &.{ &condition_stmt, if_statement.then_stmt };
                try self.parenthesizeStmt(writer, "if", .{}, stmts);
            },
            .print_statement => |print_statement| {
                try self.parenthesize(writer, "print", .{}, &.{print_statement.expression});
            },
            .return_statement => |return_statement| {
                if (return_statement.value) |exp| {
                    try self.parenthesize(writer, "return", .{}, &.{exp});
                } else {
                    try self.parenthesize(writer, "return", .{}, &.{});
                }
            },
            .var_statement => |var_statement| {
                const exprs: []const *ast.Expr =
                    if (var_statement.initializer) |initializer| &.{initializer} else &.{};
                try self.parenthesize(writer, "var {s}", .{var_statement.name.lexeme}, exprs);
            },
            .while_statement => |while_statement| {
                var condition_stmt: ast.Stmt = .{
                    .expr_statement = .init(while_statement.condition),
                };
                try self.parenthesizeStmt(writer, "while", .{}, &.{
                    &condition_stmt,
                    while_statement.body,
                });
            },
            .block_statement => |block_statement| {
                try self.parenthesizeStmt(writer, "block", .{}, block_statement.list);
            },
            .class_statement => |class_statement| {
                try self.parenthesizeStmt(
                    writer,
                    "class {s}",
                    .{class_statement.name.lexeme},
                    class_statement.methods,
                );
            },
        }
    }

    fn parenthesize(
        self: *Printer,
        writer: *Io.Writer,
        comptime fmt: []const u8,
        agrs: anytype,
        exprs: []const *ast.Expr,
    ) Io.Writer.Error!void {
        try writer.writeByte('(');
        try writer.print(fmt, agrs);
        for (exprs) |expr| {
            try writer.writeByte(' ');
            try self.printExpr(writer, expr);
        }
        try writer.writeByte(')');
    }

    fn parenthesizeStmt(
        self: *Printer,
        writer: *Io.Writer,
        comptime fmt: []const u8,
        args: anytype,
        stmts: []const *ast.Stmt,
    ) Io.Writer.Error!void {
        try writer.writeByte('(');
        try writer.print(fmt, args);
        for (stmts) |stmt| {
            try writer.writeByte(' ');
            try self.printStmt(writer, stmt);
        }
        try writer.writeByte(')');
    }
};

test "Ast Printer" {
    var buffer: [256]u8 = undefined;
    var stream: Io.Writer = .fixed(&buffer);

    try testAstPrinter(&stream, "10", @constCast(&ast.Expr{
        .literal = .init(ast.Object{ .number = 10 }),
    }));
    try testAstPrinter(&stream, "10.1", @constCast(&ast.Expr{
        .literal = .init(ast.Object{ .number = 10.1 }),
    }));
    try testAstPrinter(&stream, "hello", @constCast(&ast.Expr{
        .literal = .init(ast.Object{ .string = "hello" }),
    }));
    try testAstPrinter(&stream, "true", @constCast(&ast.Expr{
        .literal = .init(ast.Object{ .boolean = true }),
    }));
    try testAstPrinter(&stream, "false", @constCast(&ast.Expr{
        .literal = .init(ast.Object{ .boolean = false }),
    }));

    try testAstPrinter(&stream, "(group 10)", @constCast(&ast.Expr{
        .grouping = .init(@constCast(&ast.Expr{
            .literal = .init(ast.Object{ .number = 10 }),
        })),
    }));

    try testAstPrinter(&stream, "(- 10)", @constCast(&ast.Expr{
        .unary = .init(
            Token.init(.minus, "-", 1),
            @constCast(&ast.Expr{ .literal = .init(ast.Object{ .number = 10 }) }),
        ),
    }));

    try testAstPrinter(&stream, "(+ 10 20)", @constCast(&ast.Expr{
        .binary = .init(
            @constCast(&ast.Expr{ .literal = .init(ast.Object{ .number = 10 }) }),
            .init(.plus, "+", 1),
            @constCast(&ast.Expr{ .literal = .init(ast.Object{ .number = 20 }) }),
        ),
    }));

    try testAstPrinter(&stream, "(* (- 123) (group 45.67))", @constCast(&ast.Expr{
        .binary = .{
            .left = @constCast(&ast.Expr{
                .unary = .{
                    .operator = .init(.minus, "-", 1),
                    .right = @constCast(&ast.Expr{
                        .literal = .{ .value = .{ .number = 123 } },
                    }),
                },
            }),
            .operator = .init(.star, "*", 1),
            .right = @constCast(&ast.Expr{
                .grouping = .{ .expression = @constCast(&ast.Expr{
                    .literal = .{ .value = .{ .number = 45.67 } },
                }) },
            }),
        },
    }));
}

fn testAstPrinter(writer: *Io.Writer, expected: []const u8, expression: *ast.Expr) !void {
    try printExpr(writer, expression);
    try testing.expectEqualSlices(u8, expected, writer.buffered());
    writer.end = 0;
}

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
