// I need to create union Result type for a better error message.
pub fn render(
    gpa: Allocator,
    ctx: *Ctx,
    tree: ast.Ast,
    locals: AutoHashMap(*ast.Expr, usize),
) RendererError!void {
    var renderer: Renderer = try .init(gpa, locals);
    defer renderer.deinit();

    return try renderer.render(ctx, tree.list);
}

pub fn print(
    gpa: Allocator,
    ctx: *Ctx,
    tree: ast.Ast,
    locals: AutoHashMap(*ast.Expr, usize),
) RendererError!void {
    var renderer: Renderer = try .init(gpa, locals);
    defer renderer.deinit();

    return try renderer.print(ctx, tree.list);
}

pub const RendererError = Renderer.Error || Io.Writer.Error || Allocator.Error || Env.Error;

const Renderer = struct {
    allocator: Allocator,
    globals: *Env,
    // It holds the temporary Env.
    env: *Env,
    closures: ArrayList(*Env) = .empty, // Stores closures pointers.
    had_return: ?ast.Object = null,
    // The Renderer does not own the ownership.
    locals: AutoHashMap(*ast.Expr, usize),

    pub const Error = error{
        InvalidBinaryOperands,
        InvalidUnaryOperand,
        InvalidFunctionArity,
        ExpectedCallable,
    };

    pub fn init(gpa: Allocator, locals: AutoHashMap(*ast.Expr, usize)) !Renderer {
        const env = try Env.create(gpa, null);
        errdefer env.deinit();

        return .{
            .allocator = gpa,
            .had_return = null,
            .closures = .empty,
            .globals = env,
            .env = env,
            .locals = locals,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.closures.items) |closure| {
            closure.destroy(self.allocator);
        }
        self.closures.deinit(self.allocator);
        self.env.destroy(self.allocator);
    }

    pub fn render(self: *Renderer, ctx: *Ctx, list: []const *ast.Stmt) RendererError!void {
        for (list) |statement| {
            const object = try self.execute(ctx, statement);
            object.deinit(self.allocator);
        }
    }

    pub fn print(self: *Renderer, ctx: *Ctx, list: []const *ast.Stmt) RendererError!void {
        for (list) |statement| {
            const object = try self.execute(ctx, statement);
            defer object.deinit(self.allocator);

            if (object != .nil) {
                try object.toPrintln(ctx.stream.out);
            }
        }
    }

    // Statements //

    pub fn execute(self: *Renderer, ctx: *Ctx, stmt: *ast.Stmt) RendererError!ast.Object {
        return switch (stmt.*) {
            .expr_statement => |expr_stmt| try self.evaluate(ctx, expr_stmt.expression),
            .fun_statement => try self.funStatement(stmt),
            .if_statement => |if_stmt| try self.ifStatement(ctx, if_stmt),
            .print_statement => |print_stmt| try self.printStatement(ctx, print_stmt),
            .return_statement => |return_stmt| try self.returnStatement(ctx, return_stmt),
            .var_statement => |var_stmt| try self.varStatement(ctx, var_stmt),
            .while_statement => |while_stmt| try self.whileStatement(ctx, while_stmt),
            .block_statement => |block_stmt| try self.blockStatement(ctx, block_stmt),
        };
    }

    fn funStatement(self: *Renderer, stmt: *ast.Stmt) RendererError!ast.Object {
        if (stmt.* == .fun_statement) {
            // Transfer the value's ownership to interpreter env.
            try self.env.define(self.allocator, stmt.fun_statement.name.lexeme, .{
                // It borrowed statement and current env.
                .callable = .init(stmt, self.env),
            });
        }
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

    fn returnStatement(
        self: *Renderer,
        ctx: *Ctx,
        return_stmt: ast.Return,
    ) RendererError!ast.Object {
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
        // Transfer the object's ownership to interpreter's had_return.
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
        // Transfer the value's ownership to interpreter env.
        try self.env.define(self.allocator, var_stmt.name.lexeme, object);
        return try object.dupe(self.allocator);
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
            .unary => |unary| try self.unaryExpression(ctx, unary),
            .literal => |literal| try literal.value.dupe(self.allocator),
            .logical => |logical| try self.logicalExpression(ctx, logical),
            .variable => |variable| try self.variableExpression(exp, variable),
            .assign => |assign| try self.assignExpression(ctx, exp, assign),
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
        // Transfer the objects' ownership.
        return try self.callFn(ctx, callee.callable, list.items);
    }

    fn callFn(
        self: *Renderer,
        ctx: *Ctx,
        callable: ast.Callable,
        args: []const ast.Object,
    ) RendererError!ast.Object {
        const global_env = self.env;
        defer self.env = global_env;

        var fun_env = callable.closure;
        fun_env.enclosing = global_env;
        defer fun_env.enclosing = null;

        const local_env = try Env.create(self.allocator, fun_env);
        self.env = local_env;

        switch (callable.stmt.*) {
            .fun_statement => |fun_statement| {
                for (fun_statement.params, 0..) |param, i| {
                    // Transfer argument's ownership.
                    try self.env.define(self.allocator, param.lexeme, args[i]);
                }
                var block: ast.Stmt = .{ .block_statement = fun_statement.body };

                const object = try self.execute(ctx, &block);
                errdefer object.deinit(self.allocator);

                if (object != .callable) {
                    // It does not need the local env anymore.
                    local_env.destroy(self.allocator);
                } else {
                    // Transfer the local env's ownership to interpreter's closures.
                    try self.closures.append(self.allocator, local_env);
                }
                return object;
            },
            else => {},
        }
        return .nil;
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

    fn logicalExpression(
        self: *Renderer,
        ctx: *Ctx,
        logical: ast.Logical,
    ) RendererError!ast.Object {
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

    fn variableExpression(
        self: *Renderer,
        expr: *ast.Expr,
        variable: ast.Variable,
    ) RendererError!ast.Object {
        // The object belongs to Env.
        const object = blk: {
            if (self.locals.get(expr)) |distance| {
                break :blk try self.env.getAt(distance, variable.name.lexeme);
            } else {
                break :blk try self.globals.get(variable.name.lexeme);
            }
        };
        return try object.dupe(self.allocator);
    }

    fn assignExpression(
        self: *Renderer,
        ctx: *Ctx,
        expr: *ast.Expr,
        assign: ast.Assign,
    ) RendererError!ast.Object {
        const object = try self.evaluate(ctx, assign.value);
        errdefer object.deinit(self.allocator);
        // Transfer the value's ownership to interpreter's env.
        if (self.locals.get(expr)) |distance| {
            try self.env.assignAt(self.allocator, distance, assign.name.lexeme, object);
        } else {
            try self.globals.assign(self.allocator, assign.name.lexeme, object);
        }
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
};

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

    // Resovler Evaluation
    try testInterpreter(
        \\ var a = "global";
        \\ {
        \\   fun showA() {
        \\     print a;
        \\   }
        \\ 
        \\   showA();
        \\   var a = "block";
        \\   showA();
        \\ }
    , "globalglobal\nblock\n");
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

    var locals = try resolver.resolve(gpa, &ctx, stmt_list.list);
    defer locals.deinit();

    var renderer: Renderer = try .init(gpa, locals);
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
const AutoHashMap = std.AutoHashMap;
const Io = std.Io;

const analyzer = @import("analyzer.zig");
const ast = @import("ast.zig");
const Ctx = @import("Context.zig");
const Env = @import("EnvSoa.zig");
const resolver = @import("resolver.zig");
const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;
