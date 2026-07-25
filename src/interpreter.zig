// I need to create union Result type for a better error message.
pub fn render(gpa: Allocator, ctx: *Context, tree: ast.Ast) RendererError!void {
    var render_ctx: Ctx = .init(gpa, ctx);
    var renderer: Renderer = .empty;
    defer renderer.deinit(gpa);

    for (tree.list) |statement| {
        const object = try renderer.execute(&render_ctx, statement);
        object.deinit(render_ctx.allocator);
    }
}

pub fn print(gpa: Allocator, ctx: *Context, tree: ast.Ast) RendererError!void {
    var render_ctx: Ctx = .init(gpa, ctx);
    var renderer: Renderer = .empty;
    defer renderer.deinit(gpa);

    for (tree.list) |statement| {
        const object = try renderer.execute(&render_ctx, statement);
        defer object.deinit(render_ctx.allocator);

        if (object != .nil) {
            try object.toPrintln(render_ctx.stream.out);
        }
    }
}

const Ctx = struct {
    allocator: Allocator,
    io: Io,
    stream: Context.Stream,
    status: Context.Status,
    env: *Env,

    pub fn init(gpa: Allocator, ctx: *Context) Ctx {
        return .{
            .allocator = gpa,
            .io = ctx.io,
            .stream = ctx.stream,
            .status = ctx.status,
            .env = ctx.env,
        };
    }
};

pub const RendererError = Error || Io.Writer.Error || Allocator.Error || Env.Error;

const Renderer = @This();

had_return: ?ast.Object = null,
closures: ArrayList(*Env) = .empty, // Stores closures pointers.

const Error = error{
    InvalidBinaryOperands,
    InvalidUnaryOperand,
    InvalidFunctionArity,
    ExpectedCallable,
};

pub const empty: Renderer = .{
    .had_return = null,
    .closures = .empty,
};

pub fn deinit(self: *Renderer, gpa: Allocator) void {
    for (self.closures.items) |closure| {
        closure.destroy();
    }
    self.closures.deinit(gpa);
}

// Statements //

pub fn execute(self: *Renderer, ctx: *Ctx, stmt: *ast.Stmt) RendererError!ast.Object {
    return switch (stmt.*) {
        .expr_statement => |expr_stmt| try self.evaluate(ctx, expr_stmt.expression),
        .fun_statement => try funStatement(ctx, stmt),
        .if_statement => |if_stmt| try self.ifStatement(ctx, if_stmt),
        .print_statement => |print_stmt| try self.printStatement(ctx, print_stmt),
        .return_statement => |return_stmt| try self.returnStatement(ctx, return_stmt),
        .var_statement => |var_stmt| try self.varStatement(ctx, var_stmt),
        .while_statement => |while_stmt| try self.whileStatement(ctx, while_stmt),
        .block_statement => |block_stmt| try self.blockStatement(ctx, block_stmt),
    };
}

fn funStatement(ctx: *Ctx, stmt: *ast.Stmt) RendererError!ast.Object {
    if (stmt.* == .fun_statement) {
        try ctx.env.define(stmt.fun_statement.name.lexeme, .{
            // It borrowed statement and current env.
            .callable = .init(stmt, ctx.env),
        });
    }
    return .nil;
}

fn ifStatement(self: *Renderer, ctx: *Ctx, if_stmt: ast.IF) RendererError!ast.Object {
    const condition = try self.evaluate(ctx, if_stmt.condition);
    defer condition.deinit(ctx.allocator);

    if (isTruthy(condition)) {
        return try self.execute(ctx, if_stmt.then_stmt);
    } else if (if_stmt.else_stmt) |else_stmt| {
        return try self.execute(ctx, else_stmt);
    }
    return .nil;
}

fn printStatement(self: *Renderer, ctx: *Ctx, print_stmt: ast.Print) RendererError!ast.Object {
    const object = try self.evaluate(ctx, print_stmt.expression);
    defer object.deinit(ctx.allocator);

    try object.toPrintln(ctx.stream.out);
    return .nil;
}

fn returnStatement(self: *Renderer, ctx: *Ctx, return_stmt: ast.Return) RendererError!ast.Object {
    const object = blk: {
        if (return_stmt.value) |value| {
            break :blk try self.evaluate(ctx, value);
        } else {
            break :blk .nil;
        }
    };
    if (self.had_return) |return_value| {
        return_value.deinit(ctx.allocator);
    }
    self.had_return = object;

    return .nil;
}

fn varStatement(self: *Renderer, ctx: *Ctx, var_stmt: ast.Var) RendererError!ast.Object {
    const object: ast.Object = blk: {
        if (var_stmt.initializer) |init_value| {
            break :blk try self.evaluate(ctx, init_value);
        }
        break :blk .nil;
    };
    errdefer object.deinit(ctx.allocator);
    // The caller reponsibles for the value memory.
    try ctx.env.define(var_stmt.name.lexeme, object);
    return object;
}

fn whileStatement(self: *Renderer, ctx: *Ctx, while_stmt: ast.While) RendererError!ast.Object {
    while (true) {
        const condition = try self.evaluate(ctx, while_stmt.condition);
        defer condition.deinit(ctx.allocator);

        if (!isTruthy(condition)) break;

        const object = try self.execute(ctx, while_stmt.body);
        defer object.deinit(ctx.allocator);
    }
    return .nil;
}

fn blockStatement(self: *Renderer, ctx: *Ctx, block_stmt: ast.Block) RendererError!ast.Object {
    for (block_stmt.list) |value_statement| {
        const object = try self.execute(ctx, value_statement);
        defer object.deinit(ctx.allocator);

        if (self.had_return) |result| {
            self.had_return = null;
            return result;
        }
    }
    return .nil;
}

// Expressions //

fn evaluate(self: *Renderer, ctx: *Ctx, exp: *ast.Expr) RendererError!ast.Object {
    return switch (exp.*) {
        .binary => |binary| try self.binaryExpression(ctx, binary),
        .call => |call| try self.callExpression(ctx, call),
        .grouping => |group| try self.evaluate(ctx, group.expression),
        .unary => |unary| self.unaryExpression(ctx, unary),
        .literal => |literal| try literal.value.dupe(ctx.allocator),
        .logical => |logical| try self.logicalExpression(ctx, logical),
        .variable => |variable| try variableExpression(ctx, variable),
        .assign => |assign| try self.assignExpression(ctx, assign),
    };
}

fn binaryExpression(self: *Renderer, ctx: *Ctx, binary: ast.Binary) RendererError!ast.Object {
    const left = try self.evaluate(ctx, binary.left);
    defer left.deinit(ctx.allocator);

    const right = try self.evaluate(ctx, binary.right);
    defer right.deinit(ctx.allocator);

    if (binary.operator.tag == .plus) {
        if (left.isNumber() and right.isNumber()) {
            return .{ .number = left.number + right.number };
        }
        if (left.isString() and right.isString()) {
            return .{
                .string = try mem.concat(ctx.allocator, u8, &.{
                    left.string,
                    right.string,
                }),
            };
        }
        if (left.isString() and right.isNumber()) {
            return .{
                .string = try fmt.allocPrint(ctx.allocator, "{s}{}", .{
                    left.string,
                    right.number,
                }),
            };
        }
    }
    if (left.isNumber() and right.isNumber()) {
        switch (binary.operator.tag) {
            .greater => {
                return .{ .boolean = left.number > right.number };
            },
            .greater_equal => {
                return .{ .boolean = left.number >= right.number };
            },
            .less => {
                return .{ .boolean = left.number < right.number };
            },
            .less_equal => {
                return .{ .boolean = left.number <= right.number };
            },
            .minus => {
                return .{ .number = left.number - right.number };
            },
            .slash => {
                return .{ .number = left.number / right.number };
            },
            .star => {
                return .{ .number = left.number * right.number };
            },
            else => {},
        }
    }
    if (left.isSameTypeWith(right)) {
        if (binary.operator.tag == .equal_equal) {
            return .{ .boolean = isEqual(left, right) };
        }
        if (binary.operator.tag == .bang_equal) {
            return .{ .boolean = !isEqual(left, right) };
        }
    }
    return error.InvalidBinaryOperands;
}

fn callExpression(self: *Renderer, ctx: *Ctx, call: ast.Call) RendererError!ast.Object {
    var callee = try self.evaluate(ctx, call.callee);
    defer callee.deinit(ctx.allocator);

    if (!callee.isCallable()) {
        return error.ExpectedCallable;
    }

    var list: ArrayList(ast.Object) = try .initCapacity(ctx.allocator, call.args.len);
    defer {
        for (list.items) |item| {
            item.deinit(ctx.allocator);
        }
        list.deinit(ctx.allocator);
    }

    for (call.args) |arg| {
        const object = try self.evaluate(ctx, arg);
        errdefer object.deinit(ctx.allocator);
        try list.append(ctx.allocator, object);
    }

    if (list.items.len != callee.callable.arity()) {
        return error.InvalidFunctionArity;
    }

    return try self.callFn(ctx, callee.callable, list.items);
}

fn callFn(
    self: *Renderer,
    ctx: *Ctx,
    callable: ast.Callable,
    args: []const ast.Object,
) RendererError!ast.Object {
    const global_env = ctx.env;
    defer ctx.env = global_env;

    var fun_env = callable.closure;
    fun_env.enclosing = global_env;
    defer fun_env.enclosing = null;

    const local_env = try Env.create(ctx.allocator, fun_env);
    ctx.env = local_env;

    switch (callable.stmt.*) {
        .fun_statement => |fun_statement| {
            for (fun_statement.params, 0..) |param, i| {
                try ctx.env.define(param.lexeme, args[i]);
            }
            var block: ast.Stmt = .{ .block_statement = fun_statement.body };

            const object = try self.execute(ctx, &block);
            errdefer object.deinit(ctx.allocator);

            if (object != .callable) {
                // It does not need the local env anymore.
                local_env.destroy();
            } else {
                // It needs the local env for closures.
                try self.closures.append(ctx.allocator, local_env);
            }
            return object;
        },
        else => {},
    }
    return .nil;
}

fn unaryExpression(self: *Renderer, ctx: *Ctx, unary: ast.Unary) RendererError!ast.Object {
    const right = try self.evaluate(ctx, unary.right);
    defer right.deinit(ctx.allocator);

    if (unary.operator.tag == .bang) {
        return .{ .boolean = !isTruthy(right) };
    }
    if (unary.operator.tag == .minus) {
        if (right.isNumber()) {
            return .{ .number = -right.number };
        }
        return error.InvalidUnaryOperand;
    }
    return .nil;
}

fn logicalExpression(self: *Renderer, ctx: *Ctx, logical: ast.Logical) RendererError!ast.Object {
    const left = try self.evaluate(ctx, logical.left);
    errdefer left.deinit(ctx.allocator);

    if (logical.operator.tag == .keyword_or) {
        if (isTruthy(left)) return left;
    } else {
        if (!isTruthy(left)) return left;
    }
    left.deinit(ctx.allocator);
    return try self.evaluate(ctx, logical.right);
}

fn variableExpression(ctx: *Ctx, variable: ast.Variable) RendererError!ast.Object {
    // The object belongs to Env.
    const object = try ctx.env.get(variable.name.lexeme);
    return try object.dupe(ctx.allocator);
}

fn assignExpression(self: *Renderer, ctx: *Ctx, assign: ast.Assign) RendererError!ast.Object {
    const object = try self.evaluate(ctx, assign.value);
    errdefer object.deinit(ctx.allocator);
    // Duplicate the key and value using Env allocator inside the function.
    try ctx.env.assign(assign.name.lexeme, object);
    return object;
}

// Truthy values are numbers, strings, and true.
// Falsey values are false and nil.
fn isTruthy(object: ast.Object) bool {
    return switch (object) {
        .boolean => |boolean| boolean,
        .nil => false,
        else => true,
    };
}

fn isEqual(a: ast.Object, b: ast.Object) bool {
    if (a.isNil() and b.isNil()) {
        return true;
    }
    if (a.isNil()) {
        return false;
    }
    if (a.isNumber() and b.isNumber()) {
        return a.number == b.number;
    }
    if (a.isString() and b.isString()) {
        return mem.eql(u8, a.string, b.string);
    }
    if (a.isBoolean() and b.isBoolean()) {
        return a.boolean == b.boolean;
    }
    // If both side are difference types.
    return false;
}

fn panic(ctx: *Ctx, err: RendererError) RendererError!void {
    const message = try getMessage(err);
    try ctx.panic("[{}] Error: {s}\n", message);
}

fn getMessage(err: RendererError) RendererError![]const u8 {
    return switch (err) {
        error.UndefinedVariable => "Undefined Variable.",
        error.InvalidBinaryOperands => "Invalid Binary Operands.",
        error.InvalidUnaryOperand => "Invalid Unary Operand.",
        else => return err,
    };
}

test "interpreter" {
    // Literal Evaluation
    try testInterpreter("10;", "10");
    try testInterpreter("12.34;", "12.34");
    try testInterpreter("false;", "false");
    try testInterpreter(
        \\ "Hello world";
    , "Hello world");
    try testInterpreter("nil;", "");

    // Grouping Evaluation
    try testInterpreter("(10);", "10");
    try testInterpreter("(12.34);", "12.34");
    try testInterpreter("(true);", "true");
    try testInterpreter(
        \\ ("Hello World");
    , "Hello World");
    try testInterpreter("(nil);", "");

    // Binary Evaluation
    try testInterpreter("10 + 10;", "20");
    try testInterpreter(
        \\ "Hello " + "world";
    , "Hello world");
    try testInterpreter(
        \\ "Hello " + 10;
    , "Hello 10");
    try testInterpreter("10 > 10;", "false");
    try testInterpreter("10 >= 10;", "true");
    try testInterpreter("10 < 10;", "false");
    try testInterpreter("10 <= 10;", "true");
    try testInterpreter("10 - 10;", "0");
    try testInterpreter("10 / 10;", "1");
    try testInterpreter("10 * 10;", "100");
    try testInterpreter("10 == 10;", "true");
    try testInterpreter("10 != 10;", "false");
    try testInterpreter(
        \\ "hello" == "hello";
    , "true");
    try testInterpreter(
        \\ "hello" != "hello";
    , "false");
    try testInterpreter("true == true;", "true");
    try testInterpreter("true != true;", "false");
    try testInterpreter("nil == nil;", "true");
    try testInterpreter("nil != nil;", "false");

    // Or Logical Evaluation
    try testInterpreter("false or false;", "false");
    try testInterpreter("true or false;", "true");
    try testInterpreter("false or true;", "true");
    try testInterpreter("true or true;", "true");

    // And Logical Evaluation
    try testInterpreter("false and false;", "false");
    try testInterpreter("false and true;", "false");
    try testInterpreter("true and false;", "false");
    try testInterpreter("true and true;", "true");

    // Unary Evaluation
    try testInterpreter("!true;", "false");
    try testInterpreter("!10;", "false");
    try testInterpreter(
        \\ !"hello";
    , "false");
    try testInterpreter("!nil;", "true");
    try testInterpreter("-10;", "-10");

    // Assign Evaluation
    try testInterpreter(
        \\ var name = "John Wick";
    , "John Wick");

    // Variable Evaluation
    try testInterpreter("var name;", "");
    try testInterpreter(
        \\ var name = "John Wick";
    , "John Wick");

    // Print Evaluation
    try testInterpreter(
        \\ print "hello world";
    , "hello world\n");

    // Block Evaluation
    try testInterpreter(
        \\ { print "hello world"; }
    , "hello world\n");

    // If Evaluation
    try testInterpreter(
        \\ if (true) { print true; } else { print false; }
    , "true\n");
    try testInterpreter(
        \\ if (false) { print true; } else { print false; }
    , "false\n");
    try testInterpreter(
        \\ if (true) print true; else print false;
    , "true\n");
    try testInterpreter(
        \\ if (false) print true; else print false;
    , "false\n");
    try testInterpreter(
        \\ if (false) if (true) print true; else print false;
    , "");
    try testInterpreter(
        \\ if (true) if (false) print true; else print false;
    , "false\n");
    try testInterpreter(
        \\ if (true) 10; else 20;
    , "10");
    try testInterpreter(
        \\ if (false) 10; else 20;
    , "20");

    // While Evaluation
    try testInterpreter(
        \\ var i = 1;
        \\ while(i <= 2) { print "hello"; i = i + 1; }
    , "1hello\nhello\n");

    // For Evaluation
    try testInterpreter(
        \\ for(var i = 0; i < 5; i = i + 1) print i;
    , "0\n1\n2\n3\n4\n");

    // Fun Evaluation
    try testInterpreter(
        \\ fun count(n) {
        \\   if (n > 1) count(n - 1);
        \\   print n;
        \\ }
        \\ count(3);
    , "1\n2\n3\n");

    try testInterpreter(
        \\ fun fib(n) {
        \\   if (n < 2) return n;
        \\   return fib(n - 2) + fib(n - 1);
        \\ }
        \\ fib(10);
    , "55");

    try testInterpreter(
        \\ fun makeCounter() {
        \\   var i = 0;
        \\   fun count() {
        \\     i = i + 1;
        \\     print i;
        \\   }
        \\
        \\   return count;
        \\ }
        \\
        \\ var counter = makeCounter();
        \\ counter();
        \\ counter(); // "2".
    , "<fn count>1\n2\n");
}

fn testInterpreter(
    source: [:0]const u8,
    print_out: []const u8,
) !void {
    const gpa = testing.allocator;

    var env: Env = .init(gpa, null);
    defer env.deinit();

    var buffer: [1024]u8 = undefined;
    var io_out: Io.Writer = .fixed(&buffer);

    var ctx: Context = .init(undefined, &env, .{ .out = &io_out, .err = &io_out });

    const stmt_list = try analyzer.parse(gpa, &ctx, source);
    defer stmt_list.deinit(gpa);

    var renderCtx: Ctx = .{
        .allocator = gpa,
        .env = ctx.env,
        .io = undefined,
        .status = ctx.status,
        .stream = ctx.stream,
    };

    var renderer: Renderer = .empty;
    defer renderer.deinit(gpa);

    for (stmt_list.list) |stmt| {
        const object = try renderer.execute(&renderCtx, stmt);
        defer object.deinit(renderCtx.allocator);

        if (object != .nil) {
            try object.toPrint(&io_out);
        }
    }
    try testing.expectEqualSlices(u8, print_out, io_out.buffered());
}

const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const analyzer = @import("analyzer.zig");
const ast = @import("ast.zig");
const Context = @import("Context.zig");
const Env = @import("EnvSoa.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
