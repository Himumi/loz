/// print prints expression into (not)pretty format.
pub fn print(writer: *Io.Writer, tree: ast.Ast, node: u32) Io.Writer.Error!void {
    var printer: Printer = .init(writer, tree);
    try printer.print(node, 0);
}

pub const Printer = struct {
    writer: *Io.Writer,
    tree: ast.Ast,

    pub fn init(writer: *Io.Writer, tree: ast.Ast) Printer {
        return .{
            .writer = writer,
            .tree = tree,
        };
    }

    pub fn print(self: *Printer, indent: usize, node: u32) Io.Writer.Error!void {
        const value = self.tree.nodes.get(node);
        return switch (value.tag) {
            // Expressions //

            .binary => {
                const operator = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "{s}", .{operator.tag.symbol()}, &.{
                    value.data.lhs, // Left Expr
                    value.data.rhs, // Right Expr
                });
            },
            .call => {
                try self.writer.writeAll("(call ");
                try self.print(indent, value.data.lhs); // Callee Expr

                const paren = self.tree.tokens.get(value.token);
                try self.writer.print(" '{s}'", .{paren.tag.symbol()});

                const offset = value.data.rhs + 1;
                const len = self.tree.getExtra(value.data.rhs);
                if (len > 0) {
                    try self.writer.writeByte(' ');
                    const args = self.tree.sliceExtra(offset, offset + len);
                    try self.parenthesize(indent, "args", .{}, args);
                }
                try self.writer.writeByte(')');
            },
            .get => {
                const name = self.tree.tokens.get(value.token);
                try self.parenthesize(
                    indent,
                    "get {s}",
                    .{name.lexeme(self.tree.source)},
                    &.{value.data.lhs}, // Object Expr
                );
            },
            .group => {
                try self.parenthesize(indent, "group", .{}, &.{
                    value.data.lhs, // Expression Expr
                });
            },
            .unary => {
                const operator = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "{s}", .{operator.tag.symbol()}, &.{
                    value.data.lhs, // Right Expr
                });
            },
            .literal => {
                const literal = self.tree.literals[value.data.lhs];
                try literal.dump(self.writer);
            },
            .logical => {
                const operator = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "{s}", .{operator.tag.symbol()}, &.{
                    value.data.lhs, // Left Expr
                    value.data.rhs, // Right Expr
                });
            },
            .set => {
                const name = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "set {s}", .{name.lexeme(self.tree.source)}, &.{
                    value.data.lhs, // Object Expr
                    value.data.rhs, // Value Expr
                });
            },
            .variable => {
                const name = self.tree.tokens.get(value.token);
                try self.writer.writeAll(name.lexeme(self.tree.source));
            },
            .assign => {
                const name = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "assign {s}", .{name.lexeme(self.tree.source)}, &.{
                    value.data.lhs, // Value Expr
                });
            },
            .this => {
                const name = self.tree.tokens.get(value.token);
                try self.parenthesize(indent, "this {s}", .{name.lexeme(self.tree.source)}, &.{});
            },

            // Statements //

            .expr => {
                try self.print(indent, value.data.lhs); // Expressions Expr
            },
            .fun => {
                const name = self.tree.tokens.get(value.token);
                try self.writer.print("(fun {s}", .{name.lexeme(self.tree.source)});

                const len = self.tree.getExtra(value.data.lhs);
                if (len > 0) {
                    const offset = value.data.lhs + 1;
                    for (self.tree.sliceExtra(offset, offset + len)) |index| {
                        try self.writer.writeByte(' ');
                        const param = self.tree.getToken(index);
                        try self.writer.print("{s}", .{param.lexeme(self.tree.source)});
                    }
                }

                try self.writer.writeByte(' ');
                try self.print(indent, value.data.rhs);
                try self.writer.writeByte(')');
            },
            .@"if" => {
                const stmts = blk: {
                    const extra = self.tree.extra;
                    const offset = value.data.rhs + 1;

                    if (self.tree.extra[value.data.rhs] > 1) {
                        break :blk &.{
                            value.data.lhs, // Condition Expr
                            extra[offset], // Then Stmt
                            extra[offset + 1], // Else Stmt
                        };
                    } else {
                        break :blk &.{
                            value.data.lhs, // Condition Expr
                            extra[offset], // Then Stmt
                        };
                    }
                };
                try self.parenthesize(indent, "if", .{}, stmts);
            },
            .print => {
                try self.parenthesize(indent, "print", .{}, &.{value.data.lhs});
            },
            .@"return" => {
                if (value.data.lhs == 0) {
                    try self.parenthesize(indent, "return", .{}, &.{});
                } else {
                    try self.parenthesize(indent, "return", .{}, &.{
                        value.data.lhs, // Value Expr
                    });
                }
            },
            .@"var" => {
                const lexeme = self.tree.tokens.get(value.token).lexeme(self.tree.source);
                if (value.data.lhs == 0) {
                    try self.parenthesize(indent, "var {s}", .{lexeme}, &.{});
                } else {
                    try self.parenthesize(indent, "var {s}", .{lexeme}, &.{
                        value.data.lhs, // Initializer Expr
                    });
                }
            },
            .@"while" => {
                try self.parenthesize(indent, "while", .{}, &.{
                    value.data.lhs, // Condition Expr
                    value.data.rhs, // Body Stmt
                });
            },
            .block => {
                const list = self.tree.extra[value.data.lhs..value.data.rhs];
                try self.parenthesizeIndent(indent, "block", .{}, list);
            },
            .class => {
                const lexeme = self.tree.tokens.get(value.token).lexeme(self.tree.source);
                const list = self.tree.extra[value.data.lhs..value.data.rhs];
                try self.parenthesizeIndent(indent, "class {s}", .{lexeme}, list);
            },
        };
    }

    fn parenthesize(
        self: *Printer,
        indent: usize,
        comptime fmt: []const u8,
        agrs: anytype,
        exprs: []const u32,
    ) Io.Writer.Error!void {
        try self.writer.writeByte('(');
        try self.writer.print(fmt, agrs);
        for (exprs) |expr| {
            try self.writer.writeByte(' ');
            try self.print(indent, expr);
        }
        try self.writer.writeByte(')');
    }

    fn parenthesizeIndent(
        self: *Printer,
        indent: usize,
        comptime fmt: []const u8,
        agrs: anytype,
        exprs: []const u32,
    ) Io.Writer.Error!void {
        try self.writer.writeByte('(');
        try self.writer.print(fmt, agrs);
        try self.writer.writeByte('\n');
        for (exprs) |index| {
            try self.writer.splatByteAll(' ', indent + 2);
            try self.print(indent + 2, index);
            try self.writer.writeByte('\n');
        }
        try self.writer.splatByteAll(' ', indent);
        try self.writer.writeByte(')');
    }
};

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
