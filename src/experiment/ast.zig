// Expressions //
pub const Ast = struct {
    source: [:0]const u8, // A static memory.
    list: []const *Stmt,

    pub fn init(source: [:0]const u8, list: []const *Stmt) Ast {
        return .{
            .source = source,
            .list = list,
        };
    }

    pub fn deinit(self: Ast, gpa: Allocator) void {
        for (self.list) |stmt| stmt.destroy(gpa);
        gpa.free(self.list);
    }
};

pub const Expr = union(enum) {
    binary: Binary,
    call: Call,
    grouping: Grouping,
    unary: Unary,
    literal: Literal,
    logical: Logical,
    variable: Variable,
    assign: Assign,

    pub fn destroy(self: *Expr, gpa: Allocator) void {
        switch (self.*) {
            .binary => |binary| binary.deinit(gpa),
            .call => |call| call.deinit(gpa),
            .grouping => |group| group.deinit(gpa),
            .unary => |unary| unary.deinit(gpa),
            // It does not need to destroy Value in literal and variable expressions.
            // Expr only lives in parser lifetime not runtime lifetime.
            .literal,
            .variable,
            => {},
            .logical => |logical| logical.deinit(gpa),
            .assign => |assign| assign.deinit(gpa),
        }
        gpa.destroy(self);
    }
};

pub const Binary = struct {
    left: *Expr,
    operator: Token,
    right: *Expr,

    pub fn init(left: *Expr, operator: Token, right: *Expr) Binary {
        return .{
            .left = left,
            .operator = operator,
            .right = right,
        };
    }

    pub fn deinit(self: Binary, gpa: Allocator) void {
        self.left.destroy(gpa);
        self.right.destroy(gpa);
    }

    pub fn create(
        gpa: Allocator,
        left: *Expr,
        operator: Token,
        right: *Expr,
    ) Allocator.Error!*Expr {
        const binary = try gpa.create(Expr);
        binary.* = .{ .binary = .init(left, operator, right) };
        return binary;
    }
};

pub const Call = struct {
    callee: *Expr,
    paren: Token,
    args: []const *Expr,

    pub fn init(callee: *Expr, paren: Token, args: []const *Expr) Call {
        return .{
            .callee = callee,
            .paren = paren,
            .args = args,
        };
    }

    pub fn deinit(self: Call, gpa: Allocator) void {
        self.callee.destroy(gpa);
        for (self.args) |arg| arg.destroy(gpa);
        gpa.free(self.args);
    }

    pub fn create(gpa: Allocator, call: Call) Allocator.Error!*Expr {
        const call_exp = try gpa.create(Expr);
        call_exp.* = .{ .call = call };
        return call_exp;
    }
};

pub const Grouping = struct {
    expression: *Expr,

    pub fn init(expression: *Expr) Grouping {
        return .{ .expression = expression };
    }

    pub fn deinit(self: Grouping, gpa: Allocator) void {
        self.expression.destroy(gpa);
    }

    pub fn create(gpa: Allocator, expression: *Expr) Allocator.Error!*Expr {
        const group = try gpa.create(Expr);
        group.* = .{ .grouping = .init(expression) };
        return group;
    }
};

pub const Unary = struct {
    operator: Token,
    right: *Expr,

    pub fn init(operator: Token, right: *Expr) Unary {
        return .{ .operator = operator, .right = right };
    }

    pub fn deinit(self: Unary, gpa: Allocator) void {
        self.right.destroy(gpa);
    }

    pub fn create(gpa: Allocator, operator: Token, right: *Expr) Allocator.Error!*Expr {
        const unary = try gpa.create(Expr);
        unary.* = .{ .unary = .init(operator, right) };
        return unary;
    }
};

pub const Literal = struct {
    value: Object,

    pub fn init(value: Object) Literal {
        return .{ .value = value };
    }

    pub fn create(gpa: Allocator, value: Object) Allocator.Error!*Expr {
        const literal = try gpa.create(Expr);
        literal.* = .{ .literal = .init(value) };
        return literal;
    }
};

pub const Logical = struct {
    left: *Expr,
    operator: Token,
    right: *Expr,

    pub fn init(left: *Expr, operator: Token, right: *Expr) Logical {
        return .{
            .left = left,
            .operator = operator,
            .right = right,
        };
    }

    pub fn deinit(self: Logical, gpa: Allocator) void {
        self.left.destroy(gpa);
        self.right.destroy(gpa);
    }

    pub fn create(
        gpa: Allocator,
        left: *Expr,
        operator: Token,
        right: *Expr,
    ) Allocator.Error!*Expr {
        const logical = try gpa.create(Expr);
        logical.* = .{ .logical = .init(left, operator, right) };
        return logical;
    }
};

pub const Variable = struct {
    name: Token,

    pub fn init(name: Token) Variable {
        return .{ .name = name };
    }

    pub fn create(gpa: Allocator, name: Token) Allocator.Error!*Expr {
        const variable = try gpa.create(Expr);
        variable.* = .{ .variable = .init(name) };
        return variable;
    }
};

pub const Assign = struct {
    name: Token,
    value: *Expr,

    pub fn init(name: Token, value: *Expr) Assign {
        return .{ .name = name, .value = value };
    }

    pub fn deinit(self: Assign, gpa: Allocator) void {
        self.value.destroy(gpa);
    }

    pub fn create(gpa: Allocator, name: Token, value: *Expr) Allocator.Error!*Expr {
        const assign = try gpa.create(Expr);
        assign.* = .{ .assign = .init(name, value) };
        return assign;
    }
};

// Statement //

pub const Stmt = union(enum) {
    expr_statement: Expression,
    fun_statement: Function,
    if_statement: IF,
    print_statement: Print,
    return_statement: Return,
    var_statement: Var,
    while_statement: While,
    block_statement: Block,

    pub fn destroy(self: *Stmt, gpa: Allocator) void {
        switch (self.*) {
            .expr_statement => |expr_statement| expr_statement.deinit(gpa),
            .fun_statement => |fun_statement| fun_statement.deinit(gpa),
            .if_statement => |if_statement| if_statement.deinit(gpa),
            .print_statement => |print_statement| print_statement.deinit(gpa),
            .return_statement => |return_statement| return_statement.deinit(gpa),
            .var_statement => |var_statement| var_statement.deinit(gpa),
            .while_statement => |while_statemnet| while_statemnet.deinit(gpa),
            .block_statement => |block_statement| block_statement.deinit(gpa),
        }
        gpa.destroy(self);
    }
};

pub const Expression = struct {
    expression: *Expr,

    pub fn init(expression: *Expr) Expression {
        return .{ .expression = expression };
    }

    pub fn deinit(self: Expression, gpa: Allocator) void {
        self.expression.destroy(gpa);
    }

    pub fn create(gpa: Allocator, expression: *Expr) !*Stmt {
        const expr_statement = try gpa.create(Stmt);
        expr_statement.* = .{ .expr_statement = .init(expression) };
        return expr_statement;
    }
};

pub const Function = struct {
    name: Token,
    params: []const Token,
    body: Block,

    pub fn init(name: Token, params: []const Token, body: Block) Function {
        return .{
            .name = name,
            .params = params,
            .body = body,
        };
    }

    pub fn deinit(self: Function, gpa: Allocator) void {
        self.body.deinit(gpa);
        gpa.free(self.params);
    }

    pub fn create(gpa: Allocator, fun: Function) Allocator.Error!*Stmt {
        const fun_statement = try gpa.create(Stmt);
        fun_statement.* = .{ .fun_statement = fun };
        return fun_statement;
    }
};

pub const IF = struct {
    condition: *Expr,
    then_stmt: *Stmt,
    else_stmt: ?*Stmt,

    pub fn init(condition: *Expr, then_stmt: *Stmt, else_stmt: ?*Stmt) IF {
        return .{
            .condition = condition,
            .then_stmt = then_stmt,
            .else_stmt = else_stmt,
        };
    }

    pub fn deinit(self: IF, gpa: Allocator) void {
        self.condition.destroy(gpa);
        self.then_stmt.destroy(gpa);
        if (self.else_stmt) |stmt| stmt.destroy(gpa);
    }

    pub fn create(gpa: Allocator, condition: *Expr, then_stmt: *Stmt, else_stmt: ?*Stmt) !*Stmt {
        const if_statement = try gpa.create(Stmt);
        if_statement.* = .{ .if_statement = .init(condition, then_stmt, else_stmt) };
        return if_statement;
    }
};

pub const Print = struct {
    expression: *Expr,

    pub fn init(expression: *Expr) Print {
        return .{ .expression = expression };
    }

    pub fn deinit(self: Print, gpa: Allocator) void {
        self.expression.destroy(gpa);
    }

    pub fn create(gpa: Allocator, expression: *Expr) !*Stmt {
        const print_statement = try gpa.create(Stmt);
        print_statement.* = .{ .print_statement = .init(expression) };
        return print_statement;
    }
};

pub const Return = struct {
    keyword: Token,
    value: ?*Expr,

    pub fn init(keyword: Token, value: ?*Expr) Return {
        return .{
            .keyword = keyword,
            .value = value,
        };
    }

    pub fn deinit(self: Return, gpa: Allocator) void {
        if (self.value) |value| value.destroy(gpa);
    }

    pub fn create(gpa: Allocator, keyword: Token, value: ?*Expr) Allocator.Error!*Stmt {
        const return_statement = try gpa.create(Stmt);
        return_statement.* = .{ .return_statement = .init(keyword, value) };
        return return_statement;
    }
};

pub const Var = struct {
    name: Token,
    initializer: ?*Expr,

    pub fn init(name: Token, initializer: ?*Expr) Var {
        return .{
            .name = name,
            .initializer = initializer,
        };
    }

    pub fn deinit(self: Var, gpa: Allocator) void {
        if (self.initializer) |initializer| {
            initializer.destroy(gpa);
        }
    }

    pub fn create(gpa: Allocator, name: Token, initializer: ?*Expr) !*Stmt {
        const var_statement = try gpa.create(Stmt);
        var_statement.* = .{ .var_statement = .init(name, initializer) };
        return var_statement;
    }
};

pub const While = struct {
    condition: *Expr,
    body: *Stmt,

    pub fn init(condition: *Expr, body: *Stmt) While {
        return .{
            .condition = condition,
            .body = body,
        };
    }

    pub fn deinit(self: While, gpa: Allocator) void {
        self.condition.destroy(gpa);
        self.body.destroy(gpa);
    }

    pub fn create(gpa: Allocator, condition: *Expr, body: *Stmt) Allocator.Error!*Stmt {
        const while_statemnet = try gpa.create(Stmt);
        while_statemnet.* = .{ .while_statement = .init(condition, body) };
        return while_statemnet;
    }
};

pub const Block = struct {
    list: []const *Stmt,

    pub fn init(list: []const *Stmt) Block {
        return .{
            .list = list,
        };
    }

    pub fn deinit(self: Block, gpa: Allocator) void {
        for (self.list) |statement| {
            statement.destroy(gpa);
        }
        gpa.free(self.list);
    }

    pub fn create(gpa: Allocator, block: Block) !*Stmt {
        const block_statement = try gpa.create(Stmt);
        block_statement.* = .{ .block_statement = block };
        return block_statement;
    }

    pub fn dupeFrom(gpa: Allocator, list: []const *Stmt) !*Stmt {
        const block_list = try gpa.dupe(*Stmt, list);
        errdefer gpa.free(block_list);
        return try Block.create(gpa, .init(block_list));
    }
};

// Raw Values //
pub const Object = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    nil: void,
    callable: Callable, // It shared pointers

    pub fn deinit(self: Object, gpa: Allocator) void {
        switch (self) {
            .string => |string| gpa.free(string),
            else => {},
        }
    }

    /// Use dupe to duplicate it in different lifetimes.
    pub fn dupe(self: Object, gpa: Allocator) Allocator.Error!Object {
        return switch (self) {
            .string => |string| return .{
                .string = try gpa.dupe(u8, string),
            },
            else => return self,
        };
    }

    pub fn dupeMany(gpa: Allocator, objects: []const Object) Allocator.Error!Object {
        var list: ArrayList(Object) = try .initCapacity(gpa, objects.len);
        defer {
            for (list.items) |item| item.deinit(gpa);
            list.deinit(gpa);
        }

        for (objects) |object| {
            const duplicated = try object.dupe(gpa);
            errdefer duplicated.deinit(gpa);
            try list.append(gpa, duplicated);
        }

        return try list.toOwnedSlice(gpa);
    }

    pub fn isNumber(self: Object) bool {
        return self == .number;
    }

    pub fn isString(self: Object) bool {
        return self == .string;
    }

    pub fn isBoolean(self: Object) bool {
        return self == .boolean;
    }

    pub fn isNil(self: Object) bool {
        return self == .nil;
    }

    pub fn isCallable(self: Object) bool {
        return self == .callable;
    }

    pub fn isSameTypeWith(self: Object, b: Object) bool {
        const is_boolean = self.isBoolean() and b.isBoolean();
        const is_number = self.isNumber() and b.isNumber();
        const is_string = self.isString() and b.isString();
        const is_nil = self.isNil() and b.isNil();
        const is_callable = self.isCallable() and b.isCallable();
        return is_boolean or is_number or is_string or is_nil or is_callable;
    }

    pub fn toPrint(self: Object, writer: *Io.Writer) Io.Writer.Error!void {
        return switch (self) {
            .string => |string| try writer.print("{s}", .{string}),
            .number => |number| try writer.print("{d}", .{number}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .callable => |callable| try callable.toPrint(writer),
            .nil => try writer.writeAll("nil"),
        };
    }

    pub fn toPrintln(self: Object, writer: *Io.Writer) Io.Writer.Error!void {
        return switch (self) {
            .string => |string| try writer.print("{s}\n", .{string}),
            .number => |number| try writer.print("{d}\n", .{number}),
            .boolean => |boolean| try writer.print("{}\n", .{boolean}),
            .callable => |callable| {
                try callable.toPrint(writer);
                try writer.writeByte('\n');
            },
            .nil => try writer.writeAll("nil\n"),
        };
    }
};

/// Callable referrences to heap stores in different places.
pub const Callable = struct {
    // It borrowed the statement from parser.
    // It does not have control to release the memory.
    stmt: *Stmt,
    // It borrowed the env from interpreter closures.
    // It does not have control to release the memory.
    closure: *Env,

    pub fn init(stmt: *Stmt, closure: *Env) Callable {
        return .{
            .stmt = stmt,
            .closure = closure,
        };
    }

    pub fn arity(self: Callable) usize {
        const fun_statement = self.stmt.fun_statement;
        return fun_statement.params.len;
    }

    pub fn toPrint(self: Callable, writer: *Io.Writer) Io.Writer.Error!void {
        const fun_statement = self.stmt.fun_statement;
        try writer.print("<fn {s}>", .{fun_statement.name.lexeme});
    }
};

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const Context = @import("Context.zig");
const Env = @import("EnvFlat.zig");
const Token = @import("tokenizer.zig").Token;
