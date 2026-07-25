// I need to create union Result type for a better error message.
pub fn render(gpa: Allocator, ctx: *Ctx, tree: ast.Ast) RendererError!void {
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    for (tree.list) |statement| {
        const object = try renderer.execute(ctx, statement);
        object.deinit(renderer.allocator);
    }
}

pub fn print(gpa: Allocator, ctx: *Ctx, tree: ast.Ast) RendererError!void {
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    for (tree.list) |statement| {
        const object = try renderer.execute(ctx, statement);
        defer object.deinit(renderer.allocator);

        if (object != .nil) {
            try object.toPrintln(ctx.stream.out);
        }
    }
}

pub const RendererError = Error || Io.Writer.Error || Allocator.Error || Env.Error;

const Renderer = @This();

allocator: Allocator,
had_return: ?ast.Object = null,
closures: *Env,
env: *Env,

const Error = error{
    InvalidBinaryOperands,
    InvalidUnaryOperand,
    InvalidFunctionArity,
    ExpectedCallable,
};

pub fn init(gpa: Allocator) Allocator.Error!Renderer {
    const global_env = try Env.create(gpa);
    errdefer global_env.deinit(gpa);

    const closures = try Env.create(gpa);
    errdefer closures.deinit(gpa);
    return .{
        .allocator = gpa,
        .env = global_env,
        .closures = closures,
    };
}

pub fn deinit(self: *Renderer) void {
    if (self.had_return) |result| {
        result.deinit(self.allocator);
    }
    self.env.destroy(self.allocator);
    self.closures.destroy(self.allocator);
}

// Statements //

pub fn execute(self: *Renderer, ctx: *Ctx, stmt: *ast.Stmt) RendererError!ast.Object {
    return switch (stmt.*) {
        .expr_statement => |expr_stmt| try self.evaluate(ctx, expr_stmt.expression),
        .fun_statement => |fun_stmt| try self.funStatement(fun_stmt),
        .if_statement => |if_stmt| try self.ifStatement(ctx, if_stmt),
        .print_statement => |print_stmt| try self.printStatement(ctx, print_stmt),
        .return_statement => |return_stmt| try self.returnStatement(ctx, return_stmt),
        .var_statement => |var_stmt| try self.varStatement(ctx, var_stmt),
        .while_statement => |while_stmt| try self.whileStatement(ctx, while_stmt),
        .block_statement => |block_stmt| try self.blockStatement(ctx, block_stmt),
    };
}

fn funStatement(self: *Renderer, fun_stmt: ast.Function) RendererError!ast.Object {
    // Transfer the object ownership to Env.
    try self.env.define(self.allocator, fun_stmt.name.lexeme, .{
        // It borrowed statement and set closure to empty.
        .callable = .init(fun_stmt, .empty),
    });
    return .nil;
}

fn ifStatement(self: *Renderer, ctx: *Ctx, if_stmt: ast.IF) RendererError!ast.Object {
    const condition = try self.evaluate(ctx, if_stmt.condition);
    defer condition.deinit(self.allocator);

    if (isTruthy(condition)) {
        return try self.execute(ctx, if_stmt.then_stmt);
    } else if (if_stmt.else_stmt) |else_stmt| {
        return try self.execute(ctx, else_stmt);
    }
    return .nil;
}

fn printStatement(self: *Renderer, ctx: *Ctx, print_stmt: ast.Print) RendererError!ast.Object {
    const object = try self.evaluate(ctx, print_stmt.expression);
    defer object.deinit(self.allocator);

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
        return_value.deinit(self.allocator);
    }
    // Transfer the object ownership to self.had_return.
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
    errdefer object.deinit(self.allocator);
    // Transfer the object ownership.
    try self.env.define(self.allocator, var_stmt.name.lexeme, object);
    return object.dupe(self.allocator);
}

fn whileStatement(self: *Renderer, ctx: *Ctx, while_stmt: ast.While) RendererError!ast.Object {
    while (true) {
        const condition = try self.evaluate(ctx, while_stmt.condition);
        defer condition.deinit(self.allocator);

        if (!isTruthy(condition)) break;

        const object = try self.execute(ctx, while_stmt.body);
        defer object.deinit(self.allocator);
    }
    return .nil;
}

fn blockStatement(self: *Renderer, ctx: *Ctx, block_stmt: ast.Block) RendererError!ast.Object {
    for (block_stmt.list) |value_statement| {
        const object = try self.execute(ctx, value_statement);
        defer object.deinit(self.allocator);

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
        .literal => |literal| try literal.value.dupe(self.allocator),
        .logical => |logical| try self.logicalExpression(ctx, logical),
        .variable => |variable| try self.variableExpression(variable),
        .assign => |assign| try self.assignExpression(ctx, assign),
    };
}

fn binaryExpression(self: *Renderer, ctx: *Ctx, binary: ast.Binary) RendererError!ast.Object {
    const left = try self.evaluate(ctx, binary.left);
    defer left.deinit(self.allocator);

    const right = try self.evaluate(ctx, binary.right);
    defer right.deinit(self.allocator);

    if (binary.operator.tag == .plus) {
        if (left.isNumber() and right.isNumber()) {
            return .{ .number = left.number + right.number };
        }
        if (left.isString() and right.isString()) {
            return .{
                .string = try mem.concat(self.allocator, u8, &.{
                    left.string,
                    right.string,
                }),
            };
        }
        if (left.isString() and right.isNumber()) {
            return .{
                .string = try fmt.allocPrint(self.allocator, "{s}{}", .{
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
    defer callee.deinit(self.allocator);

    if (!callee.isCallable()) return error.ExpectedCallable;

    var list: ArrayList(ast.Object) = try .initCapacity(self.allocator, call.args.len);
    defer list.deinit(self.allocator);
    errdefer for (list.items) |item| item.deinit(self.allocator);

    for (call.args) |arg| {
        const object = try self.evaluate(ctx, arg);
        errdefer object.deinit(self.allocator);
        try list.append(self.allocator, object);
    }

    if (list.items.len != callee.callable.arity()) {
        return error.InvalidFunctionArity;
    }
    // Transfer the objects ownership. not the container.
    return try self.callFn(ctx, callee.callable, list.items);
}

fn callFn(
    self: *Renderer,
    ctx: *Ctx,
    callable: ast.Callable,
    args: []const ast.Object,
) RendererError!ast.Object {
    const closure_index = self.env.len();
    // Transfer the closure memory to global env.
    try self.env.append(self.allocator, try self.closures.slice(callable.closure));
    // The closures slices memory has become invalid.
    const local_index = self.env.len();
    for (callable.stmt.params, 0..) |param, i| {
        try self.env.define(self.allocator, param.lexeme, args[i]);
    }

    var block: ast.Stmt = .{ .block_statement = callable.stmt.body };
    var object = try self.execute(ctx, &block);
    errdefer object.deinit(self.allocator);

    // Steal the local keys and values from global env.
    const local = try self.env.steal(self.allocator, local_index);
    defer local.deinit(self.allocator);

    // Validate return object.
    if (object == .callable) {
        // Transfer the local ownership to interpreter's closures.
        const local_loc = try self.appendClosure(local);
        object.callable.closure.assign(local_loc);

        // Transfer the object ownership to interpreter's closures.
        const object_key = object.callable.stmt.name.lexeme;
        try self.closures.assign(self.allocator, object_key, object);
    } else {
        for (local.values) |value| {
            // Release the objects if it is not a function.
            value.deinit(self.allocator);
        }
    }

    // Steal the function's closure ownership.
    const new_closure = try self.env.steal(self.allocator, closure_index);
    defer new_closure.deinit(self.allocator);

    // Transfer the new memory to invalid location.
    try self.closures.replace(callable.closure, new_closure);
    return try object.dupe(self.allocator);
}

fn appendClosure(self: *Renderer, local: Env.Local) !ast.Closure {
    var closure: ast.Closure = .{
        .keys = .{
            .start = self.closures.keys.items.len,
            .end = 0,
        },
        .values = .{
            .start = self.closures.values.items.len,
            .end = 0,
        },
    };
    // Transfer the local ownership to interpreter's closures.
    try self.closures.append(self.allocator, local);
    // Add the end bound.
    closure.keys.end = self.closures.keys.items.len;
    closure.values.end = self.closures.values.items.len;

    return closure;
}

fn unaryExpression(self: *Renderer, ctx: *Ctx, unary: ast.Unary) RendererError!ast.Object {
    const right = try self.evaluate(ctx, unary.right);
    defer right.deinit(self.allocator);

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
    errdefer left.deinit(self.allocator);

    if (logical.operator.tag == .keyword_or) {
        if (isTruthy(left)) return left;
    } else {
        if (!isTruthy(left)) return left;
    }

    left.deinit(self.allocator);
    return try self.evaluate(ctx, logical.right);
}

fn variableExpression(self: *Renderer, variable: ast.Variable) RendererError!ast.Object {
    // The object belongs interpreter's env.
    const object = try self.env.get(variable.name.lexeme);
    return try object.dupe(self.allocator);
}

fn assignExpression(self: *Renderer, ctx: *Ctx, assign: ast.Assign) RendererError!ast.Object {
    const object = try self.evaluate(ctx, assign.value);
    errdefer object.deinit(self.allocator);
    // Transfer the object ownership to interpreter's env.
    try self.env.assign(self.allocator, assign.name.lexeme, object);
    return try object.dupe(self.allocator);
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

    var buffer: [1024]u8 = undefined;
    var io_out: Io.Writer = .fixed(&buffer);

    var ctx: Ctx = .init(undefined, .{ .out = &io_out, .err = &io_out });

    const stmt_list = try analyzer.parse(gpa, &ctx, source);
    defer stmt_list.deinit(gpa);

    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    for (stmt_list.list) |stmt| {
        const object = try renderer.execute(&ctx, stmt);
        defer object.deinit(renderer.allocator);

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
const Ctx = @import("Context.zig");
const Env = @import("EnvFlat.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
